defmodule Humdinger.Player do
  @moduledoc """
  Plays notes out through the output (`Humdinger.Output`, or `config
  :humdinger, :output`) or locally via `Humdinger.Audio` (`play_piano/2`).

  A screen starts its own player with `start_link/1`. It is linked to the
  screen: when the screen goes (popped, crashed) the player stops, cancels any
  local piano preview, and sends note-offs for whatever MIDI is still sounding.

  `play(player, notes, tag, opts \\ [])` replaces anything playing. With the
  default `mode: :midi`, `notes` (`%{start_ms, dur_ms, midi, velocity}` from
  `Humdinger.Phrase.quantized_notes/1`) play out over MIDI from time 0 and send
  `{:player, :finished, tag}` when done. With `mode: :piano`, `notes` play via
  `Audio.play_piano/2` without emitting MIDI notes, forwarding
  `{:player, :position, tag, ms}`, `{:player, :finished, tag}`, and
  `{:player, :error, tag, reason}` to the owner. `stop/1` ends either mode
  early (canceling piano or sending MIDI note-offs, no finished message;
  `stop/1` and `play/4` may return `{:error, :stream_stuck}` if canceling an
  active piano stream fails, and `play/4` returns `{:error, :output_down}`
  when the output cannot be resolved or acquired).

  One source at a time: the player acquires an Output session
  (`Humdinger.Output.acquire/2`) for either mode so live MIDI is muted and global
  preemption applies. When another session preempts this one
  (`{:output, :session_ended, ref}`), or Output goes, local piano is canceled,
  the player stops, and the owner gets `{:player, :finished, tag}` (or
  `{:player, :error, tag, reason}` if canceling piano failed).

  Timing for `:midi`: on every tick the player reads its clock, sends everything
  due and sets a timer for the next event. Options for tests: `clock:` (a
  zero-arity function -> ms), `output:` (module or `{module, server}`), and
  `audio:` (module implementing `play_piano/2` and `cancel_piano/1`).
  """

  use GenServer

  alias Humdinger.Audio

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
  @spec play(GenServer.server(), [note()], term(), keyword()) :: :ok | {:error, term()}
  def play(player, notes, tag, opts \\ []),
    do: GenServer.call(player, {:play, notes, tag, opts})

  @doc "Stops, canceling piano or sending note-offs for the sounding notes."
  @spec stop(GenServer.server()) :: :ok | {:error, term()}
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
       audio: Keyword.get_lazy(opts, :audio, &Audio.impl/0),
       # The Output session while playing: %{ref, mon, pid}.
       session: nil,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       tag: nil,
       mode: nil,
       piano_ref: nil,
       t0: nil,
       pending: [],
       sounding: MapSet.new(),
       token: nil
     }}
  end

  @impl true
  def handle_call({:play, notes, tag, opts}, _from, state) do
    mode = Keyword.get(opts, :mode, :midi)
    old_tag = state.tag

    case silence(state) do
      {:error, reason, st} ->
        if old_tag != nil, do: send(st.owner, {:player, :error, old_tag, reason})
        {:reply, {:error, reason}, release(st)}

      {:ok, st} ->
        start(mode, notes, tag, st)
    end
  end

  def handle_call(:stop, _from, state) do
    case silence(state) do
      {:ok, st} -> {:reply, :ok, release(st)}
      {:error, reason, st} -> {:reply, {:error, reason}, release(st)}
    end
  end

  def handle_call(:playing, _from, state), do: {:reply, state.tag, state}

  defp start(mode, notes, tag, st) do
    with {:ok, st} <- acquire(st),
         {:ok, st} <- start_mode(mode, notes, tag, st) do
      {:reply, :ok, st}
    else
      {:error, reason} -> {:reply, {:error, reason}, release(st)}
      {:error, reason, st} -> {:reply, {:error, reason}, release(st)}
    end
  end

  @impl true
  def handle_info({:tick, token}, %{token: token, mode: :midi} = state),
    do: {:noreply, advance(state)}

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info(
        {:hum_audio, ref, {:piano_position, ms}},
        %{mode: :piano, piano_ref: ref} = state
      ) do
    if state.tag != nil, do: send(state.owner, {:player, :position, state.tag, ms})
    {:noreply, state}
  end

  def handle_info({:hum_audio, ref, :piano_finished}, %{mode: :piano, piano_ref: ref} = state) do
    tag = state.tag
    state = state |> clear_playback() |> release()
    if tag != nil, do: send(state.owner, {:player, :finished, tag})
    {:noreply, state}
  end

  def handle_info(
        {:hum_audio, ref, {:piano_error, reason}},
        %{mode: :piano, piano_ref: ref} = state
      ) do
    tag = state.tag
    state = state |> clear_playback() |> release()
    if tag != nil, do: send(state.owner, {:player, :error, tag, reason})
    {:noreply, state}
  end

  def handle_info({:hum_audio, _stale_ref, _msg}, state), do: {:noreply, state}

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

  defp start_mode(:midi, notes, tag, state) do
    state = %{
      state
      | tag: tag,
        mode: :midi,
        piano_ref: nil,
        t0: state.clock.(),
        pending: timeline(notes),
        token: make_ref()
    }

    {:ok, advance(state)}
  end

  defp start_mode(:piano, notes, tag, state) do
    case state.audio.play_piano(self(), notes) do
      {:ok, ref} ->
        {:ok, %{state | tag: tag, mode: :piano, piano_ref: ref, t0: nil, pending: [], token: nil}}

      {:error, reason} ->
        {:error, reason, clear_playback(state)}
    end
  end

  defp start_mode(mode, _notes, _tag, state),
    do: {:error, {:invalid_mode, mode}, clear_playback(state)}

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
  defp finish(state) do
    case silence(state) do
      {:ok, state} -> release(state)
      {:error, _reason, state} -> release(state)
    end
  end

  # The session is gone without us: cancel piano, forget everything, tell the owner.
  defp lost(state) do
    if state.session.mon, do: Process.demonitor(state.session.mon, [:flush])

    cancel_res =
      if state.piano_ref != nil,
        do: state.audio.cancel_piano(state.piano_ref),
        else: :ok

    if state.tag != nil do
      case cancel_res do
        :ok -> send(state.owner, {:player, :finished, state.tag})
        {:error, reason} -> send(state.owner, {:player, :error, state.tag, reason})
      end
    end

    %{clear_playback(state) | session: nil}
  end

  # Cancel active piano or emit MIDI note-offs for what's sounding; forget the rest.
  defp silence(state) do
    cancel_res =
      if state.piano_ref != nil,
        do: state.audio.cancel_piano(state.piano_ref),
        else: :ok

    offs = for m <- Enum.sort(state.sounding), do: {:note_off, m}
    if offs != [], do: out(state, offs)
    state = clear_playback(state)

    case cancel_res do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp clear_playback(state) do
    %{
      state
      | tag: nil,
        mode: nil,
        piano_ref: nil,
        t0: nil,
        pending: [],
        sounding: MapSet.new(),
        token: nil
    }
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

  defp out(%{session: %{ref: ref, pid: pid}} = state, events) do
    module = output_module(state)
    module.session_events(ref, events, pid)
  end

  defp acquire(%{session: %{}} = state), do: {:ok, state}

  defp acquire(state) do
    {module, server} = output_target(state)

    case GenServer.whereis(server) do
      nil ->
        {:error, :output_down}

      pid ->
        mon = Process.monitor(pid)

        try do
          {:ok, ref} = module.acquire(self(), pid)
          {:ok, %{state | session: %{ref: ref, mon: mon, pid: pid}}}
        catch
          :exit, _ ->
            Process.demonitor(mon, [:flush])
            {:error, :output_down}
        end
    end
  end

  defp release(%{session: nil} = state), do: state

  defp release(%{session: %{ref: ref, mon: mon, pid: pid}} = state) do
    if mon, do: Process.demonitor(mon, [:flush])
    module = output_module(state)

    # Output may be gone (restarting, or stopping with us): nothing to release.
    try do
      module.release(ref, pid)
    catch
      :exit, _ -> :gone
    end

    %{state | session: nil}
  end

  defp output_target(%{output: {module, server}}), do: {module, server}
  defp output_target(%{output: module}), do: {module, module}

  defp output_module(%{output: {module, _server}}), do: module
  defp output_module(%{output: module}), do: module
end
