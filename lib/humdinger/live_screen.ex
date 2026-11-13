defmodule Humdinger.LiveScreen do
  @moduledoc """
  Live (home, board `02-live`): hum into the phone, see the note, send MIDI.

  Top to bottom: the destination pill (where the MIDI goes; opens Output)
  and the Settings button; the piano strip following the voice; Mimi
  beside the big note name, its velocity, the tuning meter and the cents
  line; the pitch roll (the last 4 s of the sung line and the notes sent)
  with the Spectrum chip; Scale | Open + bend, the scale picker, octave
  and transpose; Pause / Resume, the record button and Phrases.

  ## Listening

  On mount Live subscribes to `Humdinger.Engine` and Output, asks for the
  microphone (then notifications, for the background notice; a refusal
  there changes nothing here) and calls `Engine.listen/0`. A refused
  microphone, an engine error or a build without the audio engine shows
  Mimi without a microphone, what went wrong and "Try again" (and "Open
  settings" once the microphone was refused). On first launch
  (`first_run_done` false) Live opens `Humdinger.FirstRunScreen` first
  and asks for the microphone when it reports back with `{:first_run,
  :done}`.

  Live watches the engine (`Engine.watch/0`). If the engine goes down, its
  supervisor starts a new one, `:off`; Live watches that one (retrying
  every 100 ms until it is up), reloads the settings and puts it back as
  it was: listening, or listening then paused. A recording in progress is
  lost with the old engine.

  ## Frames

  Engine frames (≤ 30/s) go into a `Humdinger.LiveFeed` and arm a
  token-guarded 33 ms tick; the tick takes the latest frame and rebuilds
  only the canvases whose inputs changed (memoised by a key per canvas),
  so a silent room after the roll has emptied costs nothing but the
  message. The screen is kept awake while the voice is heard and allowed
  to sleep once Mimi idles, pauses or loses the microphone. Mimi blinks
  every few seconds on her own timer.

  ## Recording

  The record button calls `Engine.record_start/0`; a second tap calls
  `record_stop/0` and opens the phrase review (`Humdinger.PhraseScreen`,
  `%{phrase: Phrase.from_take(take), return_to: self()}`, unsaved). An
  empty take shows a note instead. `:hum_again` (sent by the review)
  starts a new recording.

  Phrases, Output and the phrase review are other screens; while one isn't
  in the build (`Code.ensure_loaded?/1`), its button says so instead of
  navigating.
  """

  use Mob.Screen

  import Mob.Canvas, only: [circle: 4, rect: 5, path: 2]
  import Humdinger.Controls

  alias Humdinger.{
    Audio,
    Engine,
    FirstRunScreen,
    LiveFeed,
    Mimi,
    Music,
    Phrase,
    Scale,
    SettingsSheet,
    SpectrumScreen,
    Style,
    Tracker
  }

  alias Humdinger.Views.{PianoStrip, PitchRoll, TuningMeter}

  @frame_ms 33
  @roll_window_ms 4_000
  @roll {350, 256}
  @strip_w 334
  @mimi {112, 106}
  @meter_w 206
  @strip_span 14
  @blink_ms 140
  @toast_ms 3_500
  @drag_quiet_ms 1_000
  @rewatch_ms 100

  @phrase_screen Humdinger.PhraseScreen
  @phrases_screen Humdinger.PhrasesScreen
  @output_screen Humdinger.OutputScreen

  # ── Mount ─────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    {:ok, engine_mon} = Engine.watch()
    destinations = subscribe_output()
    settings = Engine.settings()

    socket =
      Mob.Socket.assign(socket,
        settings: settings,
        status: Engine.status(),
        mic: :unknown,
        audio_missing: false,
        frame: idle_frame(),
        shown: idle_frame(),
        feed: LiveFeed.new(),
        last_note: nil,
        center: 69.0,
        window: window_for(69, nil),
        room_db: nil,
        voice_db: nil,
        blink: 0,
        blink_token: nil,
        tick_token: nil,
        destinations: destinations,
        sheet: nil,
        sens_drag: nil,
        drag_token: nil,
        recording: recording_state(Engine.recording?()),
        engine_mon: engine_mon,
        rec_changed_at: now_ms() - 1_000,
        rec_token: nil,
        toast: nil,
        toast_token: nil,
        awake: false,
        ops: %{},
        op_keys: %{}
      )
      |> center_on_range()
      |> schedule_blink()
      |> schedule_rec_tick()

    socket =
      if settings.first_run_done do
        ask_microphone(socket)
      else
        send(self(), :first_run)
        socket
      end

    {:ok, refresh(socket)}
  end

  defp strip_w, do: @strip_w
  defp meter_w, do: @meter_w

  defp idle_frame,
    do: %{
      t: nil,
      pitch: nil,
      note: nil,
      cents: nil,
      hz: nil,
      db: -90.0,
      velocity: nil,
      voiced: false,
      mood: :idle,
      sent: nil
    }

  defp subscribe_output do
    output = output()
    output.subscribe(self())
    output.destinations()
  catch
    :exit, _ -> []
  end

  defp output, do: Application.get_env(:humdinger, :output, Humdinger.Output)

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    {roll_w, roll_h} = @roll
    {mimi_w, mimi_h} = @mimi
    s = assigns.settings
    a = assigns

    output_tap = {self(), :output}
    settings_tap = {self(), :settings}
    spectrum_tap = {self(), :spectrum}
    picker_tap = {self(), :scale_picker}
    pause_tap = {self(), :pause}
    record_tap = {self(), :record}
    phrases_tap = {self(), :phrases}

    modes = [
      %{label: "Scale", tap: {self(), {:set, :mode, :scale}}, selected: s.mode == :scale},
      %{label: "Open + bend", tap: {self(), {:set, :mode, :open}}, selected: s.mode == :open}
    ]

    top = ~MOB"""
    <Row height={44} gap={8}>
      {pill(a, output_tap)}
      <Box
        width={44}
        height={44}
        corner_radius={22}
        background={Style.surface()}
        align="center"
        on_tap={settings_tap}
        on_press_out={held()}
      >
        <Canvas width={20} height={20} draw={SettingsSheet.icon_ops()} />
      </Box>
    </Row>
    """

    spectrum =
      button("Spectrum ›", spectrum_tap,
        kind: :header,
        height: 36,
        radius: 18,
        background: Style.bg(),
        text_size: 12,
        color: 0xFFE4DFEE
      )

    roll = ~MOB"""
    <Box width={roll_w} height={roll_h} align="bottom_trailing">
      <Canvas width={roll_w} height={roll_h} draw={a.ops.roll} />
      <Box fill_width={false} padding={8}>
        {spectrum}
      </Box>
    </Box>
    """

    picker =
      button(Scale.name(s.scale) <> " ▾", picker_tap,
        kind: :header,
        height: 46,
        padding: 14,
        color: if(s.mode == :scale, do: Style.text(), else: Style.muted())
      )

    controls = ~MOB"""
    <Column gap={10}>
      <Row gap={8}>
        {segmented(modes)}
        {picker}
      </Row>
      <Row gap={8}>
        {shift_stepper("octave", s.octave, :octave, -3..3)}
        {shift_stepper("transp", s.transpose, :transpose, -12..12)}
      </Row>
    </Column>
    """

    actions = ~MOB"""
    <Row>
      <Box
        width={96}
        height={56}
        corner_radius={16}
        background={Style.surface()}
        align="center"
        on_tap={pause_tap}
        on_press_out={held()}
      >
        {pause_label(a.status)}
      </Box>
      <Spacer />
      <Canvas
        width={88}
        height={88}
        draw={record_ops(a.recording)}
        on_tap={record_tap}
        on_press_out={held()}
      />
      <Spacer />
      <Box
        width={96}
        height={56}
        corner_radius={16}
        background={Style.surface()}
        align="center"
        on_tap={phrases_tap}
        on_press_out={held()}
      >
        <Text text="Phrases" font={:semibold} text_size={13} text_color={Style.text()} />
      </Box>
    </Row>
    """

    page(
      [
        top,
        ~MOB(<Spacer size={11} />),
        ~MOB"""
        <Box align="center">
          <Canvas width={strip_w()} height={PianoStrip.height()} draw={a.ops.strip} />
        </Box>
        """,
        ~MOB(<Spacer size={10} />),
        ~MOB"""
        <Row height={120} gap={16} padding_left={8} padding_right={8}>
          <Canvas width={mimi_w} height={mimi_h} draw={a.ops.mimi} />
          {note_panel(a)}
        </Row>
        """,
        ~MOB(<Spacer size={10} />),
        roll,
        ~MOB(<Spacer size={10} />),
        controls,
        ~MOB(<Spacer />),
        ~MOB"""
        <Text
          height={18}
          fill_width={true}
          text={status_line(a) || ""}
          font={:mono_semibold}
          text_size={12}
          text_align="center"
          text_color={if(a.recording, do: Style.danger_text(), else: Style.text_2())}
        />
        """,
        ~MOB(<Spacer size={4} />),
        actions,
        sheets(a)
      ],
      padding_bottom: 8,
      gap: nil
    )
  end

  defp pill(a, tap) do
    {dot, name, rest} = destination_summary(a.destinations, a.settings.channel)

    ~MOB"""
    <Box
      weight={1}
      height={44}
      corner_radius={22}
      background={Style.surface()}
      padding_left={14}
      padding_right={14}
      on_tap={tap}
      on_press_out={held()}
    >
      <Row height={44} gap={8}>
        <Box width={8} height={8} corner_radius={4} background={dot} />
        <Text text={name} font={:semibold} text_size={13} text_color={Style.text()} max_lines={1} />
        <Text text={rest} font={:mono} text_size={11} text_color={Style.muted()} max_lines={1} />
      </Row>
    </Box>
    """
  end

  @doc """
  The pill's dot colour, name and the rest of the line: the first enabled
  destination ("FMutate A"), then the others and the channel ("+ MIDI port
  · ch 1"). Lime when the first one is reachable, amber when it isn't,
  faint when nothing is on.
  """
  def destination_summary(destinations, channel) do
    case Enum.filter(destinations, & &1.enabled) do
      [] ->
        {Style.faint(), "Not sending", "pick an output · ch #{channel}"}

      [first | others] ->
        dot = if first.available, do: Style.fm(), else: Style.warn()

        rest =
          case others do
            [] -> "ch #{channel}"
            [other] -> "+ #{short_name(other.id)} · ch #{channel}"
            more -> "+ #{length(more)} more · ch #{channel}"
          end

        {dot, first.name, rest}
    end
  end

  defp short_name(:fmutate), do: "FMutate"
  defp short_name(:port), do: "MIDI port"
  defp short_name(:usb), do: "USB"
  defp short_name(:bt), do: "Bluetooth"

  defp note_panel(a) do
    case trouble(a) do
      nil -> note_readout(a)
      trouble -> trouble_panel(trouble)
    end
  end

  defp note_readout(a) do
    shown = a.shown
    note = shown.note || a.last_note

    {name, color} =
      cond do
        shown.note -> {Music.note_name(shown.note), Style.pitch_color(shown.note)}
        note -> {Music.note_name(note), Style.faint()}
        true -> {"–", Style.faint()}
      end

    vel = if shown.note && shown.velocity, do: "vel #{shown.velocity}", else: ""

    ~MOB"""
    <Column weight={1} gap={6}>
      <Row gap={10} align={:bottom}>
        <Text text={name} font={:display} text_size={64} line_height={0.9} text_color={color} />
        <Text text={vel} font={:mono_semibold} text_size={12} text_color={Style.muted()} />
      </Row>
      <Canvas width={meter_w()} height={TuningMeter.height()} draw={a.ops.meter} />
      <Text text={cents_line(a)} font={:mono_semibold} text_size={11} text_color={Style.text_2()} />
    </Column>
    """
  end

  defp trouble_panel({title, body, actions}) do
    ~MOB"""
    <Column weight={1} gap={6}>
      <Text text={title} font={:semibold} text_size={16} text_color={Style.text()} />
      <Text text={body} text_size={12} line_height={1.35} text_color={Style.muted()} />
      <Row gap={8}>
        {for {label, tag} <- actions do
          button(label, {self(), tag}, kind: :flat, height: 34, radius: 17)
        end}
      </Row>
    </Column>
    """
  end

  @doc false
  # What keeps Live from hearing the singer, as {title, body, actions}, or nil.
  def trouble(a) do
    cond do
      a.audio_missing ->
        {"No audio engine", "This build of Humdinger can't use the microphone yet.", []}

      a.mic == :denied or a.status == {:error, :permission} ->
        {"Mimi can't hear you", "Allow the microphone so Humdinger can follow your voice.",
         [{"Try again", :retry_mic}, {"Open settings", :app_settings}]}

      match?({:error, _}, a.status) ->
        {"The microphone stopped", "Something else may be using it.", [{"Try again", :retry_mic}]}

      true ->
        nil
    end
  end

  defp cents_line(a) do
    shown = a.shown

    cond do
      a.status == :paused -> "paused · not sending"
      shown.cents != nil -> Tracker.cents_label(shown.cents)
      shown.mood == :idle -> "hum something"
      true -> "listening…"
    end
  end

  defp shift_stepper(label, value, field, lo..hi//_) do
    down = {self(), {:set, field, max(value - 1, lo)}}
    up = {self(), {:set, field, min(value + 1, hi)}}
    stepper(nil, "#{label} #{signed(value)}", down, up, height: 46)
  end

  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n) when n < 0, do: "−#{-n}"
  defp signed(_n), do: "0"

  defp pause_label(:paused) do
    ~MOB"""
    <Row gap={8} fill_width={false}>
      <Canvas width={12} height={14} draw={play_ops()} />
      <Text text="Resume" font={:semibold} text_size={13} text_color={Style.text()} />
    </Row>
    """
  end

  defp pause_label(_status) do
    ~MOB"""
    <Row gap={8} fill_width={false}>
      <Row gap={3} fill_width={false}>
        <Box width={4} height={14} corner_radius={1} background={Style.text()} />
        <Box width={4} height={14} corner_radius={1} background={Style.text()} />
      </Row>
      <Text text="Pause" font={:semibold} text_size={13} text_color={Style.text()} />
    </Row>
    """
  end

  defp play_ops, do: [path([{0, 0}, {12, 7}, {0, 14}], color: Style.text(), fill: true)]

  @doc false
  # The record button: a 76 coral disc in a 6 dp dark ring; a dot to start,
  # a square to stop.
  def record_ops(recording) do
    inner =
      if recording,
        do: rect(33, 33, 22, 22, color: Style.bg(), fill: true, radius: 4),
        else: circle(44, 44, 13, color: Style.bg(), fill: true)

    [
      circle(44, 44, 44, color: 0xFF2A1A1A, fill: true),
      circle(44, 44, 38, color: Style.danger(), fill: true),
      inner
    ]
  end

  defp status_line(%{recording: %{elapsed: s}}),
    do: "recording · #{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"

  defp status_line(%{toast: toast}) when is_binary(toast), do: toast

  defp status_line(%{shown: shown}) do
    case Map.get(shown, :background) do
      {:error, _} -> "listening stops when you leave the app"
      _ -> nil
    end
  end

  defp sheets(%{sheet: :settings} = a), do: [SettingsSheet.sheet(sheet_data(a))]
  defp sheets(%{sheet: :scale} = a), do: [scale_sheet(a.settings)]
  defp sheets(_a), do: []

  defp sheet_data(a) do
    %{settings: a.settings, note: a.shown.note, mimi_ops: a.ops.mini, bar_ops: a.ops.bar}
  end

  defp scale_sheet(s) do
    dismiss = {self(), :scale_sheet}
    done = {self(), :scale_done}
    chromatic = s.scale.mode == :chromatic

    roots = ~MOB"""
    <Wrap spacing={6} run_spacing={6} fill_width={true}>
      {for root <- 0..11 do
        chip(
          root_label(root, scale_mode(s.scale)),
          not chromatic and s.scale.root == root,
          {self(), {:set, :scale, Scale.new(root, scale_mode(s.scale))}},
          dim: chromatic
        )
      end}
    </Wrap>
    """

    modes = ~MOB"""
    <Wrap spacing={6} run_spacing={6} fill_width={true}>
      {for mode <- Scale.modes() do
        chip(
          mode_label(mode),
          s.scale.mode == mode,
          {self(), {:set, :scale, Scale.new(s.scale.root, mode)}},
          font: :semibold
        )
      end}
    </Wrap>
    """

    sheet(
      "scale",
      dismiss,
      [
        sheet_title(Scale.name(s.scale), font: :display, size: 24, done: done, padding_bottom: 0),
        heading("ROOT"),
        roots,
        heading("MODE"),
        modes
      ],
      detents: [:medium, :large],
      scroll: true,
      width: content_width(),
      padding_top: 4,
      gap: 14
    )
  end

  # A root spelled as the scale's name spells it ("Gb" in Gb Lydian).
  defp root_label(root, mode),
    do: Scale.new(root, mode) |> Scale.name() |> String.split(" ") |> hd()

  # Picking a root while Chromatic is on turns the scale back to major.
  defp scale_mode(%Scale{mode: :chromatic}), do: :major
  defp scale_mode(%Scale{mode: mode}), do: mode

  defp mode_label(mode), do: Scale.new(0, mode) |> Scale.name() |> String.replace_prefix("C ", "")

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:engine, :frame, frame}, socket) do
    a = socket.assigns

    {room, voice} =
      if frame.voiced,
        do: {a.room_db, smooth(a.voice_db, frame.db, 0.2)},
        else: {smooth(a.room_db, frame.db, 0.1), a.voice_db}

    socket =
      Mob.Socket.assign(socket,
        frame: frame,
        feed: LiveFeed.push(a.feed, frame),
        last_note: frame.note || a.last_note,
        room_db: room,
        voice_db: voice
      )

    {:noreply, socket |> sync_recording(Map.get(frame, :recording)) |> schedule_tick()}
  end

  def handle_info({:engine, :status, status}, socket) do
    socket = Mob.Socket.assign(socket, :status, status)
    {:noreply, socket |> keep_awake() |> refresh()}
  end

  # A recording stopped from the notification was saved.
  def handle_info({:engine, :phrase_saved, phrase}, socket) do
    name = Map.get(phrase, :name, Phrase.default_name())
    socket = Mob.Socket.assign(socket, recording: nil, rec_token: nil, rec_changed_at: now_ms())
    {:noreply, toast(socket, "Saved “#{name}”")}
  end

  def handle_info({:engine, _other, _payload}, socket), do: {:noreply, socket}

  # The engine went down; its supervisor starts a new one, `:off` and
  # without subscribers. Watch it again, then put it back the way the
  # singer had it: listening, or paused.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{assigns: %{engine_mon: mon}} = socket) do
    send(self(), :engine_rewatch)
    {:noreply, Mob.Socket.assign(socket, :engine_mon, nil)}
  end

  def handle_info(:engine_rewatch, %{assigns: %{engine_mon: nil}} = socket) do
    case Engine.watch() do
      {:ok, mon} ->
        was = socket.assigns.status

        socket =
          socket
          |> Mob.Socket.assign(
            engine_mon: mon,
            recording: nil,
            rec_token: nil,
            frame: idle_frame(),
            status: Engine.status()
          )
          |> reload_settings()
          |> restore_listening(was)

        {:noreply, refresh(socket)}

      {:error, :down} ->
        Process.send_after(self(), :engine_rewatch, @rewatch_ms)
        {:noreply, socket}
    end
  end

  def handle_info(:engine_rewatch, socket), do: {:noreply, socket}

  def handle_info({:tick, token}, %{assigns: %{tick_token: token}} = socket) do
    a = socket.assigns
    frame = a.frame

    socket =
      Mob.Socket.assign(socket,
        tick_token: nil,
        shown: frame,
        center: ease_center(a.center, roll_target(a.feed)),
        window: follow_window(a.window, frame.note)
      )

    {:noreply, socket |> keep_awake() |> refresh()}
  end

  def handle_info({:tick, _stale}, socket), do: {:noreply, socket}

  def handle_info({:blink, token, phase}, %{assigns: %{blink_token: token}} = socket) do
    socket =
      case phase do
        :close -> socket |> Mob.Socket.assign(:blink, 1) |> schedule_blink(:open)
        :open -> socket |> Mob.Socket.assign(:blink, 0) |> schedule_blink()
      end

    {:noreply, refresh(socket)}
  end

  def handle_info({:blink, _stale, _phase}, socket), do: {:noreply, socket}

  def handle_info({:rec_tick, token}, %{assigns: %{rec_token: token}} = socket) do
    socket =
      case socket.assigns.recording do
        %{at: at} = rec ->
          elapsed = div(now_ms() - at, 1000)
          Mob.Socket.assign(socket, :recording, %{rec | elapsed: elapsed})

        nil ->
          socket
      end

    {:noreply, schedule_rec_tick(socket)}
  end

  def handle_info({:rec_tick, _stale}, socket), do: {:noreply, socket}

  def handle_info({:toast_off, token}, %{assigns: %{toast_token: token}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, toast: nil, toast_token: nil)}

  def handle_info({:toast_off, _stale}, socket), do: {:noreply, socket}

  def handle_info({:output, :destinations, list}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :destinations, list)}

  def handle_info({:output, _kind, _payload}, socket), do: {:noreply, socket}

  # ── Microphone ──

  def handle_info(:first_run, socket) do
    {:noreply, Mob.Socket.push_screen(socket, FirstRunScreen, %{return_to: self(), step: :mic})}
  end

  def handle_info({:first_run, :done}, socket) do
    socket = socket |> reload_settings() |> center_on_range()
    socket = if socket.assigns.mic == :unknown, do: ask_microphone(socket), else: listen(socket)
    {:noreply, refresh(socket)}
  end

  def handle_info({:permission, :microphone, :granted}, socket) do
    if device_calls?(), do: Mob.Permissions.request(socket, :notifications)
    socket = socket |> Mob.Socket.assign(:mic, :granted) |> listen()
    {:noreply, refresh(socket)}
  end

  def handle_info({:permission, :microphone, :denied}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:mic, :denied) |> refresh()}

  # Notifications only matter for the background notice; listening goes on without.
  def handle_info({:permission, _capability, _result}, socket), do: {:noreply, socket}

  # ── Taps ──

  def handle_info({:tap, :retry_mic}, socket), do: {:noreply, ask_microphone(socket)}

  def handle_info({:tap, :app_settings}, socket) do
    if device_calls?(), do: Mob.Device.open_settings(:app)
    {:noreply, socket}
  end

  def handle_info({:tap, :output}, socket), do: {:noreply, open(socket, @output_screen, %{})}

  def handle_info({:tap, :phrases}, socket), do: {:noreply, open(socket, @phrases_screen, %{})}

  def handle_info({:tap, :spectrum}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, SpectrumScreen, %{})}

  def handle_info({:tap, :settings}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:sheet, :settings) |> refresh()}

  def handle_info({:tap, :scale_picker}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, :scale)}

  def handle_info({:tap, done}, socket) when done in [:settings_done, :scale_done],
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:dismiss, sheet}, socket) when sheet in [:settings_sheet, :scale_sheet],
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:tap, :find_range}, socket) do
    socket = Mob.Socket.assign(socket, :sheet, nil)

    {:noreply,
     Mob.Socket.push_screen(socket, FirstRunScreen, %{return_to: self(), step: :range, only: true})}
  end

  def handle_info({:tap, {:set, field, value}}, socket), do: {:noreply, set(socket, field, value)}

  def handle_info({:tap, :pause}, socket) do
    case socket.assigns.status do
      :paused -> Engine.resume()
      :listening -> Engine.pause()
      _other -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:tap, :record}, socket) do
    if socket.assigns.recording,
      do: {:noreply, stop_recording(socket)},
      else: {:noreply, start_recording(socket)}
  end

  def handle_info(:hum_again, socket) do
    if socket.assigns.recording,
      do: {:noreply, socket},
      else: {:noreply, start_recording(socket)}
  end

  # ── Sensitivity drag ──

  def handle_info({:drag, :sensitivity, %{x: x} = payload}, socket) do
    {w, _h} = SettingsSheet.bar_size()
    db = SettingsSheet.db_at(x, w)
    socket = Mob.Socket.assign(socket, :sens_drag, db)

    socket =
      if Map.get(payload, :phase) == :ended,
        do: commit_sensitivity(socket),
        else: arm_drag_quiet(socket)

    {:noreply, refresh(socket)}
  end

  def handle_info({:drag_quiet, token}, %{assigns: %{drag_token: token}} = socket),
    do: {:noreply, socket |> commit_sensitivity() |> refresh()}

  def handle_info({:drag_quiet, _stale}, socket), do: {:noreply, socket}

  # The lift after a tap (see `Controls.held/0`): nothing to do.
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:awake] && device_calls?(), do: Mob.Device.keep_awake(false)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp ask_microphone(socket) do
    if device_calls?() do
      socket
      |> Mob.Socket.assign(:mic, :asking)
      |> then(&Mob.Permissions.request(&1, :microphone))
    else
      socket |> Mob.Socket.assign(:mic, :granted) |> listen()
    end
  end

  # The engine reports how it went through its status message.
  defp listen(%{assigns: %{mic: :granted}} = socket) do
    if Code.ensure_loaded?(Audio.impl()) do
      Engine.listen()
      Mob.Socket.assign(socket, status: Engine.status(), audio_missing: false)
    else
      Mob.Socket.assign(socket, :audio_missing, true)
    end
  end

  defp listen(socket), do: socket

  # After an engine restart (the new one is :off).
  defp restore_listening(socket, :listening), do: listen(socket)

  defp restore_listening(socket, :paused) do
    socket = listen(socket)
    if socket.assigns.status == :listening, do: Engine.pause()
    Mob.Socket.assign(socket, :status, Engine.status())
  end

  defp restore_listening(socket, {:error, _reason}), do: listen(socket)
  defp restore_listening(socket, _off), do: socket

  defp open(socket, screen, params) do
    if Code.ensure_loaded?(screen),
      do: Mob.Socket.push_screen(socket, screen, params),
      else: toast(socket, "That screen isn't in this build yet")
  end

  defp set(socket, field, value) do
    case Engine.update_settings(%{field => value}) do
      {:ok, settings} ->
        socket |> Mob.Socket.assign(:settings, settings) |> after_settings(field) |> refresh()

      {:error, _} ->
        socket
    end
  end

  defp after_settings(socket, field) when field in [:octave, :transpose],
    do: center_on_range(socket)

  defp after_settings(socket, _field), do: socket

  defp reload_settings(socket), do: Mob.Socket.assign(socket, :settings, Engine.settings())

  defp commit_sensitivity(%{assigns: %{sens_drag: nil}} = socket), do: socket

  defp commit_sensitivity(socket) do
    db = socket.assigns.sens_drag
    socket = Mob.Socket.assign(socket, sens_drag: nil, drag_token: nil)
    set(socket, :sensitivity_db, db)
  end

  # A drag's end can be lost on Android (MOB-511): one quiet for a second has ended.
  defp arm_drag_quiet(socket) do
    token = make_ref()
    Process.send_after(self(), {:drag_quiet, token}, @drag_quiet_ms)
    Mob.Socket.assign(socket, :drag_token, token)
  end

  defp start_recording(socket) do
    Engine.record_start()
    start_recording_state(socket)
  end

  defp stop_recording(socket) do
    socket = Mob.Socket.assign(socket, recording: nil, rec_token: nil, rec_changed_at: now_ms())

    case Engine.record_stop() do
      {:ok, take} ->
        phrase = Phrase.from_take(take, now: DateTime.utc_now())
        open(socket, @phrase_screen, %{phrase: phrase, return_to: self()})

      {:error, :empty} ->
        toast(socket, "No notes in that take: hum a little louder?")

      {:error, :not_recording} ->
        socket
    end
  end

  defp recording_state(true), do: %{at: now_ms(), elapsed: 0}
  defp recording_state(false), do: nil

  # A recording can also start or stop from the notification: follow the
  # frames' `recording`, except just after a tap here (a frame sent before
  # the tap may still be on its way).
  defp sync_recording(socket, nil), do: socket

  defp sync_recording(socket, recording?) do
    a = socket.assigns

    cond do
      now_ms() - a.rec_changed_at < 500 ->
        socket

      recording? and a.recording == nil ->
        start_recording_state(socket)

      not recording? and a.recording != nil ->
        Mob.Socket.assign(socket, recording: nil, rec_token: nil)

      true ->
        socket
    end
  end

  defp start_recording_state(socket) do
    socket
    |> Mob.Socket.assign(recording: recording_state(true), toast: nil, rec_changed_at: now_ms())
    |> schedule_rec_tick()
  end

  defp schedule_rec_tick(%{assigns: %{recording: nil}} = socket), do: socket

  defp schedule_rec_tick(socket) do
    token = make_ref()
    Process.send_after(self(), {:rec_tick, token}, 1_000)
    Mob.Socket.assign(socket, :rec_token, token)
  end

  defp toast(socket, text) do
    token = make_ref()
    Process.send_after(self(), {:toast_off, token}, @toast_ms)
    Mob.Socket.assign(socket, toast: text, toast_token: token)
  end

  defp schedule_tick(%{assigns: %{tick_token: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:tick, token}, @frame_ms)
    Mob.Socket.assign(socket, :tick_token, token)
  end

  defp schedule_tick(socket), do: socket

  defp schedule_blink(socket, phase \\ :close) do
    token = make_ref()
    delay = if phase == :open, do: @blink_ms, else: 2_500 + :rand.uniform(3_000)
    Process.send_after(self(), {:blink, token, phase}, delay)
    Mob.Socket.assign(socket, :blink_token, token)
  end

  defp keep_awake(socket) do
    a = socket.assigns
    mood = mood(a)

    want =
      cond do
        a.shown.voiced -> true
        mood in [:idle, :paused, :no_mic] -> false
        true -> a.awake
      end

    if want != a.awake do
      if device_calls?(), do: Mob.Device.keep_awake(want)
      Mob.Socket.assign(socket, :awake, want)
    else
      socket
    end
  end

  defp smooth(nil, db, _k), do: db
  defp smooth(prev, db, k), do: prev + (db - prev) * k

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp device_calls?, do: Application.get_env(:humdinger, :device_calls, true)

  # ── The view's geometry ───────────────────────────────────────────────

  @doc """
  Where the roll's centre heads: the middle of what the last 4 s sang and
  sent, held within 4 semitones of the voice so the newest pitch stays in
  view. Nil (stay put) when nothing is in the window.
  """
  def roll_target(feed) do
    from = (feed.now || 0) - @roll_window_ms
    sung = for {t, p} <- LiveFeed.trace(feed), p != nil, t >= from, do: p
    sent = for n <- LiveFeed.notes(feed), n.end_ms == nil or n.end_ms >= from, do: n.midi

    case sung ++ sent do
      [] ->
        nil

      pitches ->
        {lo, hi} = Enum.min_max(pitches)
        mid = (lo + hi) / 2

        case LiveFeed.pitch(feed) do
          nil -> mid
          p -> min(max(mid, p - 4), p + 4)
        end
    end
  end

  @doc false
  # The roll's centre eases a quarter of the way to its target each tick.
  def ease_center(center, nil), do: center

  def ease_center(center, target) do
    next = center + (target - center) * 0.25
    if abs(target - next) < 0.01, do: target * 1.0, else: next
  end

  @doc """
  The piano strip's window (`{low, high}`, 15 semitones from a white key)
  centred on `center`, and kept inside the piano.
  """
  def window_for(center, _range) do
    low = round(center) - 7
    low = if Music.white_key?(low), do: low, else: low - 1
    low = low |> max(21) |> min(108 - @strip_span)
    {low, low + @strip_span}
  end

  @doc "Moves the window when the sung note leaves its inner keys."
  def follow_window(window, nil), do: window

  def follow_window({low, high} = window, note) do
    if note > low and note < high, do: window, else: window_for(note, nil)
  end

  # The strip starts on the middle of the singer's range, as it sounds.
  defp center_on_range(socket) do
    case shifted_range(socket.assigns.settings) do
      {low, high} ->
        mid = (low + high) / 2
        Mob.Socket.assign(socket, center: mid * 1.0, window: window_for(mid, nil))

      nil ->
        socket
    end
  end

  # The singer's range moved by octave and transpose, as the notes sound.
  defp shifted_range(%{range: nil}), do: nil

  defp shifted_range(%{range: {low, high}} = s) do
    shift = s.octave * 12 + s.transpose
    {low + shift, high + shift}
  end

  defp mood(a) do
    cond do
      trouble(a) -> :no_mic
      a.status == :paused -> :paused
      true -> a.shown.mood
    end
  end

  # ── Canvases (rebuilt only when their inputs change) ──────────────────

  defp refresh(socket) do
    a = socket.assigns
    shown = a.shown
    s = a.settings
    mood = mood(a)
    note = shown.note || a.last_note
    loudness = loudness(shown, s)
    {low, high} = a.window

    socket
    |> memo(:strip, {a.window, shown.note, round1(shown.pitch), shifted_range(s)}, fn ->
      PianoStrip.ops(
        %{
          low: low,
          high: high,
          active: shown.note,
          pitch: shown.pitch,
          range: shifted_range(s)
        },
        @strip_w,
        PianoStrip.height()
      )
    end)
    |> memo(:mimi, {mood, note, loudness, a.blink}, fn ->
      {w, h} = @mimi
      Mimi.ops(w / 2, h / 2, w, %{mood: mood, note: note, loudness: loudness, blink: a.blink})
    end)
    |> memo(:meter, round1(shown.cents), fn ->
      TuningMeter.ops(%{cents: shown.cents, tolerance: 10}, @meter_w, TuningMeter.height())
    end)
    |> memo(:roll, roll_key(a), fn -> roll_ops(a) end)
    |> memo(:mini, {mood, shown.note}, fn ->
      Mimi.ops(22, 20, 44, %{mood: mood, note: shown.note || 69})
    end)
    |> memo(:bar, bar_key(a), fn ->
      {w, h} = SettingsSheet.bar_size()
      SettingsSheet.bar_ops(bar_data(a), w, h)
    end)
  end

  defp memo(socket, name, key, build) do
    a = socket.assigns

    if Map.has_key?(a.op_keys, name) and a.op_keys[name] == key do
      socket
    else
      Mob.Socket.assign(socket,
        ops: Map.put(a.ops, name, build.()),
        op_keys: Map.put(a.op_keys, name, key)
      )
    end
  end

  defp loudness(%{voiced: true, db: db}, s),
    do: Float.round(min(max((db - s.sensitivity_db) / 35, 0.0), 1.0), 1)

  defp loudness(_shown, _s), do: 0.0

  defp round1(nil), do: nil
  defp round1(v), do: Float.round(v * 1.0, 1)

  defp roll_scale(%{mode: :open}), do: nil
  defp roll_scale(%{scale: scale}), do: scale

  # A roll with nothing in its window only changes with its rows.
  defp roll_key(a) do
    center = Float.round(a.center * 1.0, 2)

    if LiveFeed.visible?(a.feed, @roll_window_ms),
      do: {a.feed.now, center, roll_scale(a.settings)},
      else: {:empty, center, roll_scale(a.settings)}
  end

  defp roll_ops(a) do
    {w, h} = @roll

    PitchRoll.ops(
      %{
        now_ms: a.feed.now || 0,
        trace: LiveFeed.trace(a.feed),
        notes: LiveFeed.notes(a.feed),
        scale: roll_scale(a.settings),
        center_midi: a.center,
        window_ms: @roll_window_ms
      },
      w,
      h
    )
  end

  # The bar only matters while the sheet is open.
  defp bar_key(%{sheet: :settings} = a) do
    d = bar_data(a)
    {d.gate, d.room && round(d.room), d.voice && round(d.voice), d.note}
  end

  defp bar_key(a), do: Map.get(a.op_keys, :bar, :closed)

  defp bar_data(a) do
    %{
      gate: a.sens_drag || a.settings.sensitivity_db,
      room: a.room_db,
      voice: a.voice_db,
      note: a.last_note
    }
  end
end
