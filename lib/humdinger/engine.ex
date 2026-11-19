defmodule Humdinger.Engine do
  @moduledoc """
  The real-time path: owns the microphone (`Humdinger.Audio`), runs the
  readings through a `Humdinger.Tracker`, sends the events to the output
  (`Humdinger.Output.send_events/1`) and tells subscribed screens what is
  happening. One per app, started from `Humdinger.App.on_start/0`, so it
  keeps listening while the singer plays FMutate in the foreground (with
  the background service, below).

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
  that asks with `spectrum/2` also gets `{:engine, :spectrum, spectrum}`,
  its `t` on engine time like the frames'; the microphone computes the
  spectrum only while someone wants it. `{:engine, :phrase_saved, phrase}`
  follows a recording stopped from the notification.

  A frame is `%{t, pitch, note, cents, hz, db, velocity, voiced, mood,
  sent, recording, background}`: the tracker's display
  (`Humdinger.Tracker.display/1`), the engine time `t` of the latest
  reading, Mimi's `mood`, `sent` (the last note on or off sent, as
  `Humdinger.Midi.describe/2` words it, or nil), whether a take is being
  recorded, and the background service: `:off`, `:running` or `{:error,
  reason}` (see below).

  Moods: `:no_mic` (the microphone failed or was refused), `:paused`,
  `:idle` (off, or nothing voiced for 5 s and the room quieter than 10 dB
  below the gate), `:listening` (otherwise not singing: a breath, or a
  sound near the gate), `:flat` / `:sharp` (a note sounds and the voice is
  10 cents or more off it, `Humdinger.Tracker.tuning_label/1`), `:aria`
  (singing 35 dB or more above the gate), `:singing`.

  ## Microphone errors

  A `listen/0` that fails (`:permission`, `:microphone_unavailable`, …) or
  an `{:error, reason}` while listening (`:device_lost`, `:input_error`, …)
  ends the sounding note and becomes status `{:error, reason}`, mood
  `:no_mic`. `listen/0` or `resume/0` tries again.

  ## In the background

  Android silences a backgrounded app's microphone unless a foreground
  service runs, and Android 14 lets an app start one only from the
  foreground. So every successful `listen/0` or `resume/0` (the singer
  pressed something: the app is in front) starts `MobBackground` in
  `:microphone` mode unless it already runs. The notification
  (`Humdinger.Engine.Notice.notification/1`) follows the engine: its text at
  most 4 times a second and only when it changes, its title and buttons at
  once.

  - `pause/0` keeps the service (and the notification, with Resume), so
    the singer can resume from the shade without opening the app: a
    running service lets the microphone start from the background.
  - `stop/0` stops it. So does the notification's Stop.
  - A microphone error keeps it, showing "no microphone" and Resume.
  - The buttons arrive as `{:mob_background, {:action, id}}`: Pause,
    Resume (also after an error), Record, Stop rec and Stop act as the
    functions of those names; Stop rec saves the take as a phrase
    (`Humdinger.Phrase.from_take/2`, `Humdinger.Phrases.save/1`), since no
    screen is there to review it, and sends subscribers
    `{:engine, :phrase_saved, phrase}`.
  - If the service can't start (`MobBackground.start/2` errors, or
    `{:mob_background, {:error, :foreground_refused | :timeout}}` arrives)
    the engine keeps listening in the foreground and the frames'
    `background` is `{:error, reason}`, so Live can say listening will stop
    when the app leaves the screen. The next `listen/0`/`resume/0` tries
    again. On Android 13+ the notification needs the `:notifications`
    permission: without it the service still runs, unseen (the Live screen
    asks for it before the first listen; the engine can't tell).

  ## Settings

  `update_settings/1` saves through `Humdinger.Settings.update/1` and
  reconfigures the tracker (`Humdinger.Tracker.configure/2`): changing the
  mode, scale, octave, transpose, bend range or channel first turns the
  sounding note off. A channel change is passed on with
  `output.configure(channel: n)` after those note offs, so they still go
  out on the old channel.

  ## Recording

  `record_start/0` begins a take at the current engine time;
  `record_stop/0` returns a `Humdinger.Take` (`Humdinger.Engine.Recording`):
  the notes the engine sent (from note on/off pairs, ms from the start; a
  note sounding at the start begins at 0, one still sounding at the stop
  ends there), the sung pitch trace (the tracker's smoothed pitch after
  octave and transpose, so it lines up with the notes, at most one every
  20 ms, a single nil where the voice stops), the scale in Scale mode (nil
  in Open), `source: :hum` and `recorded_at`. A take without notes is
  `{:error, :empty}`. A take that reaches 10 minutes
  (`Humdinger.Engine.Recording.max_ms/0`) is finished and saved as a
  phrase, as Stop rec in the notification does (`{:engine, :phrase_saved,
  phrase}`), so a forgotten recording can't grow without bound.

  ## When the engine restarts

  `Humdinger.Realtime` supervises Output and the engine (`rest_for_one`:
  an Output restart restarts the engine too). However the engine ends,
  `terminate/2` turns the sounding note off, stops the microphone and the
  notification. The new engine starts `:off`, with no subscribers and no
  take (a take in progress is lost). A screen that `watch/0`ed gets
  `:DOWN` on its monitor, frames stop until it watches again; it then gets
  `{:engine, :status, :off}` and should `listen/0` again if it was
  listening (Live does, and pauses again if it was paused).
  """

  use GenServer
  require Logger

  alias Humdinger.{Audio, Midi, Phrase, Phrases, Settings, Take, Tracker}
  alias Humdinger.Engine.{Notice, Recording}

  @frame_ms 33
  @notice_every_ms 250
  @idle_after_ms 5_000
  @near_gate_db 10
  @aria_above_gate_db 35

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
          sent: String.t() | nil,
          recording: boolean(),
          background: :off | :running | {:error, term()}
        }

  # ── API ───────────────────────────────────────────────────────────────

  @doc """
  Start the engine. Options: `audio:` (default `Humdinger.Audio.impl/0`:
  the NIF on the phone, `Humdinger.Audio.Fake` in host tests), `output:`
  (default `config :humdinger, :output`, else `Humdinger.Output`),
  `background:` (default `config :humdinger, :background`, else
  `MobBackground`), `name:` (default `Humdinger.Engine`), `max_take_ms:`
  (default `Humdinger.Engine.Recording.max_ms/0`), `stall_ms:` (the
  tracker's, see `Humdinger.Tracker.new/2`; screen tests that sing in bursts
  raise it). Settings come from `Humdinger.Settings.load/0`. The engine
  starts `:off`; `listen/0` turns the microphone on.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Subscribe the calling process (as `subscribe/1`) and monitor the engine:
  `{:ok, monitor}`, or `{:error, :down}` while there is no engine (it is
  being restarted). A screen keeps the monitor; on its `:DOWN` it calls
  `watch/0` again until it succeeds (see "When the engine restarts").
  """
  @spec watch(GenServer.server()) :: {:ok, reference()} | {:error, :down}
  def watch(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :down}

      pid ->
        monitor = Process.monitor(pid)

        try do
          :ok = subscribe(pid, self())
          {:ok, monitor}
        catch
          :exit, _down ->
            Process.demonitor(monitor, [:flush])
            {:error, :down}
        end
    end
  end

  @doc "Get the status now and frames from now on (see the moduledoc)."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid), do: GenServer.call(server, {:subscribe, pid})

  @doc "Turn the spectrum relay on or off for a subscriber (subscribing it if needed)."
  @spec spectrum(GenServer.server(), pid(), boolean()) :: :ok
  def spectrum(server \\ __MODULE__, pid, on?) when is_boolean(on?),
    do: GenServer.call(server, {:spectrum, pid, on?})

  @doc """
  Turn the microphone on, and the background service with it. `{:error,
  reason}` when the microphone can't (e.g. `:permission`). Call it from the
  foreground.
  """
  @spec listen(GenServer.server()) :: :ok | {:error, term()}
  def listen(server \\ __MODULE__), do: GenServer.call(server, :listen)

  @doc """
  Stop sending: the sounding note ends and the microphone turns off; the
  background service stays, so Resume works from the notification. Only
  while listening.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)

  @doc "Listen again after `pause/0` or a microphone error. Does nothing otherwise."
  @spec resume(GenServer.server()) :: :ok | {:error, term()}
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  @doc "Everything off: the sounding note, the microphone and the background service."
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

  # ── Server ────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Exits from the supervisor reach terminate/2, which ends the sounding note.
    Process.flag(:trap_exit, true)
    settings = Settings.load()

    {:ok,
     %{
       audio: Keyword.get_lazy(opts, :audio, &Audio.impl/0),
       output: Keyword.get_lazy(opts, :output, &default_output/0),
       background_mod: Keyword.get_lazy(opts, :background, &default_background/0),
       output_subscribed: false,
       destination: nil,
       settings: settings,
       tracker: Tracker.new(settings, Keyword.take(opts, [:stall_ms])),
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
       record: nil,
       max_take_ms: Keyword.get(opts, :max_take_ms, Recording.max_ms()),
       background: :off,
       notice: nil,
       notice_at: nil,
       # A player has the output (`{:output, :session, :active}`): the
       # singer's events go nowhere until it is `:idle` again.
       held: false
     }}
  end

  defp default_output, do: Application.get_env(:humdinger, :output, Humdinger.Output)
  defp default_background, do: Application.get_env(:humdinger, :background, MobBackground)

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
  def handle_call(:listen, _from, state), do: reply(start_listening(state))

  def handle_call(:pause, _from, state), do: {:reply, :ok, pause_listening(state)}
  def handle_call(:resume, _from, state), do: reply(resume_listening(state))
  def handle_call(:stop, _from, state), do: {:reply, :ok, stop_all(state)}
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

  def handle_call(:record_start, _from, state), do: {:reply, :ok, start_recording(state)}

  def handle_call(:record_stop, _from, state) do
    {reply, state} = stop_recording(state)
    {:reply, reply, state}
  end

  def handle_call(:recording?, _from, state), do: {:reply, state.record != nil, state}

  @impl GenServer
  def handle_info({:hum_audio, ref, message}, %{ref: ref} = state) when ref != nil,
    do: audio(message, state)

  # A message from an earlier listen (stale) or a reference we don't hold.
  def handle_info({:hum_audio, _ref, _message}, state), do: {:noreply, state}

  def handle_info({:mob_background, {:action, id}}, state)
      when id in [:pause, :resume, :record, :record_stop, :stop],
      do: {:noreply, background(id, state)}

  def handle_info({:mob_background, {:error, reason}}, state)
      when reason in [:foreground_refused, :timeout],
      do: {:noreply, background_error(reason, state)}

  def handle_info({:output, :destinations, destinations}, state) do
    {:noreply, %{state | destination: Notice.destination(destinations)}}
  end

  def handle_info({:frame, token}, %{frame_token: token} = state) when token != nil do
    state = if state.dirty, do: broadcast_frame(state), else: state
    {:noreply, state |> sync_notice(false) |> schedule_frame()}
  end

  def handle_info({:frame, _stale}, state), do: {:noreply, state}

  def handle_info({:hold, timer}, %{hold_timer: {timer, _tref}} = state) do
    t = now_t(state)
    {tracker, events} = Tracker.tick(state.tracker, t)
    state = %{state | tracker: tracker, hold_timer: nil, dirty: true}
    {:noreply, state |> emit(events, t) |> arm_hold()}
  end

  def handle_info({:hold, _stale}, state), do: {:noreply, state}

  # A player has the output, or gives it back (see `Humdinger.Output`). On
  # acquire Output released the singer's note; the tracker forgets it too,
  # so the next sung note starts afresh, during or after the session.
  def handle_info({:output, :session, what}, state) do
    {tracker, _released} = Tracker.release(state.tracker)
    {:noreply, %{state | held: what == :active, tracker: tracker} |> cancel_hold()}
  end

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

  # However the engine ends (stopped by its supervisor, or crashed), the
  # note it left sounding is turned off on every destination, the
  # microphone stops and the notification goes away. A screen sees `:DOWN`
  # on its `watch/0` monitor. The release goes to Output and waits for it
  # (`sync`), so it is out before the supervisor stops Output. When Output
  # is the one that died, nothing can be sent here: Output's own
  # `terminate/2` has silenced every destination.
  @impl GenServer
  def terminate(_reason, state) do
    if state.ref, do: state.audio.stop(state.ref)
    {_tracker, events} = Tracker.release(state.tracker)

    if events != [] and not state.held do
      state.output.send_events(events)
      sync_output(state)
    end

    if state.background == :running, do: state.background_mod.stop()
    :ok
  end

  defp reply({result, state}), do: {:reply, result, state}

  # Waits until Output has what this process sent it. Output may be gone
  # (restarting): then there is nothing to wait for.
  defp sync_output(%{output: output}) do
    if Code.ensure_loaded?(output) and function_exported?(output, :sync, 0), do: output.sync()
  catch
    :exit, _ -> :ok
  end

  # ── Listening ─────────────────────────────────────────────────────────

  defp start_listening(state) do
    case state.audio.listen(self(), spectrum: wants_spectrum?(state)) do
      {:ok, ref} ->
        offset = max(now_ms() - state.base, (state.last_t || -1) + 1)
        state = %{state | ref: ref, offset: offset, last_t: nil, last_at: nil}

        state =
          state
          |> subscribe_output()
          |> start_background()
          |> set_status(:listening)
          |> schedule_frame()

        {:ok, state}

      {:error, reason} = error ->
        {error, set_status(state, {:error, reason})}
    end
  end

  defp resume_listening(%{status: status} = state) when status == :paused or is_tuple(status),
    do: start_listening(state)

  defp resume_listening(state), do: {:ok, state}

  defp pause_listening(%{status: :listening} = state),
    do: state |> stop_listening() |> set_status(:paused)

  defp pause_listening(state), do: state

  defp stop_all(%{status: :off} = state), do: stop_background(state)
  defp stop_all(state), do: state |> stop_listening() |> stop_background() |> set_status(:off)

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

  # Output tells the engine where the notes go (for the notification) and
  # when a player has the output. A double without `subscribe/1` /
  # `follow_session/1` is fine: the notice leaves the name out, and nothing
  # holds the singer.
  defp subscribe_output(%{output_subscribed: false, output: output} = state) do
    if Code.ensure_loaded?(output) and function_exported?(output, :subscribe, 1) do
      :ok = output.subscribe(self())
      if function_exported?(output, :follow_session, 1), do: :ok = output.follow_session(self())
      %{state | output_subscribed: true}
    else
      state
    end
  end

  defp subscribe_output(state), do: state

  # ── Audio ─────────────────────────────────────────────────────────────

  defp audio({:readings, readings}, state) do
    state = Enum.reduce(readings, state, &reading/2)
    {:noreply, %{state | last_at: now_ms(), dirty: true} |> arm_hold()}
  end

  defp audio({:spectrum, spectrum}, state) do
    spectrum = %{spectrum | t: spectrum.t + state.offset}

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
    state = %{state | tracker: tracker, last_t: t, last_voiced_t: last_voiced_t}
    state = emit(state, events, t)

    case state.record do
      nil ->
        state

      record ->
        state = %{state | record: Recording.trace(record, t, display.pitch)}
        if Recording.full?(record, t, state.max_take_ms), do: save_recording(state), else: state
    end
  end

  # ── Events and recording ──────────────────────────────────────────────

  defp emit(state, [], _t), do: state

  # While a player has the output the singer's events go nowhere: not to
  # Output (it would drop them) and not into a take.
  defp emit(%{held: true} = state, _events, _t), do: state

  defp emit(state, events, t) do
    state.output.send_events(events)

    state =
      if state.record,
        do: %{state | record: Recording.events(state.record, events, t)},
        else: state

    case events |> Enum.filter(&note_event?/1) |> List.last() do
      nil -> state
      event -> %{state | sent: Midi.describe(event, state.settings.channel)}
    end
  end

  defp note_event?({kind, _note, _velocity}), do: kind == :note_on
  defp note_event?({kind, _note}), do: kind == :note_off

  defp start_recording(%{record: nil} = state) do
    display = Tracker.display(state.tracker)
    sounding = if display.note, do: {display.note, display.velocity}
    scale = if state.settings.mode == :scale, do: state.settings.scale
    record = Recording.start(now_t(state), sounding, scale)
    %{state | record: record, dirty: true} |> sync_notice(true)
  end

  defp start_recording(state), do: state

  defp stop_recording(%{record: nil} = state), do: {{:error, :not_recording}, state}

  defp stop_recording(state) do
    reply = Recording.finish(state.record, now_t(state))
    {reply, %{state | record: nil, dirty: true} |> sync_notice(true)}
  end

  # Stop rec in the notification: no screen is there to review the take, so
  # it is saved as a phrase.
  defp save_recording(state) do
    {result, state} = stop_recording(state)

    with {:ok, take} <- result,
         {:ok, phrase} <- Phrases.save(Phrase.from_take(take)) do
      for {pid, _} <- state.subscribers, do: send(pid, {:engine, :phrase_saved, phrase})
    else
      {:error, :empty} -> :ok
      {:error, reason} -> Logger.warning("Engine: couldn't save the take: #{inspect(reason)}")
    end

    state
  end

  # ── Background service ────────────────────────────────────────────────

  defp background(:pause, state), do: pause_listening(state)
  defp background(:resume, state), do: state |> resume_listening() |> elem(1)
  defp background(:record, state), do: start_recording(state)
  defp background(:record_stop, state), do: save_recording(state)
  defp background(:stop, state), do: stop_all(state)

  # A late report about a service already stopped changes nothing.
  defp background_error(reason, %{background: :running} = state) do
    :ok = state.background_mod.stop()
    Logger.warning("Engine: Android refused the background service (#{reason})")
    broadcast_frame(%{state | background: {:error, reason}, notice: nil})
  end

  defp background_error(_reason, state), do: state

  defp start_background(%{background: :running} = state), do: state

  defp start_background(state) do
    notice = notice(%{state | status: :listening})

    case state.background_mod.start(self(),
           mode: :microphone,
           notification: Notice.notification(notice)
         ) do
      :ok ->
        %{state | background: :running, notice: notice, notice_at: now_ms()}

      {:error, reason} ->
        Logger.warning("Engine: no background service: #{inspect(reason)}")
        %{state | background: {:error, reason}}
    end
  end

  defp stop_background(%{background: :running} = state) do
    :ok = state.background_mod.stop()
    %{state | background: :off, notice: nil}
  end

  defp stop_background(state), do: %{state | background: :off}

  # The notification follows the engine: forced for a change of status or
  # recording (title and buttons), else at most every 250 ms on a change.
  defp sync_notice(%{background: :running} = state, force?) do
    notice = notice(state)

    cond do
      notice == state.notice ->
        state

      force? or now_ms() - state.notice_at >= @notice_every_ms ->
        case state.background_mod.update(Notice.notification(notice)) do
          :ok -> %{state | notice: notice, notice_at: now_ms()}
          {:error, :not_running} -> %{state | background: :off, notice: nil}
        end

      true ->
        state
    end
  end

  defp sync_notice(state, _force?), do: state

  defp notice(state) do
    Notice.build(
      state.status,
      state.record != nil,
      Tracker.display(state.tracker),
      state.destination,
      state.settings.channel
    )
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
    state |> broadcast_frame() |> sync_notice(true)
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
    |> Map.merge(%{
      t: state.last_t,
      mood: mood(state, display),
      sent: state.sent,
      recording: state.record != nil,
      background: state.background
    })
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
