# AGENTS.md: humdinger

Humdinger is a [Mob](https://hexdocs.pm/mob) app: Elixir on the BEAM,
running on the phone, rendering native SwiftUI / Jetpack Compose views. Screens
live in `lib/humdinger/`; `lib/humdinger/app.ex` starts the app.

## Where Mob's docs are

Read the docs for the mob version this app actually uses, in this order:

1. **`deps/mob/guides/*.md` and `deps/mob/usage-rules.md`**, after `mix deps.get`.
   These match the installed version exactly. (With a `path:` dependency on
   mob, read that checkout's `guides/` instead.)
2. **https://hexdocs.pm/mob/llms.txt**, the index of every page. Each page is
   also served as Markdown at `https://hexdocs.pm/mob/<page>.md`, e.g.
   https://hexdocs.pm/mob/screen_lifecycle.md. Hexdocs shows the latest
   release; check `mix.lock` if behaviour differs.
3. **`mix hex.docs fetch mob`** for offline docs, written to
   `~/.hex/docs/hexpm/mob/<version>/`.
4. **IEx**: `iex -S mix`, then `h Mob.Socket.start_async` (any module or
   function).

Guides to start with: `getting_started`, `screen_lifecycle` (including async
loading with `start_async/3` / `handle_async/3`), `components`, `events`,
`navigation`, `testing` (`Mob.ScreenCase`), `coming_from_liveview`.

## Rules for this app

- Load data asynchronously with `Mob.Socket.start_async/3` and handle the result
  in `handle_async/3` (LiveView's `start_async`; `assign_async` is a `:loading`
  assign plus `start_async`). Never a bare `Task.async` in a screen.
- Long or paginated lists use `<LazyList>` with `on_end_reached`. Mob has no
  `stream`.
- Write UI with the `~MOB` sigil.
- Test screens with `Mob.ScreenCase` (`mount_screen`, `render_event`,
  `render_info`, `render_async`).

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.

## What this app is

**Humdinger: hum it, get MIDI.** A phone app that listens to the singer
(humming, singing, whistling), turns the pitch into MIDI notes in real time
and sends them to a synth: FMutate (the sibling FM-1 emulator app, over
Erlang distribution), Humdinger's own virtual MIDI port (any app can pick
it), USB-MIDI or Bluetooth-MIDI. Humdinger makes no sound itself. It also
records phrases (piano roll, sheet music, `.mid`, MusicXML) and turns an
audio file into notes. The mascot is **Mimi**, a round hummingbird whose
feathers take the colour of the note being sung.

**Android first.** The sibling FMutate is Android-first and the pairing
protocol leans on Android (signature permissions, the back-gesture
gutters). Keep code platform-neutral where it costs nothing; iOS is a later
port (the Choir Coach iOS engine shows how).

### Design references (read before building a screen)

`design/` holds the Claude Design handoff: `shots/*.webp` are the boards
rendered at 390 × 844 (the reference artboard; `fmutate_bg` is 844 × 390),
`boards/*.html` their source (measurements, colours, the scripts that
compute shapes; `mimi-component.html` draws Mimi). There is no written spec
beyond the boards: what the boards show is the spec. `design/fmutate/`
is FMutate's handoff (`protocol.md` is the contract Humdinger's FMutate
link implements), `design/choir-coach-handoff.md` the lessons from the
previous app (Choir Coach, `~/code/choir_coach`, whose audio engine and
pitch detector Humdinger's are ported from).

| Screen | Board | Module |
|---|---|---|
| Live (home) | `live` | `Humdinger.LiveScreen` |
| Settings sheet | `settings` | sheet in `LiveScreen` |
| Spectrum view | `spectrum` | `Humdinger.SpectrumScreen` |
| Output: where the MIDI goes | `output` | `Humdinger.OutputScreen` |
| Pair with FMutate | `pair` | `Humdinger.PairScreen` |
| First run: find your range | `first_run` | `Humdinger.FirstRunScreen` |
| Phrases (saved) | `saved` | `Humdinger.PhrasesScreen` |
| Review a phrase (piano roll / staff) | `record_review`, `sheet_music` | `Humdinger.PhraseScreen` |
| Import audio → notes | `import_audio` | `Humdinger.ImportScreen` |
| Singing into FMutate (background) | `fmutate_bg` | `Humdinger.Background` |
| Identity, Mimi | `identity`, `mimi` | `Humdinger.Mimi`, app icon |

## Architecture

```
mic ─► Audio (NIF: YIN pitch, level, spectrum) ─► Engine ─► Tracker ─► MIDI events ─► Output ─┬► FMutate (dist)
                                                     │                                        ├► virtual MIDI port
                                                     └► frames ─► screens (Live, Spectrum…)   ├► USB-MIDI (mob_midi)
                                                                                              └► BLE-MIDI (mob_midi)
```

The real-time path runs in long-lived processes started from `App.on_start`
(`Engine`, `Output`, `FMutate`), never in a screen: Humdinger keeps
listening while the singer plays FMutate in the foreground. Screens
subscribe for display and send commands.

### Shared modules (in place; extend, don't fork)

- `Humdinger.Style` — tokens (ARGB ints), `theme/0` (fonts: `:default`
  Inter, `:medium`, `:semibold`, `:bold`, `:mono` JetBrains Mono,
  `:mono_semibold`, `:mono_bold`, `:display` Bricolage Grotesque 800,
  `:music` Noto Music), `pitch_color/2` (88-key colours), `hsl/3`, `alpha/2`.
- `Humdinger.Music` — note names (sharps, C4 = 60), `parse/1`, Hz ⇄ MIDI, cents.
- `Humdinger.Scale` — root + mode, `name/1` ("D Dorian"), `snap/2`,
  `contains?/2`, `key_fifths/1`, `flats?/1`, `detect/1` (Krumhansl).
- `Humdinger.Take` — a recording's notes + sung-pitch trace, the hand-off
  from `Engine.record_stop/0` and `Transcribe` to `Phrase.from_take/2`.
- `Humdinger.Audio` — the engine contract and its message shapes (read
  its moduledoc): `listen/2`, `set_spectrum/2`, `stop/1`, `inputs/0`,
  `analyze_file/3`; readings `%{t, hz, clarity, db}`; spectrum columns of
  128 log-spaced bins.

### Contracts between parts

**Audio** (`Humdinger.Audio.Native`, `Nif`, `Fake`; `c_src/hum_audio.c`,
`c_src/pitch_yin.c`, `c_src/spectrum.c`): see `Humdinger.Audio`. One
listener at a time; a new `listen/2` replaces the old one (its ref goes
stale); listening stops when the owner exits. `listen/2` answers
`{:error, :permission}` until the screen has asked for the microphone
(`Mob.Permissions.request(socket, :microphone)` → `{:permission,
:microphone, :granted | :denied}`). `Fake` is driven by tests:
`Fake.sing(ref, [reading])`, `spectrum/2`, `fail/2`, `analysis/2`,
`analysis_error/2`, `listening?/1`, `spectrum?/1`, `current/0`,
`set_permission/1`, `reset/0` (one engine per VM: tests that listen are
not `async`).

**Background** (`Humdinger.Background`, Android `HumListenService`):
listening on while FMutate is in front, as an ongoing notification (not an
overlay). `start(owner \\ self(), notice) :: :ok | {:error, :permission |
:refused | :unavailable}` (while the app is in the foreground),
`update(notice) :: :ok | {:error, :not_running}` (call on every change;
unchanged notices are free, the service posts ≤ 4/s), `stop/0`,
`running?/0`. `notice = %{title, text, state: :listening | :paused |
:recording}` (e.g. `%{title: "Humdinger · listening", text: "A4 −12¢ →
FMutate A · ch 1"}`); `state` picks the buttons. Taps arrive at `owner` as
`{:background, :pause | :resume | :record | :record_stop | :stop}`, or
`{:background, :failed}` if Android refused the service after `start`.
The buttons only report: the owner acts and then `update/1`s or `stop/0`s.
Tests: `Fake.background/0` (`%{owner, notice} | nil`),
`Fake.tap_background(action)`.

**Tracker** (`Humdinger.Tracker`, pure): readings in, MIDI events out.
`new(settings)`, `push(tracker, reading) :: {tracker, [event]}`,
`tick(tracker, t_ms) :: {tracker, [event]}` (hold timeouts),
`deadline(tracker) :: t_ms | nil` (when `tick/2` next matters),
`release(tracker) :: {tracker, [event]}` (note off, bend centred, CC 1
zeroed), `configure(tracker, settings) :: {tracker, [event]}` (releases
first when mode, scale, octave, transpose, bend range or channel change),
`display(tracker) :: %{pitch: float | nil, note: midi | nil, cents: float
| nil, hz: float | nil, db: float, velocity: 1..127 | nil, voiced:
boolean, holding: boolean}` (pitch and note after octave/transpose: the
displayed note is the sent one). `response_ms/1` (Fast 30, Balanced 60,
Steady 120: the "~xx ms" on the Settings sheet), `hold_ms/0` (250),
`tuning_label(cents)` ("in tune" < 10¢, "a little flat/sharp" ≤ 30¢, then
"flat"/"sharp"), `cents_label(cents)` ("−12¢ · a little flat"),
`cents_text(cents)` ("−12¢"). Events
carry no channel: `{:note_on, note, velocity}`, `{:note_off, note}`,
`{:pitch_bend, -8192..8191}`, `{:cc, number, value}` (1 and 11).

How it works (the moduledoc has the detail): a gate opens on pitched,
clear (≥ 0.8), loud enough (≥ `sensitivity_db`) readings unbroken for the
response time and closes after 30 ms without a reading that keeps it
(clarity ≥ 0.6, level ≥ gate − 6 dB). Pitch = median of 3, then an
exponential smoother (12/30/60 ms) that jumps on leaps > 1.5 semitones.
Scale mode snaps (`Scale.snap/2`, octave/transpose applied first so notes
stay in the scale) with hysteresis (a quarter semitone past the midpoint)
and changes note after the new one holds for the response time. Open mode
strikes the nearest semitone and bends (1 cent resolution) for the rest,
re-striking when the pitch drifts past the bend range or a slow centre
(100 ms) settles within 40¢ of another semitone, moving < 15¢, for the
response time; bend centres before each new note. `:legato` = new on, old
off; `:new_note` = old off, new on. `:hold` keeps a note 250 ms after the
last voiced reading (same note on re-voicing continues it). Velocity maps
the onset's peak level (gate → 16, −10 dBFS → 127; 100 when off); CC 11
follows the smoothed level (≥ 1 change, ≤ every 20 ms); CC 1 follows
vibrato depth (3.5–9 Hz swing over 500 ms, detrended, 8–100¢ → 0–127).
Property tests run 300 random streams × random settings and check no
note is ever unbalanced.

**Settings** (`Humdinger.Settings`, saved with `Mob.State` under
`:settings` as a plain map, scale as `{root, mode}`): `load/0`, `save/1`,
`update(change) :: {:ok, settings} | {:error, {:invalid, field}}` (re-loads,
merges, validates, saves; `change` is a map/keyword of fields or a
function of the settings), pure `merge(settings, change)` (same result),
`defaults/0`, `decode/1`/`encode/1`, `sensitivity_range/0` (−70..−20 dBFS,
the slider span), `bend_ranges/0`. Loading drops unknown keys and
defaults invalid values (forward/backward compatible). `destinations`
merges into the current map. Fields and defaults: `sensitivity_db` −55
(gate), `response` `:balanced` (`:fast | :balanced | :steady`),
`pitch_change` `:legato` (`| :new_note`), `on_stop` `:hold` (`|
:note_off`, hold = 250 ms), `bend_range` 2 (1, 2, 7, 12),
`velocity_from_loudness` true, `cc11_from_loudness` true,
`cc1_from_vibrato` false, `mode` `:scale` (`| :open`), `scale` D Dorian,
`octave` 0 (−3..3), `transpose` 0 (−12..12), `channel` 1 (1..16),
`destinations` `%{fmutate: true, port: true, usb: false, bt: false}`,
`range` nil (`{low, high}` MIDI), `first_run_done` false. Output persists
`destinations` through `update/1`, the engine everything else, both from a
fresh load so neither clobbers the other.

**Engine** (`Humdinger.Engine`, GenServer, started in `App.on_start`
after Output and before the root screen; starts `:off`, the Live screen
calls `listen/0`): `start_link(audio:, output:, name:)` (defaults
`Audio.impl/0`, i.e. the NIF on the phone and `Audio.Fake` in host tests;
`config :humdinger, :output` or `Humdinger.Output`; `Humdinger.Engine`).
Every call also takes the server as an optional first argument.
`subscribe(pid)` (monitored; replies with the current status at once) →
`{:engine, :frame, frame}` ≤ 30/s while listening (token-guarded 33 ms
timer, latest state, only when changed; plus one per status change),
`{:engine, :status, status}` on change, `{:engine, :spectrum, spectrum}`
for subscribers with `spectrum(pid, true)` (`t` on the frames' engine
clock; the mic computes it only while someone wants it),
`{:engine, :phrase_saved, phrase}` after Stop rec in the notification.
`listen/0 :: :ok | {:error, reason}`, `pause/0` (note off, mic off,
service stays), `resume/0` (after a pause or a mic error), `stop/0` (also
stops the service), `status/0` (`:off | :listening | :paused | {:error,
reason}`; `listen/2` refusals such as `:permission`,
`:microphone_unavailable` and stream errors such as `:device_lost`,
`:input_error` land here, mood `:no_mic`), `settings/0`,
`update_settings(map | fun) :: {:ok, settings} | {:error, {:invalid,
field}}` (saves, then `Tracker.configure/2`; a channel change calls
`output.configure(channel: n)` after the release's note offs),
`record_start/0`, `record_stop/0 :: {:ok, Take.t()} | {:error, :empty |
:not_recording}`, `recording?/0`. A frame: `%{t, pitch, note, cents, hz,
db, velocity, voiced, mood, sent, recording, background}`; `mood`:
`:no_mic` (error), `:paused`, `:idle` (off, or nothing voiced for 5 s and
quieter than gate − 10 dB), `:listening`, `:flat`/`:sharp` (sounding note,
voice ≥ 10¢ off), `:aria` (≥ gate + 35 dB), `:singing`; `sent` = the last
note on/off sent (`Midi.describe/2`); `background` = `:off | :running |
{:error, reason}`. Readings move onto one engine clock that runs across
pause/resume; a hold timer fires `Tracker.tick/2` at `Tracker.deadline/1`.
A take (`Engine.Recording`, pure) has the notes from the note on/off
pairs sent (ms from `record_start`, open notes closed at the stop) and
the tracker's smoothed (shifted) pitch every ≥ 10 ms, one nil per gap.

The engine owns the background notification (`Humdinger.Background`,
text from the pure `Engine.Notice`): every successful `listen/0`/`resume/0`
(the app is in front: Android 14 only lets a foreground app start the
service) starts it unless it runs; text "A4 −12¢ → FMutate A · ch 1" /
"listening… → …" / "paused → …" (destination = the first enabled and
available row of Output's `{:output, :destinations, list}`, which the
engine subscribes to on its first listen; without one, "A4 −12¢ · ch 1"),
titles "Humdinger · listening / recording / paused / no microphone",
updated at most 4/s on change (title/buttons at once). Buttons: Pause,
Resume (also after a mic error), Record, Stop rec (saves the take with
`Phrase.from_take/2` + `Phrases.save/1`, default name, and sends
`{:engine, :phrase_saved, phrase}`), Stop (= `stop/0`). A mic error keeps
the service ("no microphone", Resume). If the service can't start, or
`{:background, :failed}` arrives, the engine keeps listening in front and
frames carry `background: {:error, reason}`; the next listen/resume tries
again. On Android 13+ the notification needs the `:notifications`
permission, which the engine can't detect (the service runs unseen):
the Live screen requests it before the first `listen/0`.

Verifying the Engine: host tests `test/humdinger/{engine,tracker,settings}_test.exs`,
`test/humdinger/engine/` (`Audio.Fake` with an output double; host timers
can fire late on macOS, so tests never depend on a timer being on time).
`Humdinger.Test.FakeAudio` (test/support) is an older double some screen
branches still use. On the phone: deploy, `mix mob.connect --no-iex
--android-only --device <serial>`, then `SERIAL=<serial> mix run
--no-start scripts/engine_check.exs` with the phone by the Mac's speaker:
tones → note ons (and the time from tone start to the first clear reading
to the note on, from a trace of the engine process), frames and moods, a
recorded take, Home pressed (frames, events and the notification text keep
coming), then the notification's buttons through their intents.

**Output** (`Humdinger.Output`, GenServer; `Humdinger.Midi` pure
encoder): `send_events([event])` (cast, on the settings channel),
`configure(channel: 1..16)` (cast; the Engine sends it after the old
channel's note-offs), `destinations/0 :: [%{id: :fmutate | :port | :usb |
:bt, name, detail, enabled, available}]`, `set_enabled(id, bool)` (call,
saves via `Settings.update/1`), `test_note/0`, `panic/0` (call),
`last_sent/0 :: String.t() | nil`, `subscribe(pid)` → `{:output,
:destinations, list}` (at once, then on change), `{:output, :sent,
summary}` (e.g. `"A4 on · vel 92 · ch 1"`, ≤ 10/s, latest wins),
`{:output, :bluetooth, view}`. Bluetooth-MIDI (Output board's "Scan
Bluetooth"): `bluetooth/0 :: %{scanning, found: [%{address, name, rssi}],
error, connecting, paired}`, `scan_bluetooth/0`, `stop_bluetooth_scan/0`,
`connect_bluetooth(address)`, `forget_bluetooth/0`; on `{:error,
:no_permission}` the screen calls `Mob.Permissions.request(socket,
:midi_bluetooth)`. Every function takes an optional last `server` argument.
`Midi.encode(event, channel) :: binary`, `Midi.describe(event, channel) ::
String.t()`, `Midi.all_notes_off(channel, notes \\ []) :: [binary]`.

**FMutate link** (`Humdinger.FMutate`, GenServer): `status/0 :: :unpaired |
:disconnected | {:connected, %{name, firmware, device}}`, `subscribe(pid)` →
`{:fmutate, :status, status}`, `send_midi(binary)` (dropped while not
connected), `forget/0`. Pairing (`Humdinger.FMutate.Pairing`):
`parse_link/1`, `normalize_code/1`, `discover(owner)` → `{:fmutate_pair,
:found, [candidate]}`, `pair(owner, offer)` → `{:fmutate_pair, :waiting}`,
`{:fmutate_pair, :paired, info}`, `{:fmutate_pair, :failed, reason}`,
`cancel/0`. Messages to FMutate follow `design/fmutate/protocol.md` §4.

**Phrases** (`Humdinger.Phrase` pure, `Humdinger.Phrases` storage,
`Humdinger.Tempo`, `Notation`, `Smf`, `MusicXml`, `Transcribe`, `Export`):

- `Phrase` struct: `id, name ("New phrase"), notes (%{start_ms, dur_ms,
  midi, velocity, unsure}, as sung), trace ({t_ms, pitch | nil}),
  duration_ms, tempo_bpm (whole bpm), tempo_detected, scale (Scale | nil =
  open), quantize (:q4 | :q8 | :q16 | :triplet | :off), source (:hum |
  {:file, name}), created_at, updated_at`. The grid is a view: notes stay
  as sung. `from_take(take, name:, quantize: (:q8), now:)` (tempo: the
  take's, else `Tempo.detect`, else 120; leading silence dropped to the
  nearest grid line), `summary/1` ("8 notes · 2 bars at 96 · D Dorian",
  "open" for no scale), `list_summary(phrase, now, utc_offset: s)` ("8 notes
  · 2 bars · D Dorian · today": today / yesterday / Tue / 3 Mar / 3 Mar
  2025), `bars/1`, `quantized_notes/1`, `quantize_notes(notes, bpm, q)`,
  `grid_notes(notes, bpm, q)` (whole steps + index; same-step collisions
  keep the longer note, ends cut at the next start), `steps_per_beat/1`,
  `step_ms/2`, `beat_ms/1`, `spelling_scale/1` (own scale, or the detected
  key for open/chromatic), edits `move_note/3` (clamped 0..127),
  `resize_note(p, i, :start | :end, ms)` (snapped, ≥ 1 step or 60 ms off
  the grid, stops at neighbours; no room → unchanged), `set_tempo/2`
  (40..240, no longer detected), `set_quantize/2`, `rename/2` (blank →
  "New phrase"). Edited notes lose `unsure`.
- `Tempo.detect(onsets_ms) :: %{bpm, confidence, phase_ms} | nil` (60–180
  bpm, eighth-note grid fit, half/double picked toward 100 bpm).
- `Phrases` (SQLite table `phrases`, migration
  `20261112000001_create_phrases`): `list/0` (newest first, `trace: []`),
  `get(id) :: Phrase | nil`, `save(phrase) :: {:ok, Phrase} | {:error,
  :not_found | changeset}` (insert without id, else update; trace thinned
  to 20 ms), `rename(id, name)`, `delete(id) :: :ok | {:error,
  :not_found}`. Host tests get an in-memory database (`config/config.exs`,
  test env) and start `Humdinger.Repo` themselves.
- `Notation.layout(phrase, clef: :auto | :treble | :bass, rhythm: :as_sung
  | :simpler)` → `%{clef, key_fifths, time: {4, 4}, measures: [%{index,
  items}]}`, items per the shared notation contract (beat, type, dots,
  tuplet, midi, step, octave, alter, accidental, staff_pos, tie_to_next,
  beam, note_index). As sung = the phrase's grid (sixteenths when off),
  simpler = quarters. `Notation.staff_pos/3`, `Notation.key_caption(scale |
  nil)` ("D Dorian has no sharps or flats, so no key signature.").
- `Smf.encode(phrase)` (format 0, 480 PPQN, channel 1), `Smf.vlq/1`.
  `MusicXml.encode(phrase, clef:, rhythm:)` (4.0 partwise, validates
  against the official XSD).
- `Transcribe.take(analysis, range:, snap:, quantize:, min_ms:, name:) ::
  {Take, %{note_count, unsure_count, scale, tempo_bpm, voices: :one |
  :several, clear}}`.
- `Export.render(phrase, :mid | :musicxml | :pdf, opts)`,
  `write(phrase, kind, opts) :: {:ok, path}` (into `Export.dir/0`: Android
  `cache/exports`, covered by the app's FileProvider `cache-path`),
  `file_name/2`, `mime/1`, `share(path, title:)`, `print(path, title:)`.
  The PDF is engraved in pure Elixir (`Humdinger.Export.Pdf`,
  `Humdinger.Pdf`, glyph outlines in `Humdinger.MusicGlyphs`, generated by
  `scripts/extract_music_glyphs.py` from `priv/fonts/NotoMusic-Regular.ttf`).
  **Missing native piece:** Mob 0.9 shares text only and can't print, so
  `share/2` and `print/2` call a `Humdinger.Export.Native` module set with
  `config :humdinger, :file_share, Module` and return `{:error,
  :unsupported}` without one. It needs `share_file(path, mime, title)`
  (Android `ACTION_SEND` + `EXTRA_STREAM` FileProvider URI +
  `FLAG_GRANT_READ_URI_PERMISSION`, via `createChooser`) and
  `print_pdf(path, title)` (Android `PrintManager.print` with a
  `PrintDocumentAdapter` streaming the file); see that module's doc.

Verifying the Phrases part: the host tests (`test/humdinger/{phrase, tempo,
phrases, notation, smf, music_xml, transcribe, export, pdf}_test.exs`,
`test/humdinger/export/`). To look at real output, `Export.write(phrase,
kind, dir: "/tmp/x")`, then validate the MusicXML against the official
schema (`xmllint --noout --schema musicxml.xsd`, from
github.com/w3c/musicxml, tag v4.0) and render the PDF with `pdftoppm -png`.

**Views** (pure `Mob.Canvas` op builders under `Humdinger.Views.*`, plus
`Humdinger.Mimi`): the screens compose them; each takes plain data and a
size and returns ops (and, for editable ones, a hit-test function). See
"Views and Mimi" below for each one's data and hit-test.

## Views and Mimi

Every view is `ops(data, w, h) :: [op]`: pure, from plain maps (no domain
modules), canvas-local dp with the origin top-left, colours as ARGB ints
from `Humdinger.Style`. Shared helpers live in `Humdinger.Views.Draw`
(Bézier flattening, `text_width/2`, rounding). Things to know when
composing them:

- **Hit-tests take `on_drag` coordinates.** A canvas `on_tap` carries no
  x/y, and on Android a drag only starts past touch slop, so a stationary
  tap gives no position at all. Drags (move a note, a window, a range
  handle) use `hit/5` on the `began` point; for taps, lay native tap
  targets over the geometry the view exposes (`PianoStrip.keys/3`).
- **Android's canvas renderer ignores `family:`** (it draws the system
  sans, bold for `:medium` and heavier). Views still pass
  `Style.font_family/1` for iOS. Music glyphs are therefore drawn as
  paths, and text a screen wants in a brand font (the big note name,
  "−12¢ · a little flat") is native text: the views give the strings.
- **No clipping, gradients or rotation.** Rounded boxes are drawn as
  clipped polygons, or (PianoStrip's keyboard, Spectrum's box) their
  corners are masked in `Style.bg()`: those two must sit on the app
  background.
- Canvas text width is a guess (≈ 0.56 em per character, MOB-513).

| View | Board | Data | Size | Hit-test |
|---|---|---|---|---|
| `PianoStrip` | live (top) | `%{low, high, active, pitch, range}` | w × `height/0` (129) | `{:key, m}`, `{:window, m}`, `:none`; `keys/3` rects |
| `TuningMeter` | live | `%{cents, tolerance}`; `caption/2`, `velocity_label/1` | w × 22 | — |
| `PitchRoll` | live (trace) | `%{now_ms, trace, notes, scale, center_midi, window_ms?}` | 350 × 256 | — |
| `Spectrum` | spectrum | `%{columns: [%{t, bins}], trace, now_ms, pitch, window_ms?, bins_hz?}`; `legend_ops/2` | 350 × 470 | — |
| `PianoRoll` | record_review, import_audio | `%{notes, trace, scale, tempo_bpm, beats_per_bar?, selected, duration_ms?}`; `layout/3` | 350 × 312 / 210 | `{:note, i, :start \| :end \| :body}`, `{:empty, %{ms, midi}}`, `:none` |
| `Staff` | sheet_music | `%{layout: Notation.layout(…), note_names}`; `height/2`, `systems/2`, `staff_y/2` | w × `height/2` (316 for the board at 350) | — |
| `Waveform` | import_audio | `%{peaks, duration_ms, selection}`; `drag/5`, `ms_per_dp/2` | 344 × 62 | `{:handle, :start \| :end}`, `{:range, ms}`, `{:outside, ms}` |
| `PhraseThumb` | saved | `%{notes}` | 326 × 56 | — |
| `RangeBar` | first_run | `%{pitch, low, high}`; `marker_x/2` | w × 46 | — |
| `QrFrame` | pair | `%{state: :scanning \| :found}`; `square/2` | 350 × 300 | — |

Pitches in view data are fractional MIDI numbers (the engine's `pitch`),
notes are integers; times are ms. Each module's moduledoc has the exact
geometry and the board it follows.

- **PianoStrip**: an 88-key overview (the visible window boxed, keys
  outside the singer's `range` dimmed) over a zoomed keyboard of
  `low..high` (whole white keys ≥ ~36 dp; edge keys cut as on the board).
  The `active` key is filled in its pitch colour; with `pitch` a dark tick
  on it shows where the voice sits within the note.
- **TuningMeter**: track, lime in-tune band (±`tolerance`), centre tick, a
  marker at `cents / 50 · w/2` from the centre; no marker for nil cents.
- **PitchRoll**: 22 dp rows centred on `center_midi` (ease it in the
  screen), in-scale rows striped and labelled bright (naturals when the
  scale is nil), sent notes as pitch-coloured blocks (opaque while
  `end_ms: nil`, 0.55 once ended), the sung pitch as a white line broken at
  nil, the playhead at `w − 44` with a dot on the latest pitch.
- **Spectrum**: columns placed by time over `window_ms`, bins on a log axis
  80 Hz…2.4 kHz, levels quantised by `shade/1` to the legend's five violet
  steps (−62…−30 dBFS, 8 dB apart; retune on a device if real voices look
  too dark), runs merged (≈ 600 ops for 4 s of voice). The trace in the
  current note's colour, "note / ×2 / ×3" chips at the harmonics.
- **PianoRoll**: one row per scale note over the phrase's range (all 12
  for nil / chromatic), beat and bar lines from `tempo_bpm`, note blocks,
  the selected one ringed with end handles, unsure notes faded with a
  "N unsure · faded" chip, the faint sung line. `layout/3` exposes rows,
  blocks and `x_of/2`, `ms_at/2`, `y_of/2`, `midi_at/2`; `hit/5` accepts a
  layout or the data. Edge zones are ≥ 12 dp; the selected note wins.
- **Staff**: the canvas is the paper card (padding 6 / 10 / 6), staff
  lines 12 apart from x 14 to w − 14, systems 150 apart (more when ledger
  notes or name dots need it). Each system: barline, clef, key signature;
  the time signature on the first only. Measures take the width their
  content needs; a system holds as many as fit (squeezed down to 1/1.2 of
  natural before wrapping), then stretches to the full width (a last
  system under 70 % full keeps its natural width); the music ends with a
  thin + thick barline. Heads,
  stems (the beam group's farthest note decides), beams, flags, dots,
  ledger lines, printed accidentals, ties (split at a system break),
  triplet brackets and rests; clefs, accidentals, rests and flags are
  filled polygons from `Humdinger.Views.StaffGlyphs`. `note_names: true`
  adds pitch-coloured letter dots 34 below the staff. `systems/2` gives each
  system's top, x extent and measure indexes (to scroll to a measure).
- **Waveform**: one bar per 3 dp (the max of its 50 ms peaks), lime inside
  the selection, a white box with handles. For a drag keep the `began`
  target and apply `drag(selection0, target, (x − x0) · ms_per_dp, …)`.
- **PhraseThumb**: the phrase's notes as 6 dp pills over a dark well.
- **RangeBar**: the 88-key rainbow, keys outside the chosen low/high dimmed
  (only below `low` while the highest isn't chosen), a white marker at the
  sung pitch, A0 / C8 labels.
- **QrFrame**: lime corner brackets over the camera preview; `:found` adds
  a soft lime fill.

**Mimi** (`Humdinger.Mimi.ops(cx, cy, size, state)`): the board's 64 × 56
bird scaled to `size` dp wide, centred on `{cx, cy}`. `state`: `mood`
(`Mimi.moods/0`: `:idle :listening :singing :aria :flat :sharp
:headphones :paused :no_mic`, the engine frame's `mood`), `note` (feathers;
nil → A4 teal), `loudness` (0..1, opens the beak), `beak_open` (overrides),
`look` (`{dx, dy}`, −1..1; flat/sharp force down/up), `blink` (0..1, the
screen animates it). Aria shuts the eyes in arcs and sings two notes;
paused is grey with "zZ"; no mic is grey with bar eyes; flat/sharp add
↓/↑.

**App icon**: Mimi is the icon. `Mimi.icon_ops/2` is the identity board's
"Dark + pitch stripe": a #1C1925 (`Style.surface/0`) square, Mimi singing
A4 looking up at 105.6/140 of the width, centred, and along the bottom a
10/140-high stripe of eight bands in the pitch colours of MIDI 33 45 52 57
64 69 81 93. `Mimi.icon_foreground_ops/1` is the Android adaptive
foreground: Mimi alone on transparent, 0.49 of the width so she stays in
the 66/108 safe circle; the adaptive background is the colour #1C1925.
Regenerate everything with
`mise exec -- mix run --no-start scripts/render_icon.exs`: it writes
`assets/icon/humdinger-icon-1024.png` (square master; stores and iOS round
it) and `assets/icon/humdinger-icon-foreground-1024.png`, runs `mix
mob.icon --source <master> --adaptive --adaptive-bg "#1C1925"` (legacy
Android, iOS, the adaptive XML and colour), then redraws the five
`mipmap-*/ic_launcher_foreground.png` from the foreground ops (mob.icon
would reuse the whole master, stripe included, and the launcher mask
would crop it). `--assets-only` skips the install.

**Seeing them**: `scripts/canvas_svg.exs` turns ops into SVG and a PNG
(libvips through the `image` dev dependency, under a second);
`mise exec -- mix run --no-start scripts/preview_views.exs [out.png]`
renders every scene of `Humdinger.GalleryScreen` (each view and mood with
board sample data) to `/tmp/humdinger_views/gallery.png` to compare with
`design/shots/*`. On a phone, the same gallery is a dev-only screen
(`dev/` is compiled in dev and test, never in a release) outside the
navigation: after `mix mob.connect`, `Mob.Test.navigate(node,
Humdinger.GalleryScreen)`. Tests: `test/humdinger/views/*`,
`test/humdinger/mimi_test.exs`.

## Output: where the MIDI goes

`Humdinger.Output` (started in `App.on_start`) encodes each batch of
Tracker events once on the channel and sends every message to each
destination that is enabled (Settings `destinations`) and available. It
tracks the notes it left sounding per destination as `{channel, note}`:
turning a destination off sends it exactly those note-offs (USB/Bluetooth
outputs are closed after), `panic/0` sends them plus CC 123 on every channel
used and the current one, and a destination that drops out (FMutate
disconnects, a device is unplugged) forgets its notes.

| Row (board `output`) | `detail` |
|---|---|
| FMutate (`FMutate A` once connected: the status `name`) | `sibling app · connected · X0X` (firmware), `sibling app · not connected`, `sibling app · not paired` |
| Humdinger port | `virtual MIDI · any app can pick it`, `… · 1 app listening`, `… · N apps listening`; `virtual MIDI · not on this phone` without the plugin (host, iOS) |
| USB MIDI out | `nothing plugged in`, or the devices' names (`<name> · can't open` if mob_midi couldn't open it) |
| Bluetooth MIDI | `none paired`, `connecting…`, the connected device's name, `<name> · not connected` (remembered, not connected) |

Encoding (`Humdinger.Midi`): channel 1..16 → status nibble 0..15; note-on
velocity clamped to 1..127 (a note-on stays one); note-off is `8n note 64`;
pitch bend −8192..8191 → 14 bits around 8192, LSB first; everything clamped,
never raised on.

Native side: `plugins/humdinger_midi_port/` (in-repo Mob plugin, unsigned,
in `:acknowledge_unsafe_plugins`; Android only). `HumdingerMidiBridge.kt`
holds:

- **The Humdinger port**: `HumdingerMidiService`, a `MidiDeviceService`
  declared by the plugin's `manifest_application_snippets` (exported,
  `BIND_MIDI_DEVICE_SERVICE`, intent filter + meta-data) with
  `res/xml/humdinger_midi_port.xml`: device `name="Humdinger"`, one
  `<output-port name="Humdinger">` (a service's output port is what other
  apps receive from). Android lists it whenever the app is installed and
  binds the service in the app's process when an app opens the port.
  `Humdinger.Output.Port.send/1` → `portSend` → the port's
  `getOutputPortReceivers()[0].send(bytes, 0, n, System.nanoTime())`; with no
  app connected it returns `{:error, :no_client}` and the bytes are dropped.
  `connections/0` comes from `onDeviceStatusChanged`
  (`getOutputPortOpenCount(0)`).
- **Device watcher** (`MidiManager.DeviceCallback`) and the device list
  with transport (`usb` / `bluetooth` / `virtual`, plus `own` for the port):
  mob_midi 0.2.0 on Android has neither hot-plug events nor the transport.
  Opening and sending to USB/Bluetooth devices goes through mob_midi
  (`MobMidi.open_output/2`, `send_raw/3`, `close/2`); only devices with an
  input port, not virtual, are used. Output opens a device only while its
  destination is on (an Android input port has one opener at a time).
- **Bluetooth-MIDI central**: BLE scan filtered on the BLE-MIDI service
  (10 s), `MidiManager.openBluetoothDevice/3`; the opened device then shows
  up as a `bluetooth` MIDI device. The last one connected is remembered in
  `Mob.State` and reconnected at start while Bluetooth MIDI is on. The
  `:midi_bluetooth` permission capability (the bridge is a
  `MobPermissionProvider`) asks for fine location on Android ≤ 11 and
  BLUETOOTH_SCAN + BLUETOOTH_CONNECT + location on 12+.

All events reach Output as `{:humdinger_midi, tag, json}` through
`humdinger_midi_port_nif.zig` (`subscribe/0` registers the one listener).
Without the plugin (host, iOS) the NIF stub answers `{:error,
:unavailable}`, so the port and devices are simply unavailable.

Output reads the FMutate and Settings modules from `Application.get_env(:humdinger,
:fmutate | :settings, …)`; one that isn't loaded is left out (FMutate
unavailable; defaults channel 1, FMutate + port on, USB + Bluetooth off).
If FMutate isn't running yet, Output retries `subscribe/1` every second.

### Verifying Output on the phone

- Host: `mix test test/humdinger/midi_test.exs test/humdinger/output_test.exs`
  (Output runs against doubles; they report through `$callers`).
- `adb shell dumpsys midi` lists `name=Humdinger … mOutputPortCount=1`
  with the `HumdingerMidiService` service info, even before the app runs.
- Another process receiving from the port:
  `plugins/humdinger_midi_port/tools/midi_probe.sh <serial> Humdinger 30`
  runs a MIDI client as the adb shell user (`app_process`, no app needed),
  opens the port and prints `RECV 90 45 5c` per message. While it listens,
  over dist: `Humdinger.Output.Port.connections()` is 1 and
  `Humdinger.Output.Port.send(<<0x90, 69, 92>>)` (or `Output.test_note()`)
  shows up as `RECV` lines.
- USB/Bluetooth need hardware: plug a USB-MIDI synth (OTG) or scan for a
  BLE-MIDI one; the `:usb` / `:bt` rows should change at once.

## The audio engine

`c_src/hum_audio.c` is a static NIF (`mob.exs` `:static_nifs`, Android
only), `ERL_NIF_INIT(Elixir.Humdinger.Audio.Nif, …)`. It includes
`pitch_yin.c` and `spectrum.c`, which are plain C and build on the Mac.

- **Microphone.** AAudio input, low-latency performance mode, shared, mono
  float at the device's rate (48 kHz, 192-frame bursts = 4 ms on the moto g
  power 2021), VOICE_RECOGNITION preset (no AGC or noise suppression), into
  a lock-free ring. Opened with dlopen (the app links android-24 headers).
  `RECORD_AUDIO` is checked over JNI first (`{:error, :permission}`).
- **Readings.** A listen thread (priority −16, Android's audio priority)
  runs YIN every 255 samples (5.3 ms) over a 42 ms window decimated to
  16 kHz, range 60–1600 Hz (a hummed bass to a whistle): threshold 0.15,
  pitched when the dip is ≤ 0.35, nothing below −70 dBFS. Readings go out
  in pairs (or alone after 6 ms) as finished `%{t, hz, clarity, db}` maps:
  the BEAM only receives them. `t` is the window's middle, ms since the
  `listen/2` call.
- **Spectrum.** Every 1/30 s while on: Hann window over the last 4096
  samples (85 ms); bands narrower than two FFT bins (< ~680 Hz) are the
  window's DFT at the band centre (Goertzel), wider ones the largest bin of
  a radix-2 FFT inside them; levels as sine amplitude, −90 → 0 … −10 dBFS →
  255.
- **Files.** `analyze_file/3`: AMediaExtractor + AMediaCodec on a thread
  per file (m4a/AAC, MP3, WAV, Ogg Opus all checked on the moto g),
  mixed to mono and analysed as it decodes (only the readings are kept):
  readings every 10 ms, a peak byte per 50 ms. A container longer than
  10 min is refused before decoding (`:too_long`). `Mob.Files.pick/2` hands
  over a copied local path (never a `content://` URI), so paths are all it
  takes.
- **Background.** `HumListenService` (host package,
  `android/app/src/main/java/com/genericjam/humdinger/HumListenService.kt`)
  is a foreground service of type microphone; `HumListenBridge` is its JNI
  face. The NIF finds the bridge through the activity's class loader and
  registers `nativeAction` with `RegisterNatives`, which sends
  `{:background, action}`. Without the service Android silences a
  backgrounded app's microphone as soon as the app goes idle (about a
  minute; `adb shell am make-uid-idle com.genericjam.humdinger` does it at
  once): readings keep coming, all at −90 dB. A backgrounded app can't open
  a new microphone stream either (`listen/2` → `:microphone_unavailable`)
  unless the service runs; with it, `listen/2` works from the background.
- **Locks.** `lock` (control path: open/start/stop/close, join) → `send_lock`
  (the listener's owner and ref) → `BG.lock` (the service). A stream is
  closed only once it is quiet; one that won't stop is left open, harmless.

Measured on the moto g power 2021 (Android 11), `scripts/audio_check.exs`:
188 readings/s, 1.85 per message, message interval p50 9.8 ms; from the
newest analysed sample's arrival to the owner's mailbox p50 3–5 ms, p95
8–11 ms (the higher with the spectrum on), max ≤ 18 ms; spectrum 29.9
columns/s. A consumer's per-reading work (match the map, hz → MIDI) is
6–10 µs, 23–25 heap words per reading. A 440 Hz / 660 Hz sine from the Mac
speaker in a quiet room: median +1.5 / +2 ¢, p95 |error| 5 / 4 ¢, no
octave errors, the spectrum's strongest bin 63 (440 Hz) in every column.
When something else sounds in the room the readings follow the mixture
(e.g. a D3 under the 440 Hz tone reads as D3/A3): one voice at a time is
the design. A 12.4 s m4a analyses in 0.8–1.6 s. Input timestamps aren't
available in shared mode (`input_latency_ms: -1`), so the latencies above
start at the callback that delivered the samples (192 frames = 4 ms
bursts).

How to check it:

- Host, detector: `cc -O2 -o /tmp/pitch_host c_src/test/pitch_host.c -lm &&
  /tmp/pitch_host synth` (sines, saw, formant voice with vibrato, weak
  fundamental, whistle; prints cents error and octave errors per kind;
  exit 1 on any octave error or p95 > 10 ¢). A file: `ffmpeg -v error -i
  voice.m4a -ac 1 -ar 48000 -f f32le - | /tmp/pitch_host 48000 > pitch.csv`
  (summary of voiced share and octave jumps on stderr).
- Host, spectrum: `cc -O2 -o /tmp/spectrum_host c_src/test/spectrum_host.c
  -lm && /tmp/spectrum_host` (harmonics 1–4 of tones 98–659 Hz peak in their
  bins with valleys between; a −50 dB sine reads ≈128).
- The C for Android: `$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang
  --target=aarch64-linux-android28 --sysroot=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot
  -I ~/.mob/cache/otp-android-*/erts-*/include -DSTATIC_ERLANG_NIF_LIBNAME=hum_audio
  -Wall -Wextra -fsyntax-only c_src/hum_audio.c` (also `armv7a-linux-androideabi28`,
  `x86_64-linux-android28`).
- Device: after `mix mob.deploy --native --android --device <serial>` and
  `mix mob.connect --no-iex --android-only --device <serial>`,
  `adb shell pm grant com.genericjam.humdinger android.permission.RECORD_AUDIO`,
  then `SERIAL=<serial> mix run --no-start scripts/audio_check.exs` with the
  phone by the Mac's speaker: rates, latencies, tone pitch, spectrum, a
  second listen replacing the first, stop. `FILE=/data/data/com.genericjam.humdinger/files/<f>`
  adds file analysis (push with `adb push` + `adb shell run-as
  com.genericjam.humdinger cp`), `BACKGROUND=1 [IDLE=1] [NOSERVICE=1]`
  listening from the background with the screen off and on (NOSERVICE is
  the control), `BUTTONS=1` the notification's button intents (sent as the
  app's uid through `run-as`, the path a tap in the shade takes),
  listening from the background, update and stop.
  `Humdinger.Audio.Native.info/0` reports the stream and delivery counters.

## Rules for Mob screens here (from Choir Coach; avoid its traps)

- **Every `on_tap` on a screen that re-renders on a timer** (Live,
  Spectrum, First run, anything showing frames) **also declares
  `on_press_out={held()}`** (MOB-509: Android drops a plain tap whose handle
  is from an earlier render). Screen tests check every tap target has it.
- Frame timers carry a token (`{:tick, token}`) and stale ticks are ignored.
- Never call `:mob_nif.*` test functions (e.g. `screen_info/0`) from app
  code: release builds compile them out (MOB-517).
- Canvas text width is a guess (≈0.56 em per character, MOB-513): leave room.
- A drag's end can be lost on Android (MOB-511): end a drag quiet for 1 s.
- Mob's root already insets the safe area; don't pad it again.
- `Mob.Test.tap/2` skips the native tap path: only real touches (`adb shell
  input`) catch lost taps.

## Working on it

- Run mix through mise (`mise exec -- mix …`): `.tool-versions` pins the
  toolchain (zig 0.17.0; a dev build earlier on the PATH fails the native build).
- Gate before every commit: `mix format`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix test`.
- Devices are shared with other agents: lease first (`agent-lease acquire
  <name> --serial <serial>`), release when done (see `~/AGENTS.md`).
- Android: `mix mob.deploy --native --android --device <serial>` after
  native changes (`c_src/`, plugins, manifest), else `mix mob.deploy
  --android --device <serial>`; restart with `mix mob.connect --no-iex
  --android-only --device <serial>`. Scripts over dist need
  `Node.set_cookie(MobDev.DistCookie.for_project!())`.
