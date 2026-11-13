defmodule Humdinger.Tracker do
  @moduledoc """
  Turns the microphone's pitch readings into MIDI events: the heart of
  Humdinger. Pure: `push/2` takes one `Humdinger.Audio` reading (`%{t, hz,
  clarity, db}`, `t` in ms) and returns the events it caused, `tick/2`
  moves time on without a reading (it ends a hold, or a note whose
  readings stopped coming), `release/1` turns everything off.
  Events carry no channel: `{:note_on, note, velocity}`, `{:note_off,
  note}`, `{:pitch_bend, -8192..8191}`, `{:cc, number, value}`.

  ## How a voice becomes notes

  **Voicing gate.** A reading opens the gate when it is pitched (`hz` not
  nil), clear (clarity ≥ 0.8) and loud enough (`db` ≥ `sensitivity_db`).
  The gate opens once such readings have run unbroken for the response
  time (below); a breathy or noisy blip shorter than that never makes a
  note. Once open, a reading keeps it open on easier terms (clarity ≥ 0.6,
  `db` ≥ `sensitivity_db` − 6 dB), and the gate closes only after 30 ms
  without such a reading, so a consonant or a crackle inside a note
  doesn't chop it. Readings that don't keep the gate don't move the pitch.

  **Pitch.** Hz becomes a fractional MIDI number plus `octave · 12 +
  transpose`, so everything after works on the sent note (the displayed
  note is the sent one). A median of the last three readings removes the
  detector's one-off octave errors, then an exponential smoother with a
  time constant per response damps jitter and vibrato. A move of more than
  1.5 semitones from the smoothed pitch is a leap, not a wobble: the
  smoother jumps straight there instead of sliding through the notes in
  between.

  **Response.** `response_ms/1`: Fast 30 ms (smoothing 12 ms), Balanced
  60 ms (30 ms), Steady 120 ms (60 ms). It is both how long the voice must
  be heard before its first note and how long a new note must hold before
  the sent note changes. Fast follows quick runs but can flip notes on a
  wide vibrato; Steady waits until it is sure.

  **Scale mode.** The note is `Humdinger.Scale.snap/2` of the pitch, with
  hysteresis: leaving the current note needs the pitch a quarter semitone
  past the midpoint to the neighbour (so from A to A# it must reach A +
  75 cents, and back below A# − 75 cents). A pitch hovering at a boundary
  stays on its note. The new note must then hold for the response time.

  **Open + bend mode.** The note is the nearest semitone and pitch bend
  carries the difference: ± `bend_range` semitones over the 14-bit range,
  sent when it moves by a cent or more. A new note is struck at once when
  the pitch drifts beyond the bend range, or when the voice settles on
  another semitone: a slow centre (the pitch smoothed over 100 ms, which
  irons out vibrato) must pass the same hysteresis, sit within 40 cents
  of the new semitone and move less than 15 cents for the response time.
  So vibrato and glides only bend (a glide faster than 0.15 semitones per
  response time: 2.5 a second at Balanced), while a voice
  that lands on a new note gets one. Bend returns to centre before each
  new note and is set for the new note right after it.

  **Pitch change.** `:legato` sends the new note on before the old note
  off, so a mono synth glides or slurs; `:new_note` sends the old note off
  first and re-articulates.

  **When you stop.** `:note_off` ends the note when the gate closes.
  `:hold` keeps it for 250 ms after the last voiced reading: a breath or
  a consonant that re-voices on the same note continues it without a new
  note on, a different note changes as in a phrase, and silence ends it
  (on a later reading or on `tick/2`, see `deadline/1`). If the readings
  stop altogether (readings come every ~10 ms; a stalled microphone sends
  none), `tick/2` closes the gate 150 ms after the last one, so a note
  can't sound on forever; the margin over the 30 ms a reading needs keeps
  a busy moment of the caller from chopping a note.

  **Velocity** maps the loudest reading of the onset (the readings that
  opened the gate) from `sensitivity_db` (16) to −10 dBFS (127); a note
  changed in the middle of a phrase takes the current level. Fixed 100
  when off. **CC 11** (expression) follows the level while a note sounds
  (smoothed over 50 ms, sent on a change of 1 or more, at most every
  20 ms, and once before each onset's note on). **CC 1** (mod wheel)
  follows vibrato: the last 500 ms of pitch, its slow drift removed by a
  straight-line fit, counts as vibrato when it swings across its centre
  at 3.5–9 Hz; its depth (the swing's amplitude in cents, from the RMS,
  8 → 0, 100 → 127) is sent at most every 50 ms on a change of 2 or
  more, and 0 when the voice stops.

  Notes stay within MIDI 0..127. Every note on is matched by exactly one
  note off: at most one note sounds between pushes (two for an instant
  inside a legato change), and `release/1` ends it, centres the bend and
  zeroes the mod wheel.
  """

  alias Humdinger.{Music, Scale, Settings}

  @type event ::
          {:note_on, 0..127, 1..127}
          | {:note_off, 0..127}
          | {:pitch_bend, -8192..8191}
          | {:cc, 0..127, 0..127}

  @type display :: %{
          pitch: float() | nil,
          note: 0..127 | nil,
          cents: float() | nil,
          hz: float() | nil,
          db: float(),
          velocity: 1..127 | nil,
          voiced: boolean(),
          holding: boolean()
        }

  # {response time, smoothing time constant}, ms.
  @responses %{fast: {30, 12}, balanced: {60, 30}, steady: {120, 60}}
  @open_clarity 0.8
  @keep_clarity 0.6
  @keep_below_gate_db 6.0
  @close_ms 30
  @stall_ms 150
  @hold_ms 250
  @leap 1.5
  @hysteresis 0.25
  @settle_near 0.4
  @settle_still 0.15
  @centre_tau_ms 100
  @loud_db -10.0
  @fixed_velocity 100
  @level_tau_ms 50
  @cc11_every_ms 20
  @cc1_every_ms 50
  @vibrato_window_ms 500
  @vibrato_min_span_ms 300
  @vibrato_deadband_cents 3.0
  # Settings whose change re-maps notes: the tracker releases first.
  @release_on [:mode, :scale, :octave, :transpose, :bend_range, :channel]

  defstruct [
    :settings,
    :gate_db,
    :confirm_ms,
    :tau_ms,
    :shift,
    stall_ms: @stall_ms,
    t: nil,
    db: -90.0,
    hz: nil,
    voiced: false,
    onset: [],
    last_voiced_t: nil,
    window: [],
    pitch: nil,
    centre: nil,
    pitch_t: nil,
    note: nil,
    velocity: nil,
    pending: nil,
    hold_until: nil,
    bend: 0,
    level: nil,
    cc11: nil,
    cc11_t: nil,
    vib: [],
    cc1: 0,
    cc1_t: nil
  ]

  @type t :: %__MODULE__{}

  @doc """
  A tracker for these settings. Option `stall_ms` (default 150): how long
  without any reading counts as a stalled input (see `tick/2`).
  """
  @spec new(Settings.t(), keyword()) :: t()
  def new(%Settings{} = settings, opts \\ []) do
    tracker = %__MODULE__{stall_ms: Keyword.get(opts, :stall_ms, @stall_ms)}
    apply_settings(tracker, settings)
  end

  @doc """
  The response time of a `response` setting in ms: how long a voice or a
  new note must be heard before the sent note follows.
  """
  @spec response_ms(:fast | :balanced | :steady) :: pos_integer()
  def response_ms(response), do: @responses |> Map.fetch!(response) |> elem(0)

  @doc "How long `:hold` keeps a note after the voice stops, in ms."
  @spec hold_ms() :: pos_integer()
  def hold_ms, do: @hold_ms

  @doc """
  Change settings. A change of mode, scale, octave, transpose, bend range
  or channel re-maps notes, so it releases first (the returned events);
  anything else applies to the note in progress. Turning CC 1 off zeroes
  the mod wheel, turning CC 11 off restores full expression (127).
  """
  @spec configure(t(), Settings.t()) :: {t(), [event()]}
  def configure(%__MODULE__{settings: old} = tracker, %Settings{} = settings) do
    if Enum.any?(@release_on, &(Map.fetch!(old, &1) != Map.fetch!(settings, &1))) do
      {released, events} = release(tracker)
      {released, cc11} = maybe_restore_cc11(released, settings.cc11_from_loudness)
      {apply_settings(released, settings), events ++ cc11}
    else
      {tracker, cc1} = maybe_zero_cc1(tracker, settings.cc1_from_vibrato)
      {tracker, cc11} = maybe_restore_cc11(tracker, settings.cc11_from_loudness)
      {apply_settings(tracker, settings), cc1 ++ cc11}
    end
  end

  @doc "Feed one reading; returns the events it caused, in order."
  @spec push(t(), Humdinger.Audio.reading()) :: {t(), [event()]}
  def push(%__MODULE__{} = tracker, %{t: t, hz: hz, clarity: clarity, db: db}) do
    {tracker, expired} = expire_hold(%{tracker | t: t, db: db / 1}, t)
    {tracker, events} = gate(tracker, t, hz, clarity, db / 1)
    {tracker, expired ++ events}
  end

  @doc """
  Advance time to `t` without a reading: closes the gate when no reading
  at all came for 150 ms (a stalled input), and ends a hold that has run
  out.
  """
  @spec tick(t(), number()) :: {t(), [event()]}
  def tick(%__MODULE__{} = tracker, t) do
    {tracker, closed} = close_stalled(tracker, t)
    {tracker, expired} = expire_hold(tracker, t)
    {tracker, closed ++ expired}
  end

  @doc """
  When `tick/2` next has something to do, or nil: while voiced, when the
  readings would count as stalled; else the end of a hold.
  """
  @spec deadline(t()) :: number() | nil
  def deadline(%__MODULE__{voiced: true, last_voiced_t: last, stall_ms: stall}), do: last + stall
  def deadline(%__MODULE__{hold_until: until}), do: until

  @doc "Everything off: the note, the bend (centred) and the mod wheel (0)."
  @spec release(t()) :: {t(), [event()]}
  def release(%__MODULE__{} = tracker) do
    events =
      if(tracker.note, do: [{:note_off, tracker.note}], else: []) ++
        if(tracker.bend != 0, do: [{:pitch_bend, 0}], else: []) ++
        if tracker.cc1 > 0, do: [{:cc, 1, 0}], else: []

    {silence(%{tracker | bend: 0, cc1: 0}), events}
  end

  @doc """
  What the Live screen shows: the smoothed pitch (fractional MIDI, after
  octave and transpose; nil while not voiced), the sounding note, the
  pitch's cents from it, the last voiced hz, the latest level, the note's
  velocity, whether the gate is open and whether a note is being held
  over a gap.
  """
  @spec display(t()) :: display()
  def display(%__MODULE__{} = tracker) do
    pitch = if tracker.voiced, do: tracker.pitch

    %{
      pitch: pitch,
      note: tracker.note,
      cents: if(pitch && tracker.note, do: Music.cents(pitch, tracker.note)),
      hz: if(tracker.voiced, do: tracker.hz),
      db: tracker.db,
      velocity: tracker.velocity,
      voiced: tracker.voiced,
      holding: tracker.hold_until != nil
    }
  end

  @doc """
  Wording for how far the voice is from the sent note: "in tune" within
  10 cents, "a little flat" / "a little sharp" up to 30 cents, then
  "flat" / "sharp".
  """
  @spec tuning_label(number()) :: String.t()
  def tuning_label(cents) when abs(cents) < 10, do: "in tune"

  def tuning_label(cents) when cents < -30 or cents > 30,
    do: if(cents < 0, do: "flat", else: "sharp")

  def tuning_label(cents), do: if(cents < 0, do: "a little flat", else: "a little sharp")

  @doc ~S|The Live screen's tuning line: `cents_label(-12.4)` → "−12¢ · a little flat".|
  @spec cents_label(number()) :: String.t()
  def cents_label(cents), do: "#{cents_text(cents)} · #{tuning_label(cents)}"

  @doc ~S|Whole cents with a sign (a real minus): `cents_text(-12.4)` → "−12¢", `cents_text(3)` → "+3¢", 0 → "0¢".|
  @spec cents_text(number()) :: String.t()
  def cents_text(cents) do
    rounded = round(cents)

    sign =
      cond do
        rounded < 0 -> "−"
        rounded > 0 -> "+"
        true -> ""
      end

    "#{sign}#{abs(rounded)}¢"
  end

  # ── Settings ──────────────────────────────────────────────────────────

  defp apply_settings(tracker, settings) do
    {confirm_ms, tau_ms} = Map.fetch!(@responses, settings.response)

    %{
      tracker
      | settings: settings,
        gate_db: settings.sensitivity_db / 1,
        confirm_ms: confirm_ms,
        tau_ms: tau_ms,
        shift: settings.octave * 12 + settings.transpose
    }
  end

  defp maybe_zero_cc1(%{cc1: cc1} = tracker, false) when cc1 > 0,
    do: {%{tracker | cc1: 0}, [{:cc, 1, 0}]}

  defp maybe_zero_cc1(tracker, _on), do: {tracker, []}

  defp maybe_restore_cc11(%{cc11: cc11} = tracker, false) when is_integer(cc11) and cc11 != 127,
    do: {%{tracker | cc11: nil}, [{:cc, 11, 127}]}

  defp maybe_restore_cc11(tracker, false), do: {%{tracker | cc11: nil}, []}
  defp maybe_restore_cc11(tracker, true), do: {tracker, []}

  # ── Gate ──────────────────────────────────────────────────────────────

  defp gate(%{voiced: true} = tracker, t, hz, clarity, db) do
    cond do
      keeps?(tracker, hz, clarity, db) ->
        track(%{tracker | last_voiced_t: t, hz: hz / 1}, t, pitch_of(tracker, hz), db)

      t - tracker.last_voiced_t >= @close_ms ->
        close(tracker)

      true ->
        {tracker, []}
    end
  end

  defp gate(tracker, t, hz, clarity, db) do
    if opens?(tracker, hz, clarity, db) do
      onset = [{t, pitch_of(tracker, hz), db} | tracker.onset]
      {first_t, _pitch, _db} = List.last(onset)

      if t - first_t >= tracker.confirm_ms,
        do: open(%{tracker | onset: [], hz: hz / 1}, t, onset),
        else: {%{tracker | onset: onset}, []}
    else
      {%{tracker | onset: []}, []}
    end
  end

  defp opens?(tracker, hz, clarity, db),
    do: is_number(hz) and hz > 0 and clarity >= @open_clarity and db >= tracker.gate_db

  defp keeps?(tracker, hz, clarity, db),
    do:
      is_number(hz) and hz > 0 and clarity >= @keep_clarity and
        db >= tracker.gate_db - @keep_below_gate_db

  defp pitch_of(tracker, hz), do: Music.hz_to_midi(hz) + tracker.shift

  # The onset has run for the response time: the gate opens on the median
  # of its pitches, at its loudest level.
  defp open(tracker, t, onset) do
    pitches = Enum.map(onset, &elem(&1, 1))
    peak_db = onset |> Enum.map(&elem(&1, 2)) |> Enum.max()
    pitch = median(pitches)

    tracker = %{
      tracker
      | voiced: true,
        last_voiced_t: t,
        window: Enum.take(pitches, 3),
        pitch: pitch,
        centre: pitch,
        pitch_t: t,
        level: peak_db,
        pending: nil,
        hold_until: nil,
        vib: Enum.map(onset, fn {ot, p, _db} -> {ot, p} end)
    }

    target = target(tracker, pitch, tracker.note)

    cond do
      tracker.note == nil ->
        start_note(tracker, target, velocity(tracker, peak_db), t)

      target == tracker.note ->
        follow_bend(tracker)

      true ->
        change_note(tracker, target)
    end
  end

  defp close(tracker) do
    cc1 = if tracker.cc1 > 0, do: [{:cc, 1, 0}], else: []
    tracker = %{tracker | voiced: false, onset: [], pending: nil, vib: [], window: [], cc1: 0}

    case tracker.settings.on_stop do
      _ when tracker.note == nil ->
        {tracker, cc1}

      :hold ->
        {%{tracker | hold_until: tracker.last_voiced_t + @hold_ms}, cc1}

      :note_off ->
        {%{tracker | note: nil, velocity: nil}, [{:note_off, tracker.note} | cc1]}
    end
  end

  defp close_stalled(%{voiced: true, last_voiced_t: last, stall_ms: stall} = tracker, t)
       when t - last >= stall,
       do: close(tracker)

  defp close_stalled(tracker, _t), do: {tracker, []}

  defp expire_hold(%{hold_until: until, voiced: false, note: note} = tracker, t)
       when is_number(until) and t >= until and note != nil do
    {%{tracker | hold_until: nil, note: nil, velocity: nil}, [{:note_off, note}]}
  end

  defp expire_hold(tracker, _t), do: {tracker, []}

  defp silence(tracker) do
    %{
      tracker
      | voiced: false,
        onset: [],
        window: [],
        pitch: nil,
        centre: nil,
        note: nil,
        velocity: nil,
        pending: nil,
        hold_until: nil,
        vib: []
    }
  end

  # ── While voiced ──────────────────────────────────────────────────────

  defp track(tracker, t, raw, db) do
    dt = max(t - tracker.pitch_t, 1)
    window = Enum.take([raw | tracker.window], 3)
    median = median(window)

    {pitch, centre} =
      if abs(median - tracker.pitch) > @leap,
        do: {median, median},
        else:
          {ease(tracker.pitch, median, dt, tracker.tau_ms),
           ease(tracker.centre, median, dt, @centre_tau_ms)}

    vib =
      Enum.take_while([{t, median} | tracker.vib], fn {vt, _} ->
        t - vt <= @vibrato_window_ms
      end)

    tracker = %{
      tracker
      | window: window,
        pitch: pitch,
        centre: centre,
        pitch_t: t,
        level: ease(tracker.level, db, dt, @level_tau_ms),
        vib: vib
    }

    {tracker, notes} = decide(tracker, t)
    {tracker, bend} = follow_bend(tracker)
    {tracker, cc11} = follow_level(tracker, t)
    {tracker, cc1} = follow_vibrato(tracker, t)
    {tracker, notes ++ bend ++ cc11 ++ cc1}
  end

  defp decide(%{note: nil} = tracker, t) do
    target = target(tracker, tracker.pitch, nil)
    start_note(tracker, target, velocity(tracker, tracker.level), t)
  end

  # Open mode: strike again when the pitch drifts past the bend range, or
  # when the slow centre has settled near another semitone.
  defp decide(%{settings: %{mode: :open, bend_range: range}} = tracker, t) do
    %{pitch: pitch, centre: centre, note: note} = tracker

    if abs(pitch - note) > range do
      case nearest(tracker, pitch) do
        ^note -> {tracker, []}
        target -> change_note(tracker, target)
      end
    else
      target = target(tracker, centre, note)

      if target == note or abs(centre - target) > @settle_near,
        do: {%{tracker | pending: nil}, []},
        else: settle(tracker, target, t, centre)
    end
  end

  defp decide(tracker, t) do
    case target(tracker, tracker.pitch, tracker.note) do
      target when target == tracker.note -> {%{tracker | pending: nil}, []}
      target -> settle(tracker, target, t, nil)
    end
  end

  # The new note must hold for the response time; in Open mode the centre
  # must also stay put (`anchor` is where it was when the wait began).
  defp settle(tracker, target, t, value) do
    case tracker.pending do
      {^target, since, anchor} when anchor == nil or abs(value - anchor) <= @settle_still ->
        if t - since >= tracker.confirm_ms,
          do: change_note(tracker, target),
          else: {tracker, []}

      _other ->
        {%{tracker | pending: {target, t, value}}, []}
    end
  end

  # The note for a pitch, keeping `current` unless the pitch is clearly
  # past the midpoint to another note.
  defp target(tracker, pitch, current) do
    candidate = nearest(tracker, pitch)

    if current == nil or candidate == current or
         abs(pitch - current) - abs(pitch - candidate) >= 2 * @hysteresis,
       do: candidate,
       else: current
  end

  defp nearest(%{settings: %{mode: :scale, scale: scale}}, pitch),
    do: scale |> Scale.snap(pitch) |> clamp(0, 127)

  defp nearest(_tracker, pitch), do: pitch |> round() |> clamp(0, 127)

  defp start_note(tracker, note, velocity, t) do
    {tracker, cc11} = onset_level(tracker, t)
    {tracker, reset} = reset_bend(tracker)
    tracker = %{tracker | note: note, velocity: velocity, pending: nil}
    {tracker, bend} = follow_bend(tracker)
    {tracker, cc11 ++ reset ++ [{:note_on, note, velocity}] ++ bend}
  end

  defp change_note(tracker, note) do
    old = tracker.note
    velocity = velocity(tracker, tracker.level)
    {tracker, reset} = reset_bend(tracker)
    tracker = %{tracker | note: note, velocity: velocity, pending: nil, hold_until: nil}
    {tracker, bend} = follow_bend(tracker)

    events =
      case tracker.settings.pitch_change do
        :legato -> reset ++ [{:note_on, note, velocity}, {:note_off, old}]
        :new_note -> [{:note_off, old}] ++ reset ++ [{:note_on, note, velocity}]
      end

    {tracker, events ++ bend}
  end

  # ── Bend ──────────────────────────────────────────────────────────────

  defp reset_bend(%{bend: 0} = tracker), do: {tracker, []}
  defp reset_bend(tracker), do: {%{tracker | bend: 0}, [{:pitch_bend, 0}]}

  defp follow_bend(%{settings: %{mode: :open, bend_range: range}, note: note} = tracker)
       when is_integer(note) do
    bend = bend_value(tracker.pitch - note, range)

    if abs(bend - tracker.bend) >= bend_quantum(range),
      do: {%{tracker | bend: bend}, [{:pitch_bend, bend}]},
      else: {tracker, []}
  end

  defp follow_bend(tracker), do: {tracker, []}

  defp bend_value(semitones, range), do: round(semitones / range * 8192) |> clamp(-8192, 8191)

  # One cent of bend.
  defp bend_quantum(range), do: ceil(8192 / (range * 100))

  # ── Loudness ──────────────────────────────────────────────────────────

  defp velocity(%{settings: %{velocity_from_loudness: false}}, _db), do: @fixed_velocity

  defp velocity(tracker, db),
    do: round(16 + 111 * loudness(db, tracker.gate_db)) |> clamp(1, 127)

  defp expression(tracker, db),
    do: round(127 * loudness(db, tracker.gate_db - @keep_below_gate_db)) |> clamp(0, 127)

  defp loudness(db, floor), do: ((db - floor) / (@loud_db - floor)) |> clamp(0.0, 1.0)

  defp onset_level(%{settings: %{cc11_from_loudness: true}} = tracker, t) do
    value = expression(tracker, tracker.level)

    if value == tracker.cc11,
      do: {tracker, []},
      else: {%{tracker | cc11: value, cc11_t: t}, [{:cc, 11, value}]}
  end

  defp onset_level(tracker, _t), do: {tracker, []}

  defp follow_level(%{settings: %{cc11_from_loudness: true}, note: note} = tracker, t)
       when is_integer(note) do
    value = expression(tracker, tracker.level)

    if value != tracker.cc11 and (tracker.cc11_t == nil or t - tracker.cc11_t >= @cc11_every_ms),
      do: {%{tracker | cc11: value, cc11_t: t}, [{:cc, 11, value}]},
      else: {tracker, []}
  end

  defp follow_level(tracker, _t), do: {tracker, []}

  # ── Vibrato ───────────────────────────────────────────────────────────

  defp follow_vibrato(%{settings: %{cc1_from_vibrato: true}, note: note} = tracker, t)
       when is_integer(note) do
    if tracker.cc1_t == nil or t - tracker.cc1_t >= @cc1_every_ms do
      value = tracker.vib |> Enum.reverse() |> vibrato_cents() |> vibrato_value()
      tracker = %{tracker | cc1_t: t}

      if abs(value - tracker.cc1) >= 2 or (value == 0 and tracker.cc1 != 0),
        do: {%{tracker | cc1: value}, [{:cc, 1, value}]},
        else: {tracker, []}
    else
      {tracker, []}
    end
  end

  defp follow_vibrato(tracker, _t), do: {tracker, []}

  @doc """
  The vibrato in `{t_ms, pitch}` samples (oldest first): the swing's
  amplitude in cents once a straight-line drift is removed, when the pitch crosses
  its centre at 3.5–9 Hz over at least 300 ms; else 0.0.
  """
  @spec vibrato_cents([{number(), float()}]) :: float()
  def vibrato_cents([{t0, _} | _] = samples) do
    {t1, _} = List.last(samples)
    span = t1 - t0

    if span < @vibrato_min_span_ms do
      0.0
    else
      residuals = detrend(samples)
      rate = crossings(residuals) / 2 / (span / 1000)

      if rate >= 3.5 and rate <= 9.0,
        do: :math.sqrt(Enum.reduce(residuals, 0.0, &(&1 * &1 + &2)) / length(residuals) * 2),
        else: 0.0
    end
  end

  def vibrato_cents([]), do: 0.0

  defp vibrato_value(cents), do: round((cents - 8) * 127 / 92) |> clamp(0, 127)

  # Residuals from the least-squares line, in cents.
  defp detrend(samples) do
    n = length(samples)
    mt = Enum.reduce(samples, 0.0, fn {t, _}, acc -> acc + t end) / n
    mp = Enum.reduce(samples, 0.0, fn {_, p}, acc -> acc + p end) / n

    {sxy, sxx} =
      Enum.reduce(samples, {0.0, 0.0}, fn {t, p}, {sxy, sxx} ->
        {sxy + (t - mt) * (p - mp), sxx + (t - mt) * (t - mt)}
      end)

    slope = if sxx == 0.0, do: 0.0, else: sxy / sxx
    Enum.map(samples, fn {t, p} -> (p - mp - slope * (t - mt)) * 100 end)
  end

  # Sign changes, ignoring values within the deadband.
  defp crossings(residuals) do
    {count, _sign} =
      Enum.reduce(residuals, {0, nil}, fn r, {count, prev} ->
        sign =
          cond do
            r > @vibrato_deadband_cents -> 1
            r < -@vibrato_deadband_cents -> -1
            true -> nil
          end

        cond do
          sign == nil -> {count, prev}
          prev != nil and sign != prev -> {count + 1, sign}
          true -> {count, sign}
        end
      end)

    count
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp ease(nil, target, _dt, _tau), do: target
  defp ease(value, target, dt, tau), do: value + (target - value) * (1 - :math.exp(-dt / tau))

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)
end
