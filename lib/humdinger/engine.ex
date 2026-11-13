defmodule Humdinger.Engine do
  @moduledoc """
  The real-time path: owns the microphone (`Humdinger.Audio`), runs the
  readings through a `Humdinger.Tracker`, sends the events to the output
  (`Humdinger.Output.send_events/1`) and tells subscribed screens what is
  happening. One per app, started from `Humdinger.App.on_start/0`, so it
  keeps listening while the singer plays FMutate in the foreground.

  ## Time

  Readings carry ms since their `listen/2`; the engine moves them onto one
  clock that keeps running across pause and resume (engine time), so the
  tracker and a recording never see time go backwards. Between readings
  the engine estimates the time from the last reading plus the wall clock
  since it arrived; that drives the hold timer (`Tracker.tick/2` at
  `Tracker.deadline/1`) and the ends of a recording.

  ## Subscribers

  `subscribe/1` (monitored; a dead subscriber is dropped) sends the current
  `{:engine, :status, status}` at once and on every change, and
  `{:engine, :frame, frame}` at most 30 times a second while listening (a
  token-guarded timer sends the latest state, not every reading; one more
  frame follows each status change so Mimi's mood updates). A subscriber
  that asks with `spectrum/2` also gets `{:engine, :spectrum, spectrum}`;
  the microphone computes the spectrum only while someone wants it.

  A frame is `%{t, pitch, note, cents, hz, db, velocity, voiced, mood,
  sent}`: the tracker's display (`Humdinger.Tracker.display/1`), the
  engine time `t` of the latest reading, Mimi's `mood` and `sent`, the
  last note on or off sent (`describe/2`, e.g. "A4 on · vel 92 · ch 1"),
  or nil.

  Moods: `:no_mic` (the microphone failed or was refused), `:paused`,
  `:idle` (off, or nothing voiced for 5 s and the room quieter than 10 dB
  below the gate), `:listening` (otherwise not singing: a breath, or a
  sound near the gate), `:flat` / `:sharp` (a note sounds and the voice is
  10 cents or more off it, `Humdinger.Tracker.tuning_label/1`), `:aria`
  (singing 35 dB or more above the gate), `:singing`.

  ## Settings

  `update_settings/1` saves through `Humdinger.Settings.update/1` and
  reconfigures the tracker (`Humdinger.Tracker.configure/2`): changing the
  mode, scale, octave, transpose, bend range or channel first turns the
  sounding note off. A channel change is passed on with
  `output.configure(channel: n)` after those note offs, so they still go
  out on the old channel.

  ## Recording

  `record_start/0` begins a take at the current engine time;
  `record_stop/0` returns a `Humdinger.Take`: the notes the engine sent
  (from note on/off pairs, ms from the start; a note sounding at the start
  begins at 0, one still sounding at the stop ends there), the sung pitch
  trace (`{t_ms, pitch}`, the tracker's smoothed pitch after octave and
  transpose so it lines up with the notes, at most one every 10 ms, a
  single nil where the voice stops), the scale in Scale mode (nil in
  Open), `source: :hum` and `recorded_at`. A take without notes is
  `{:error, :empty}`.
  """

  use GenServer

  alias Humdinger.{Audio, Music, Settings, Take, Tracker}

  @frame_ms 33
  @idle_after_ms 5_000
  @near_gate_db 10
  @aria_above_gate_db 35
  @trace_every_ms 10

  @type status :: :off | :listening | :paused | {:error, term()}
  @type frame :: %{
          t: non_neg_integer() | nil,
          pitch: float() | nil,
          note: 0..127 | nil,
          cents: float() | nil,
          hz: float() | nil,
          db: float(),
          velocity: 1..127 | nil,
          voiced: boolean(),
          mood: :idle | :listening | :singing | :aria | :flat | :sharp | :paused | :no_mic,
          sent: String.t() | nil
        }

  # ── API ───────────────────────────────────────────────────────────────

  @doc """
  Start the engine. Options: `audio:` (default `Humdinger.Audio.impl/0`),
  `output:` (default `config :humdinger, :output`, else
  `Humdinger.Output`), `name:` (default `Humdinger.Engine`). Settings come
  from `Humdinger.Settings.load/0`. The engine starts `:off`; `listen/0`
  turns the microphone on.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the status now and frames from now on (see the moduledoc)."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid), do: GenServer.call(server, {:subscribe, pid})

  @doc "Turn the spectrum relay on or off for a subscriber (subscribing it if needed)."
  @spec spectrum(GenServer.server(), pid(), boolean()) :: :ok
  def spectrum(server \\ __MODULE__, pid, on?) when is_boolean(on?),
    do: GenServer.call(server, {:spectrum, pid, on?})

  @doc "Turn the microphone on. `{:error, reason}` when it can't (e.g. `:permission`)."
  @spec listen(GenServer.server()) :: :ok | {:error, term()}
  def listen(server \\ __MODULE__), do: GenServer.call(server, :listen)

  @doc "Stop sending: the sounding note ends and the microphone turns off. Only while listening."
  @spec pause(GenServer.server()) :: :ok
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)

  @doc "Listen again after `pause/0`. Does nothing unless paused."
  @spec resume(GenServer.server()) :: :ok | {:error, term()}
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  @doc "Everything off: the sounding note ends and the microphone turns off."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__), do: GenServer.call(server, :stop)

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec settings(GenServer.server()) :: Settings.t()
  def settings(server \\ __MODULE__), do: GenServer.call(server, :settings)

  @doc """
  Change settings (a map or keyword list of fields, or a function of the
  settings), save them and apply them to the note in progress. Returns
  the new settings, or `{:error, {:invalid, field}}` and changes nothing.
  """
  @spec update_settings(GenServer.server(), Settings.change()) ::
          {:ok, Settings.t()} | {:error, {:invalid, atom()}}
  def update_settings(server \\ __MODULE__, change),
    do: GenServer.call(server, {:update_settings, change})

  @doc "Start recording a take. Does nothing if one is being recorded."
  @spec record_start(GenServer.server()) :: :ok
  def record_start(server \\ __MODULE__), do: GenServer.call(server, :record_start)

  @doc """
  Finish the take. `{:error, :empty}` when no note was sent during it,
  `{:error, :not_recording}` when none was started.
  """
  @spec record_stop(GenServer.server()) :: {:ok, Take.t()} | {:error, :empty | :not_recording}
  def record_stop(server \\ __MODULE__), do: GenServer.call(server, :record_stop)

  @spec recording?(GenServer.server()) :: boolean()
  def recording?(server \\ __MODULE__), do: GenServer.call(server, :recording?)

  @doc ~S"""
  A one-line summary of an event on a channel, as the Live and Output
  screens show it: "A4 on · vel 92 · ch 1", "A4 off · ch 1",
  "bend +1234 · ch 1", "CC 11 = 80 · ch 1". The same wording as
  `Humdinger.Midi.describe/2`.
  """
  @spec describe(Tracker.event(), 1..16) :: String.t()
  def describe({:note_on, note, velocity}, channel),
    do: "#{Music.note_name(note)} on · vel #{velocity} · ch #{channel}"

  def describe({:note_off, note}, channel), do: "#{Music.note_name(note)} off · ch #{channel}"

  def describe({:pitch_bend, value}, channel) when value > 0, do: "bend +#{value} · ch #{channel}"
  def describe({:pitch_bend, value}, channel), do: "bend #{value} · ch #{channel}"
  def describe({:cc, number, value}, channel), do: "CC #{number} = #{value} · ch #{channel}"

  # ── Server ────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    settings = Settings.load()
    output = Keyword.get_lazy(opts, :output, &default_output/0)

    {:ok,
     %{
       audio: Keyword.get_lazy(opts, :audio, &Audio.impl/0),
       output: output,
       settings: settings,
       tracker: Tracker.new(settings),
       status: :off,
       ref: nil,
       base: now_ms(),
       offset: 0,
       last_t: nil,
       last_at: nil,
       last_voiced_t: nil,
       subscribers: %{},
       frame_token: nil,
       dirty: false,
       hold_timer: nil,
       sent: nil,
       record: nil
     }}
  end

  defp default_output, do: Application.get_env(:humdinger, :output, Humdinger.Output)

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    state = add_subscriber(state, pid)
    send(pid, {:engine, :status, state.status})
    {:reply, :ok, state}
  end

  def handle_call({:spectrum, pid, on?}, _from, state) do
    before = wants_spectrum?(state)
    state = add_subscriber(state, pid)
    state = put_in(state.subscribers[pid].spectrum, on?)
    {:reply, :ok, sync_spectrum(state, before)}
  end

  def handle_call(:listen, _from, %{status: :listening} = state), do: {:reply, :ok, state}
  def handle_call(:listen, _from, state), do: start_listening(state)

  def handle_call(:pause, _from, %{status: :listening} = state),
    do: {:reply, :ok, state |> stop_listening() |> set_status(:paused)}

  def handle_call(:pause, _from, state), do: {:reply, :ok, state}

  def handle_call(:resume, _from, %{status: :paused} = state), do: start_listening(state)
  def handle_call(:resume, _from, state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, %{status: :off} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state),
    do: {:reply, :ok, state |> stop_listening() |> set_status(:off)}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:settings, _from, state), do: {:reply, state.settings, state}

  def handle_call({:update_settings, change}, _from, state) do
    case Settings.update(change) do
      {:ok, settings} ->
        {tracker, events} = Tracker.configure(state.tracker, settings)
        old_channel = state.settings.channel
        state = emit(%{state | tracker: tracker}, events, now_t(state))
        if settings.channel != old_channel, do: state.output.configure(channel: settings.channel)
        state = %{state | settings: settings, dirty: true} |> arm_hold()
        {:reply, {:ok, settings}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:record_start, _from, %{record: nil} = state) do
    t0 = now_t(state)
    display = Tracker.display(state.tracker)

    open =
      if display.note,
        do: %{display.note => {0, display.velocity}},
        else: %{}

    record = %{
      t0: t0,
      open: open,
      notes: [],
      trace: [],
      trace_t: nil,
      scale: if(state.settings.mode == :scale, do: state.settings.scale),
      recorded_at: DateTime.utc_now()
    }

    {:reply, :ok, %{state | record: record}}
  end

  def handle_call(:record_start, _from, state), do: {:reply, :ok, state}

  def handle_call(:record_stop, _from, %{record: nil} = state),
    do: {:reply, {:error, :not_recording}, state}

  def handle_call(:record_stop, _from, %{record: record} = state) do
    end_ms = max(now_t(state) - record.t0, 0)

    notes =
      Enum.reduce(record.open, record.notes, fn {midi, {start, velocity}}, notes ->
        [take_note(midi, start, end_ms, velocity) | notes]
      end)
      |> Enum.sort_by(&{&1.start_ms, &1.midi})

    reply =
      if notes == [] do
        {:error, :empty}
      else
        {:ok,
         %Take{
           notes: notes,
           trace: Enum.reverse(record.trace),
           duration_ms: end_ms,
           scale: record.scale,
           source: :hum,
           recorded_at: record.recorded_at
         }}
      end

    {:reply, reply, %{state | record: nil}}
  end

  def handle_call(:recording?, _from, state), do: {:reply, state.record != nil, state}

  @impl GenServer
  def handle_info({:hum_audio, ref, message}, %{ref: ref} = state) when ref != nil,
    do: audio(message, state)

  # A message from an earlier listen (stale) or a reference we don't hold.
  def handle_info({:hum_audio, _ref, _message}, state), do: {:noreply, state}

  def handle_info({:frame, token}, %{frame_token: token} = state) when token != nil do
    state = if state.dirty, do: broadcast_frame(state), else: state
    {:noreply, schedule_frame(state)}
  end

  def handle_info({:frame, _stale}, state), do: {:noreply, state}

  def handle_info({:hold, timer}, %{hold_timer: {timer, _tref}} = state) do
    t = now_t(state)
    {tracker, events} = Tracker.tick(state.tracker, t)
    state = %{state | tracker: tracker, hold_timer: nil, dirty: true}
    {:noreply, state |> emit(events, t) |> arm_hold()}
  end

  def handle_info({:hold, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, mon, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => %{mon: ^mon}} ->
        before = wants_spectrum?(state)
        state = %{state | subscribers: Map.delete(state.subscribers, pid)}
        {:noreply, sync_spectrum(state, before)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Audio ─────────────────────────────────────────────────────────────

  defp audio({:readings, readings}, state) do
    state = Enum.reduce(readings, state, &reading/2)
    received = now_ms()
    {:noreply, %{state | last_at: received, dirty: true} |> arm_hold()}
  end

  defp audio({:spectrum, spectrum}, state) do
    for {pid, %{spectrum: true}} <- state.subscribers,
        do: send(pid, {:engine, :spectrum, spectrum})

    {:noreply, state}
  end

  defp audio({:error, reason}, state),
    do: {:noreply, state |> stop_listening() |> set_status({:error, reason})}

  defp audio(_other, state), do: {:noreply, state}

  defp reading(%{t: t} = reading, state) do
    t = t + state.offset
    {tracker, events} = Tracker.push(state.tracker, %{reading | t: t})
    display = Tracker.display(tracker)
    last_voiced_t = if display.voiced, do: t, else: state.last_voiced_t

    %{state | tracker: tracker, last_t: t, last_voiced_t: last_voiced_t}
    |> emit(events, t)
    |> trace(t, display.pitch)
  end

  defp start_listening(state) do
    case state.audio.listen(self(), spectrum: wants_spectrum?(state)) do
      {:ok, ref} ->
        offset = max(now_ms() - state.base, (state.last_t || -1) + 1)
        state = %{state | ref: ref, offset: offset, last_t: nil, last_at: nil}
        {:reply, :ok, state |> set_status(:listening) |> schedule_frame()}

      {:error, reason} = error ->
        {:reply, error, set_status(state, {:error, reason})}
    end
  end

  # Ends the sounding note and turns the microphone off. The engine clock
  # carries on from the last reading.
  defp stop_listening(state) do
    t = now_t(state)
    if state.ref, do: state.audio.stop(state.ref)
    {tracker, events} = Tracker.release(state.tracker)

    %{state | tracker: tracker, ref: nil, frame_token: nil, last_t: t, last_at: now_ms()}
    |> emit(events, t)
    |> cancel_hold()
  end

  # ── Events and recording ──────────────────────────────────────────────

  defp emit(state, [], _t), do: state

  defp emit(state, events, t) do
    state.output.send_events(events)
    state = %{state | record: record_events(state.record, events, t)}

    case events |> Enum.filter(&note_event?/1) |> List.last() do
      nil -> state
      event -> %{state | sent: describe(event, state.settings.channel)}
    end
  end

  defp note_event?({kind, _note, _velocity}), do: kind == :note_on
  defp note_event?({kind, _note}), do: kind == :note_off

  defp record_events(nil, _events, _t), do: nil

  defp record_events(record, events, t) do
    at = max(t - record.t0, 0)

    Enum.reduce(events, record, fn
      {:note_on, midi, velocity}, record ->
        put_in(record.open[midi], {at, velocity})

      {:note_off, midi}, record ->
        case Map.pop(record.open, midi) do
          {{start, velocity}, open} ->
            %{record | open: open, notes: [take_note(midi, start, at, velocity) | record.notes]}

          {nil, _open} ->
            record
        end

      _other, record ->
        record
    end)
  end

  defp take_note(midi, start, stop, velocity),
    do: %{
      start_ms: start,
      dur_ms: max(stop - start, 1),
      midi: midi,
      velocity: velocity,
      unsure: false
    }

  # A pitch sample every 10 ms; one nil where the voice stops.
  defp trace(%{record: nil} = state, _t, _pitch), do: state

  defp trace(%{record: record} = state, t, pitch) do
    at = max(t - record.t0, 0)
    last = List.first(record.trace)

    cond do
      pitch == nil and (last == nil or elem(last, 1) == nil) ->
        state

      pitch != nil and record.trace_t != nil and at - record.trace_t < @trace_every_ms ->
        state

      true ->
        %{state | record: %{record | trace: [{at, pitch} | record.trace], trace_t: at}}
    end
  end

  # ── Hold timer ────────────────────────────────────────────────────────

  defp arm_hold(state) do
    state = cancel_hold(state)

    case Tracker.deadline(state.tracker) do
      nil ->
        state

      deadline ->
        timer = make_ref()
        delay = max(ceil(deadline - now_t(state)), 0)
        tref = Process.send_after(self(), {:hold, timer}, delay)
        %{state | hold_timer: {timer, tref}}
    end
  end

  defp cancel_hold(%{hold_timer: {_timer, tref}} = state) do
    Process.cancel_timer(tref)
    %{state | hold_timer: nil}
  end

  defp cancel_hold(state), do: state

  # ── Subscribers and frames ────────────────────────────────────────────

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      sub = %{mon: Process.monitor(pid), spectrum: false}
      %{state | subscribers: Map.put(state.subscribers, pid, sub)}
    end
  end

  defp wants_spectrum?(state), do: Enum.any?(state.subscribers, fn {_pid, s} -> s.spectrum end)

  defp sync_spectrum(state, before) do
    now = wants_spectrum?(state)
    if state.ref && now != before, do: state.audio.set_spectrum(state.ref, now)
    state
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    state = %{state | status: status}
    for {pid, _} <- state.subscribers, do: send(pid, {:engine, :status, status})
    broadcast_frame(state)
  end

  defp schedule_frame(state) do
    token = make_ref()
    Process.send_after(self(), {:frame, token}, @frame_ms)
    %{state | frame_token: token}
  end

  defp broadcast_frame(state) do
    if map_size(state.subscribers) > 0 do
      frame = frame(state)
      for {pid, _} <- state.subscribers, do: send(pid, {:engine, :frame, frame})
    end

    %{state | dirty: false}
  end

  defp frame(state) do
    display = Tracker.display(state.tracker)

    display
    |> Map.take([:pitch, :note, :cents, :hz, :db, :velocity, :voiced])
    |> Map.merge(%{t: state.last_t, mood: mood(state, display), sent: state.sent})
  end

  defp mood(%{status: {:error, _}}, _display), do: :no_mic
  defp mood(%{status: :paused}, _display), do: :paused
  defp mood(%{status: :off}, _display), do: :idle

  defp mood(state, %{voiced: true} = display) do
    cond do
      display.cents != nil and Tracker.tuning_label(display.cents) != "in tune" ->
        if display.cents < 0, do: :flat, else: :sharp

      display.db >= state.settings.sensitivity_db + @aria_above_gate_db ->
        :aria

      true ->
        :singing
    end
  end

  defp mood(_state, %{holding: true}), do: :singing

  defp mood(state, display) do
    if quiet_for?(state, @idle_after_ms) and
         display.db < state.settings.sensitivity_db - @near_gate_db,
       do: :idle,
       else: :listening
  end

  defp quiet_for?(%{last_voiced_t: nil}, _ms), do: true
  defp quiet_for?(state, ms), do: now_t(state) - state.last_voiced_t >= ms

  # ── Clock ─────────────────────────────────────────────────────────────

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Engine time now: the last reading's time plus the wall clock since it
  # arrived, or the wall clock since the engine started.
  defp now_t(%{last_t: nil} = state), do: max(now_ms() - state.base, state.offset)
  defp now_t(state), do: state.last_t + (now_ms() - state.last_at)
end
