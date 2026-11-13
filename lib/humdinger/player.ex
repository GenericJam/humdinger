defmodule Humdinger.Player do
  @moduledoc """
  Plays notes out through the output (`Humdinger.Output`, or `config
  :humdinger, :output`) at their times: the Phrases list's play buttons,
  Review's "Play out" and "Play back", Import's "Play out", and Output's
  test note. Humdinger makes no sound itself; the synth at the other end
  does.

  A screen starts its own player with `start_link/1`. It is linked to the
  screen: when the screen goes (popped, crashed) the player stops and sends
  note-offs for whatever is still sounding.

  `play(player, notes, tag)` replaces anything playing. `notes` are
  `%{start_ms, dur_ms, midi, velocity}` (`Humdinger.Phrase.quantized_notes/1`),
  played from time 0. Events due at the same time go out in one batch, note
  offs first, so a repeated pitch re-strikes. When the last note ends the
  owner gets `{:player, :finished, tag}`, sent only once the note-offs are
  out and the session is released (below); `stop/1` ends early (note-offs,
  no message).

  One source at a time: the player plays in an Output session
  (`Humdinger.Output.acquire/2`), which takes the output from the singer
  for as long as it plays (see `Humdinger.Output`). Output monitors the
  player, so a player killed outright still has its notes released. When
  another session preempts this one (`{:output, :session_ended, ref}`), or
  Output goes (its own `terminate/2` silences everything), the player stops
  and the owner gets `{:player, :finished, tag}`.

  Timing: on every tick the player reads its clock, sends everything due
  and sets a timer for the next event. A late timer only delays the batch;
  nothing is skipped or drifts, because times are measured from the start
  on the clock. Options for tests: `clock:` (a zero-arity function → ms),
  `output:` (a module with `acquire/1`, `session_events/2`, `release/1`, or
  `{module, server}` for the versions taking a server).
  """

  use GenServer

  @typedoc "A note to play; extra keys are ignored."
  @type note :: %{
          required(:start_ms) => number(),
          required(:dur_ms) => number(),
          required(:midi) => 0..127,
          optional(:velocity) => 1..127
        }

  @default_velocity 100

  @doc "Starts a player for the calling process (`owner:` overrides)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Plays `notes` from the start, replacing anything playing."
  @spec play(GenServer.server(), [note()], term()) :: :ok
  def play(player, notes, tag), do: GenServer.call(player, {:play, notes, tag})

  @doc "Stops, sending note-offs for the sounding notes."
  @spec stop(GenServer.server()) :: :ok
  def stop(player), do: GenServer.call(player, :stop)

  @doc "The tag of what's playing, or nil."
  @spec playing(GenServer.server()) :: term() | nil
  def playing(player), do: GenServer.call(player, :playing)

  @doc """
  The note on/off timeline of `notes`: `[{t_ms, [event]}]`, ascending, note
  offs before note ons at the same time.
  """
  @spec timeline([note()]) :: [{number(), [tuple()]}]
  def timeline(notes) do
    notes
    |> Enum.flat_map(fn n ->
      vel = Map.get(n, :velocity) || @default_velocity
      [{n.start_ms, 1, {:note_on, n.midi, vel}}, {n.start_ms + n.dur_ms, 0, {:note_off, n.midi}}]
    end)
    |> Enum.sort_by(fn {t, order, _} -> {t, order} end)
    |> Enum.chunk_by(fn {t, _, _} -> t end)
    |> Enum.map(fn [{t, _, _} | _] = same -> {t, Enum.map(same, &elem(&1, 2))} end)
  end

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       output:
         Keyword.get_lazy(opts, :output, fn ->
           Application.get_env(:humdinger, :output, Humdinger.Output)
         end),
       # The Output session while playing: %{ref, mon}.
       session: nil,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       tag: nil,
       t0: nil,
       pending: [],
       sounding: MapSet.new(),
       token: nil
     }}
  end

  @impl true
  def handle_call({:play, notes, tag}, _from, state) do
    state = state |> silence() |> acquire()

    state = %{
      state
      | tag: tag,
        t0: state.clock.(),
        pending: timeline(notes),
        token: make_ref()
    }

    {:reply, :ok, advance(state)}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, finish(state)}
  def handle_call(:playing, _from, state), do: {:reply, state.tag, state}

  @impl true
  def handle_info({:tick, token}, %{token: token} = state), do: {:noreply, advance(state)}
  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  # Another session took over: its notes were released by Output.
  def handle_info({:output, :session_ended, ref}, %{session: %{ref: ref}} = state),
    do: {:noreply, lost(state)}

  # Output went: its terminate/2 silenced everything.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{session: %{mon: mon}} = state),
    do: {:noreply, lost(state)}

  def handle_info({:output, :session_ended, _stale}, state), do: {:noreply, state}
  def handle_info({:DOWN, _mon, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state),
    do: {:stop, if(reason == :normal, do: :normal, else: :shutdown), state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: finish(state)

  # Sends everything due, then waits for the next event or finishes.
  defp advance(%{tag: nil} = state), do: state

  defp advance(state) do
    elapsed = state.clock.() - state.t0
    {due, rest} = Enum.split_while(state.pending, fn {t, _} -> t <= elapsed end)
    state = Enum.reduce(due, state, fn {_t, events}, st -> send_events(st, events) end)

    case rest do
      [] ->
        tag = state.tag
        state = finish(state)
        # Only now: the note-offs are out and the singer has the output back.
        send(state.owner, {:player, :finished, tag})
        state

      [{t, _} | _] ->
        Process.send_after(self(), {:tick, state.token}, max(ceil(t - elapsed), 0))
        %{state | pending: rest}
    end
  end

  # Silence, then release the session (Output has the note-offs before it
  # answers: same sender, same order).
  defp finish(state), do: state |> silence() |> release()

  # The session is gone without us: forget everything, tell the owner.
  defp lost(state) do
    if state.session.mon, do: Process.demonitor(state.session.mon, [:flush])
    if state.tag != nil, do: send(state.owner, {:player, :finished, state.tag})
    %{state | session: nil, tag: nil, pending: [], sounding: MapSet.new(), token: nil}
  end

  # Note-offs for what's sounding; forget the rest.
  defp silence(state) do
    offs = for m <- Enum.sort(state.sounding), do: {:note_off, m}
    if offs != [], do: out(state, offs)
    %{state | tag: nil, pending: [], sounding: MapSet.new(), token: nil}
  end

  # A note on for a pitch already sounding (overlapping notes as sung) ends
  # it first; a note off for a pitch that isn't sounding is dropped.
  defp send_events(state, events) do
    {out, sounding} =
      Enum.flat_map_reduce(events, state.sounding, fn
        {:note_on, m, _} = on, s ->
          if MapSet.member?(s, m), do: {[{:note_off, m}, on], s}, else: {[on], MapSet.put(s, m)}

        {:note_off, m} = off, s ->
          if MapSet.member?(s, m), do: {[off], MapSet.delete(s, m)}, else: {[], s}
      end)

    if out != [], do: out(state, out)
    %{state | sounding: sounding}
  end

  defp out(%{session: nil}, _events), do: :ok

  defp out(%{output: {module, server}, session: s}, events),
    do: module.session_events(s.ref, events, server)

  defp out(%{output: module, session: s}, events), do: module.session_events(s.ref, events)

  defp acquire(%{session: %{}} = state), do: state

  defp acquire(state) do
    {:ok, ref} = call_output(state, :acquire, [self()])

    mon =
      case GenServer.whereis(server(state)) do
        nil -> nil
        pid -> Process.monitor(pid)
      end

    %{state | session: %{ref: ref, mon: mon}}
  end

  defp release(%{session: nil} = state), do: state

  defp release(%{session: session} = state) do
    if session.mon, do: Process.demonitor(session.mon, [:flush])
    # Output may be gone (restarting, or stopping with us): nothing to release.
    try do
      call_output(state, :release, [session.ref])
    catch
      :exit, _ -> :gone
    end

    %{state | session: nil}
  end

  defp call_output(%{output: {module, server}}, fun, args),
    do: apply(module, fun, args ++ [server])

  defp call_output(%{output: module}, fun, args), do: apply(module, fun, args)

  defp server(%{output: {_module, server}}), do: server
  defp server(%{output: module}), do: module
end
