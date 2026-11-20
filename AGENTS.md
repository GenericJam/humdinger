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
it), USB-MIDI or Bluetooth-MIDI. Singing makes no sound on the phone; the
only local audio is Review's sampled-piano preview of a recorded phrase. It
also records phrases (piano roll, sheet music, `.mid`, MusicXML) and turns
an audio file into notes. The mascot is **Mimi**, a round hummingbird whose
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
| Singing into FMutate (background) | `fmutate_bg` | `MobBackground` + `Humdinger.Engine.Notice` |
| Identity, Mimi | `identity`, `mimi` | `Humdinger.Mimi`, app icon |

## Architecture

```
mic ─► Audio (NIF: YIN pitch, level, spectrum) ─► Engine ─► Tracker ─► MIDI events ─► Output ─┬► FMutate (dist)
                                                     │                                        ├► virtual MIDI port
                                                     └► frames ─► screens (Live, Spectrum…)   ├► USB-MIDI (mob_midi)
                                                                                              └► BLE-MIDI (mob_midi)
```

The real-time path runs in long-lived processes started from `App.on_start`
(`Humdinger.Realtime`, a `rest_for_one` supervisor of `Output` then
`Engine`; `FMutate` under its own supervisor), never in a screen:
Humdinger keeps listening while the singer plays FMutate in the
foreground. Screens subscribe for display and send commands.

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
- `Humdinger.Controls` — the UI pieces every screen uses (`import
  Humdinger.Controls`), drawn as on the boards; options for the sizes
  and colours a screen needs, never a screen-local copy: `held/0` (the
  `on_press_out` every tap target carries, MOB-509), `page/2` (the
  centred 350-wide column, or `width: nil` for the full width less 20 a
  side, as Output and Pair), `centered/1`, `header/5` + `back_button/1`,
  `heading/1`, `button/3` (kinds `:flat`, `:lime`, `:primary`, `:header`,
  `:raised`, `:action`, `:outline`), `action_row/1`, `play_button/3`,
  `more_button/2`, `segmented/2` (+ `segments/3`), `chip/4` (kinds
  `:pick`, `:menu`, `:tag`), `switch/2`, `stepper/5`, `labelled/3`,
  `mimi/4`, `sheet/4`, `sheet_title/2`, `menu_item/4`, `notice/1`.

### Contracts between parts

**Audio** (`Humdinger.Audio.Native`, `Nif`, `Fake`; `c_src/hum_audio.c`,
`c_src/pitch_yin.c`, `c_src/spectrum.c`): see `Humdinger.Audio`. One
listener at a time; a new `listen/2` replaces the old one (its ref goes
stale); listening stops when the owner exits. `listen/2` answers
`{:error, :permission}` until the screen has asked for the microphone
(`Mob.Permissions.request(socket, :microphone)` → `{:permission,
:microphone, :granted | :denied}`). `Fake` is driven by tests:
`Fake.sing(ref, [reading])`, `spectrum/2`, `fail/2`, `analysis/2`,
`analysis_error/2`, `analyses/0` (the `analyze_file/3` calls, newest
first), `listening?/1`, `spectrum?/1`, `current/0`, `set_permission/1`,
`reset/0` (one engine per VM: tests that listen are
not `async`).

**Background** (`MobBackground`, Android `io.mob.background.BeamForegroundService`;
configured via `config :humdinger, :background`, default `MobBackground` and
`Humdinger.Test.FakeBackground` in host tests): listening on while FMutate is
in front, as an ongoing notification (not an overlay). `MobBackground.start(owner,
mode: :microphone, notification: %{title, text, actions}) :: :ok | {:error,
:permission | :refused | :unavailable | :owner_dead | :unsupported}` (while the
app is in the foreground; max 3 actions), `update(notification) :: :ok | {:error,
:not_running}` (unchanged notifications skip JNI; posts ≤ 4/s), `stop/0`,
`status/0 :: :idle | {:running, mode} | {:error, term}`. `Humdinger.Engine.Notice`
builds `%{title, text, state}` and `Notice.notification/1` maps `state`
(`:listening | :paused | :recording`) to the three action buttons (`:pause` /
`:resume`, `:record` / `:record_stop`, `:stop`). Taps arrive at `owner` as
`{:mob_background, {:action, id}}`; async refusals/timeouts arrive as
`{:mob_background, {:error, :foreground_refused | :timeout}}`. The buttons only
report: the owner acts and then `update/1`s or `stop/0`s. The plugin monitors
`owner` (stopping the service on exit), handles start→stop races, and contributes
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, and its `<service>` to the
merged manifest; the host declares `RECORD_AUDIO` and `POST_NOTIFICATIONS`.
Tests: `FakeBackground.current/0` (`%{owner, mode, notification} | nil`),
`FakeBackground.tap(id)`, `FakeBackground.refuse/0,1`,
`FakeBackground.set_start_result/1`, `FakeBackground.reset/0`.

**Tracker** (`Humdinger.Tracker`, pure): readings in, MIDI events out.
`new(settings)`, `push(tracker, reading) :: {tracker, [event]}`,
`tick(tracker, t_ms) :: {tracker, [event]}` (hold timeouts, and closes the
gate when no reading at all came for 150 ms: a stalled input),
`deadline(tracker) :: t_ms | nil` (when `tick/2` next matters: while
voiced, last voiced reading + 150 ms; else the end of a hold),
`release(tracker) :: {tracker, [event]}` (note off, bend centred, CC 1
zeroed), `configure(tracker, settings) :: {tracker, [event]}` (releases
first when mode, scale, octave, transpose, bend range or channel change;
turning CC 11 off sends `{:cc, 11, 127}` either way),
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

**Engine** (`Humdinger.Engine`, GenServer under `Humdinger.Realtime`,
after Output and before the root screen; starts `:off`, the Live screen
calls `listen/0`): `start_link(audio:, output:, background:, name:,
max_take_ms:)` (defaults `Audio.impl/0`, i.e. the NIF on the phone and
`Audio.Fake` in host tests; `config :humdinger, :output` or
`Humdinger.Output`; `config :humdinger, :background` or `MobBackground`;
`Humdinger.Engine`; 10 min). Every call also takes the server as an
optional first argument.
`watch()` :: `{:ok, monitor} | {:error, :down}` (subscribe + monitor the
engine; screens use it) or `subscribe(pid)` (monitored; replies with the
current status at once) →
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
pause/resume; a timer fires `Tracker.tick/2` at `Tracker.deadline/1`
(hold ends, stalled input).
A take (`Engine.Recording`, pure) has the notes from the note on/off
pairs sent (ms from `record_start`, open notes closed at the stop) and
the tracker's smoothed (shifted) pitch every ≥ 20 ms, one nil per gap; at
10 minutes it is finished and saved as a phrase (`{:engine,
:phrase_saved, phrase}`), so a forgotten recording stays bounded.

When the engine ends (a crash, or `Realtime` restarting it after Output
went), `terminate/2` (it traps exits) sends the sounding note's note-off
and bend/CC resets to the output, stops the microphone and the
notification. The supervisor starts a new engine: `:off`, no subscribers,
no take. Screens that `watch/0`ed get `:DOWN`, then `watch/0` again
every 100 ms until it succeeds: Live puts the new engine back as it was
(listening, or listening then paused), Spectrum turns its spectrum relay
on again, First run just watches. A recording in progress is lost.

The engine owns the background notification (`MobBackground` in `:microphone`
mode, via `config :humdinger, :background`; text and actions from the pure
`Engine.Notice.build/5` and `Engine.Notice.notification/1`): every successful
`listen/0`/`resume/0` (the app is in front: Android 14 only lets a foreground
app start the service) starts it unless it runs; text "A4 −12¢ → FMutate A ·
ch 1" / "listening… → …" / "paused → …" (destination = the first enabled and
available row of Output's `{:output, :destinations, list}`, which the engine
subscribes to on its first listen; without one, "A4 −12¢ · ch 1"), titles
"Humdinger · listening / recording / paused / no microphone", updated at most
4/s on change (title/buttons at once). Buttons arrive as `{:mob_background,
{:action, id}}`: Pause, Resume (also after a mic error), Record, Stop rec
(saves the take with `Phrase.from_take/2` + `Phrases.save/1`, default name, and
sends `{:engine, :phrase_saved, phrase}`), Stop (= `stop/0`). A mic error keeps
the service ("no microphone", Resume). If the service can't start, or
`{:mob_background, {:error, :foreground_refused | :timeout}}` arrives, the
engine keeps listening in front and frames carry `background: {:error, reason}`;
the next listen/resume tries again. On Android 13+ the notification needs the
`:notifications` permission, which the engine can't detect (the service runs
unseen): the Live screen requests it before the first `listen/0`.

Verifying the Engine: host tests `test/humdinger/{engine,tracker,settings}_test.exs`,
`test/humdinger/engine/` (`Audio.Fake` with `Humdinger.Test.FakeOutput`;
host timers can fire late on macOS, so tests never depend on a timer being
on time). On the phone: deploy, `mix mob.connect --no-iex
--android-only --device <serial>`, then `SERIAL=<serial> mix run
--no-start scripts/engine_check.exs` with the phone by the Mac's speaker:
tones → note ons (and the time from tone start to the first clear reading
to the note on, from a trace of the engine process), frames and moods, a
recorded take, Home pressed (frames, events and the notification text keep
coming), then the notification's buttons through their intents.
Measured on the moto g power 2021 (Balanced, room −67 dBFS, sensitivity
−59, `VOLUME=3`): every tone became its note; first clear reading → note
on 58–65 ms (the 60 ms response plus a reading batch); tone start → note
on 258–290 ms, about 200 ms of it before the first clear reading (afplay
start, speaker, the 42 ms YIN window); frames 29.2/s; in the background
the notification read "A4 0¢ → Humdinger port · ch 1" mid-tone. With the
tones only 2–5 dB over the gate (`VOLUME=1`) some onsets took 300–400 ms
(readings dipping under the gate restart the onset), and the first tone
after a silence sometimes read as its subharmonics (D3 for A4) for
300–600 ms, which the engine then plays: a detector-level effect at low
signal, not seen at the louder level.

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
`connect_bluetooth(address)`, `forget_bluetooth/0`; on `:permission_denied`
the screen calls `Mob.Permissions.request(socket, :midi_bluetooth)`. Every
function takes an optional last `server` argument.
`Midi.encode(event, channel) :: binary`, `Midi.describe(event, channel) ::
String.t()`, `Midi.all_notes_off(channel, notes \\ []) :: [binary]`.

**FMutate link** (`Humdinger.FMutate`, GenServer): `status/0 :: :unpaired |
:disconnected | {:connected, %{name, firmware, device, emulator}}` (`emulator`:
FMutate's last `:status` event or nil), `subscribe(pid)` → `{:fmutate,
:status, status}` (now and on change), `unsubscribe(pid)`,
`send_midi(binary)` (dropped while not connected or when the link is
backed up), `forget/0 :: :ok | {:error, reason}`, `reconnect/0` (retry now),
`install(record)` (Pairing's hand-off). Pairing
(`Humdinger.FMutate.Pairing`): `parse_link/1 :: {:ok, offer} | {:error,
reason}`, `normalize_code/1 :: {:ok, "KQ7M-X2PD"} | {:error, :invalid_code}`,
`discover(owner)` → `{:fmutate_pair, :found, [candidate]}` on each change
(candidate `%{name, inst, node, host, port, dist_port, fp, firmware,
device}`; `port` nil = not showing its code), `pair(owner, offer)` (offer: a
parsed link, or `%{code: code}` / `%{code: code, candidate: candidate}`) →
`{:fmutate_pair, :matched, candidate}` ("code matches"), `{:fmutate_pair,
:waiting}`, `{:fmutate_pair, :paired, %{name, device, firmware, inst,
same_phone}}`, `{:fmutate_pair, :failed, reason}`, `cancel/0`. Each function
also takes the server as an optional last argument. Messages to FMutate
follow `design/fmutate/protocol.md` §1.5 and §4; details in "FMutate link"
below.

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
  `file_name/2`, `mime/1`, `share(socket, path, title:)`, `print(path, title:)`.
  The PDF is engraved in pure Elixir (`Humdinger.Export.Pdf`,
  `Humdinger.Pdf`, glyph outlines in `Humdinger.MusicGlyphs`, generated by
  `scripts/extract_music_glyphs.py` from `priv/fonts/NotoMusic-Regular.ttf`).
  `share/3` delegates to `Mob.Share.file/3` (`config :humdinger, :share`,
  `Humdinger.Test.Share` in host tests): fire-and-forget, returns `socket`, and
  delivers setup failures (`:not_found`, `:no_activity`, `:no_app`, `:failed`,
  `:unsupported`) to `self()` as `{:mob_share, :error, reason}`, so screens
  write the file in `start_async/3` (`PhraseActions.write_share/3`) and call
  `PhraseActions.share/3` from `handle_async/3` in the screen process (and
  handle `{:mob_share, :error, reason}` in `handle_info/2`). `print/2` is
  PDF-only and delegates synchronously to `MobPrint.pdf/2` (`config :humdinger,
  :print`, `Humdinger.Test.Print` in host tests), fine inside `start_async/3`.
  Needs mob ≥ 0.9.31 (`Mob.Share.file/3`), mob_print 0.1 and mob_background
  0.3 (`:microphone` mode); the app's `MobBridge.kt` carries `shareFile` from
  mob_new 0.6.20.

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
turning a destination off sends it exactly those note-offs, then pitch bend
centre, CC 1 = 0 and CC 11 = 127 on each channel it used and the current one
(USB/Bluetooth outputs are closed after); `panic/0` sends the note-offs, CC
123 and the same resets; a destination that drops out (FMutate disconnects,
a device is unplugged, the last app leaves the port) forgets its notes.
Nothing is sent to the port while no app has it open.

Never a stuck note:

- **One source at a time, arbitrated by Output.** The live source is
  `send_events/1` (the Engine). A `Humdinger.Player` (phrase playback,
  Import's "Play out", Output's test note) plays in an Output session:
  `Output.acquire/2` (owner monitored) releases the live notes and resets
  the controllers, then drops live events until `release/2`;
  `session_events/3` carry the player's. A newer session preempts an older
  one (its notes off, its owner gets `{:output, :session_ended, ref}` and
  reports `:finished`); a session whose owner dies (even `:kill`) has its
  notes released by Output. The Engine follows (`follow_session/2`:
  `{:output, :session, :active | :idle}`) only to keep quiet and start its
  next note afresh; its status doesn't change, so Live's cached state and an
  Engine restart mid-session don't matter (a new Engine is told `:active`
  when it subscribes). The player sends `{:player, :finished, tag}` only
  after its note-offs and `release/2`. The test note is a Player Output
  owns, so a tap while it sounds restarts it (300 ms from the last tap).
  Sounding notes are tracked per destination as `{source, channel, note}`.
- **Output exits** trap and `terminate/2` panics every destination
  directly, each adapter call guarded (a destination that raises is logged
  and skipped, the others still silenced). The Engine's `terminate/2` sends
  its release and syncs; when Output is the one that died nothing can be
  sent, and Output's own terminate covered it.
- **A destination that comes back is reset before any note**: CC 123 +
  controller resets on all 16 channels to the port when Output starts and
  when the first app opens it again, and to a USB/Bluetooth output once
  mob_midi reports it open. FMutate sends its own panic on every
  (re)connection.
- **No output drops silently**: on Android each open output (the virtual port
  and USB/Bluetooth devices) has its own per-port queue and dispatch thread in
  `mob_midi` (`mob_midi_core.c`). A full queue answers `{:error, :queue_full}`
  and refuses sends until drained: Output calls `MobMidi.discard/1` (drops the
  stale queued bytes and starts a new queue generation) and stops sending to
  that output only (other destinations carry on and stay tracked). Once the
  queue has drained, `mob_midi` sends `{:midi, :drained, %{device, port,
  handle, generation}}`; Output ignores stale generations and sends the
  note-offs it still knows of, CC 123 and resets before anything new.
- **FMutate** treats a dropped (`nosuspend`) MIDI cast as a resync: no more
  MIDI (`{:fmutate, :midi, :resyncing}`), a full panic retried every 50 ms
  until it goes through (`:ready`), the connection dropped after 2 s. A
  connection is set up the same way: the `:status` subscription and then
  the panic must both go out before MIDI flows (`:resyncing` reaches
  subscribers before the connected status). `design/fmutate/protocol.md`
  §4.1 requires FMutate to release a sibling's notes when its node goes
  (`Reference.Instance` does).

| Row (board `output`) | `detail` |
|---|---|
| FMutate (`FMutate A` once connected: the status `name`) | `sibling app · connected · X0X` (firmware), `sibling app · not connected`, `sibling app · not paired` |
| Humdinger port | `virtual MIDI · any app can pick it`, `… · 1 app listening`, `… · N apps listening`; `virtual MIDI · not on this phone` where `open_virtual` is unavailable (host, or a phone without Android MIDI) |
| USB MIDI out | `nothing plugged in`, or the devices' names (`<name> · can't open` if mob_midi couldn't open it) |
| Bluetooth MIDI | `none paired`, `connecting…`, the connected device's name, `<name> · not connected` (remembered, not connected) |

Encoding (`Humdinger.Midi`): channel 1..16 → status nibble 0..15; note-on
velocity clamped to 1..127 (a note-on stays one); note-off is `8n note 64`;
pitch bend −8192..8191 → 14 bits around 8192, LSB first; everything clamped,
never raised on.

Native side: `mob_midi` (`~> 0.3.0`, signed first-party plugin; no in-repo
MIDI plugin). All MIDI operations pass `nil` as the socket from
`Humdinger.Output`, so replies arrive directly in Output as `{:midi, ...}`
messages:

- **The Humdinger port**: `io.mob.midi.MobMidiDeviceService`, declared in
  `AndroidManifest.xml` with `res/xml/mob_midi_device.xml`, generated by
  `mix mob_midi.gen.virtual_device` (and `--check`), which reads
  `config :mob_midi, :virtual_device` (`name`, `inputs`, `outputs`,
  `manufacturer`): device `name="Humdinger"`, one
  `<output-port name="Humdinger">` (a service's output port is what other
  apps receive from). Output calls `MobMidi.open_virtual(nil, "Humdinger")`
  at start and gets `{:midi, :opened, %{device: id, direction: :virtual,
  name: "Humdinger"}}` followed by `{:midi, :virtual_status, %{device: id,
  senders: n, listeners: n}}`. `Humdinger.Output.Port.send/2` calls
  `MobMidi.send_raw(nil, id, bytes)` into the port's C queue and dispatch
  thread (`{:error, :no_listener}` with no app listening; `{:error,
  :queue_full}` when full, followed by `MobMidi.discard/1` and `{:midi,
  :drained, %{device, port, handle, generation}}`).
- **Device list and hot-plug**: `MobMidi.list_devices(nil)` delivers
  `{:midi, :devices, payload}` (normalised with `MobMidi.parse_devices/1`,
  carrying `type: :usb | :bluetooth | :virtual | :other`, `address`,
  `input_ports`, `output_ports` and `own`) and subscribes Output to
  `{:midi, :device_added | :device_removed, nil}` (Output re-lists on
  either). Output skips `own` devices and virtual devices, using only USB and
  Bluetooth devices with a writeable port (`output_ports > 0`, Android's
  `inputPortCount`). Opening, closing and sending go through
  `MobMidi.open_output/2`, `send_raw/3`, `discard/1` and `close/2`; Output
  opens a device only while its destination is on (an Android input port has
  one opener at a time).
- **Bluetooth-MIDI central**: `MobMidi.scan_bluetooth(nil, duration_ms:
  10_000)` (`{:midi, :bluetooth_scan, :started | :stopped}`,
  `{:midi, :bluetooth_device, %{address, name, rssi}}`, errors via `{:midi,
  :error, %{op: :scan_bluetooth, reason: ...}}`), `MobMidi.connect_bluetooth/2`
  (`{:midi, :connected, %{device, address}}` or `op: :connect_bluetooth`
  error) and `MobMidi.close/2` to disconnect. The last connected device is
  remembered in `Mob.State` (`Humdinger.Output.Device.recall/0`,
  `remember/1`) and reconnected at start while Bluetooth MIDI is on. The
  `:midi_bluetooth` permission capability (`MobMidiBridge`, a
  `MobPermissionProvider`) asks for fine location on Android ≤ 11 and
  BLUETOOTH_SCAN + BLUETOOTH_CONNECT + location on 12+.

On the host `MobMidi` answers `{:error, :unsupported}`, so the port and
devices are simply unavailable.

Output reads the FMutate and Settings modules from `Application.get_env(:humdinger,
:fmutate | :settings, …)`; one that isn't loaded is left out (FMutate
unavailable; defaults channel 1, FMutate + port on, USB + Bluetooth off).
If FMutate isn't running yet, Output retries `subscribe/1` every second; it
monitors the FMutate process and, when it restarts, marks it disconnected and
subscribes again.

### Verifying Output on the phone

- Host: `mix test test/humdinger/midi_test.exs test/humdinger/output_test.exs`
  (Output runs against doubles; they report through `$callers`).
- `adb shell dumpsys midi` lists `name=Humdinger … mOutputPortCount=1`
  with the `io.mob.midi.MobMidiDeviceService` service info, even before the
  app runs.
- Another process receiving from the port: mob_midi's probe, which lives in
  the mob_midi source repo (Hex doesn't ship `tools/`):
  `~/code/mob_midi/tools/midi_probe.sh <serial> Humdinger listen 30`
  runs a MIDI client as the adb shell user (`app_process`, no app needed),
  opens the port and prints `RECV <port> <received ns> <sent ns> 90 45 5c`
  per message. While it listens, over dist: `Humdinger.Output.destinations()`
  shows `"virtual MIDI · 1 app listening"`, the client first receives the
  per-channel reset, and `Humdinger.Output.test_note()` shows up as `RECV`
  lines (`90 45 5c`, then `80 45 40` 300 ms later).
- A stuck client: `~/code/mob_midi/tools/midi_probe.sh <serial> Humdinger stall 10`
  stops reading for 10 s at the first message. Flood the port over dist
  (`Output.send_events/1` with a few thousand bends): the probe prints
  `STALL`, `MobMidi.send_raw/3` answers `{:error, :queue_full}` once the
  queue is full, Output calls `MobMidi.discard/1`, and after `RESUME` the
  probe receives what was in the socket, then the note-offs, CC 123 and
  resets, then new notes.
- USB/Bluetooth need hardware: plug a USB-MIDI synth (OTG) or scan for a
  BLE-MIDI one; the `:usb` / `:bt` rows should change at once.

### The Output and Pair screens

`Humdinger.OutputScreen` (board `output`) subscribes to `Output` and to
the FMutate link (`config :humdinger, :fmutate`, the key Output reads too)
and re-renders on their messages, so every tap target carries
`on_press_out={held()}` (`Humdinger.Controls`, MOB-509).

- **Cards**: `Output.destinations/0`, badge tiles FM / PORT / USB / BT.
  The switch shows `enabled` (tap → `Output.set_enabled/2`); the lime
  outline means enabled *and* available; an unavailable card is dimmed
  but still switchable (it sends once the device shows up). FMutate unpaired
  reads "not paired · pair below"; once paired (connected or not) the card
  has "Forget this FMutate" → `Mob.Alert` confirm → `FMutate.forget/0`.
- **Pair FMutate · QR or code** pushes `PairScreen`. **Scan Bluetooth**
  opens a `<Sheet>` driven by `Output.bluetooth/0` and `{:output,
  :bluetooth, view}`: scanning spinner, finds with Connect / Connecting…,
  the paired device with Forget, Scan again / Stop, Done (closing stops a
  scan). `:permission_denied` → `Mob.Permissions.request(socket,
  :midi_bluetooth)` → granted scans again, denied explains Settings;
  scan errors (`bluetooth_off`, `location_off`, …) read as sentences
  (`OutputScreen.bt_message/2`).
- **CHANNEL** taps call `Engine.update_settings(%{channel: n})` (the
  engine releases notes on the old channel, then moves Output). **WHAT GETS
  SENT** is `OutputScreen.chips/1` of `Engine.settings/0`: an off chip is
  outlined (pitch bend in Scale mode, CC 11 / velocity when not from
  loudness), CC 1 appears only with vibrato on. **Last sent** follows
  `{:output, :sent, summary}` ("nothing yet" before); **Send test note** is
  `Output.test_note/0`. The footer turns amber and semibold when every
  destination is off.

`Humdinger.PairScreen` (board `pair`) talks to the pairing service in
`config :humdinger, :pairing` (default `Humdinger.FMutate.Pairing`) and
reads the clipboard through `config :humdinger, :clipboard` (default
`Mob.Clipboard`); both keys exist for the screen tests' doubles.

- Mount calls `discover(self())`; `terminate/2` calls `cancel/0` (the
  service also drops an owner that exits).
- **Scan**: the viewfinder box (QrFrame brackets over a camera glyph, the
  "Point at the code" chip) is one tap target: it asks for `:camera`, then
  `MobScanner.scan(socket, formats: [:qr])` (full screen); `{:scan,
  :result, %{value: link}}` → `parse_link/1` → `pair/2`. A non-FMutate code,
  a refused camera and an unavailable scanner each get a sentence.
- **Code field**: while a code is incomplete the field keeps the keys as
  typed (a controlled Android field adopts any value the screen changes,
  and during fast typing that drops the keys still in flight:
  `MobTextSync`); once `PairScreen.format_code/1` / `normalize_code/1`
  accept 8 characters it shows `XXXX-XXXX`, turns lime and pairing starts
  (once per code; Return retries). **Paste** formats at once. A link typed
  or pasted pairs by link.
- **FOUND NEARBY**: `{:fmutate_pair, :found, list}` rows "FMutate A · X0X"
  / "Pixel 7 · Wi-Fi · showing its code" ("this phone" for 127.0.0.1, "not
  showing its code" when `port` is nil, untappable), "code matches" after
  `:matched` (a link's FMutate is listed even if mDNS didn't see it).
  Tapping one picks it: the code then pairs with `%{code:, candidate:}`.
- **Status card** (`PairScreen.status_view/2`, Mimi 54 × 48): idle hint;
  "Finding FMutate…" / "Code matches FMutate A" / "Waiting for Allow…" with
  Cancel (`cancel/0`, then `discover/1` again); "Paired with FMutate A",
  then `pop_screen` after 1.5 s; failures through
  `PairScreen.failure_text/1` with Try again (re-pairs the same offer,
  except wrong code / too many tries / expired / used token / not a link,
  which clear the field for a fresh code).

Host calls that only exist on a phone (`Mob.Permissions`, `Mob.Alert`) are
skipped under `config :humdinger, device_calls: false` (host tests); the
state they lead to is still assigned, so tests deliver the answer
(`{:permission, …}`, `{:alert, …}`) themselves. MobScanner's NIF is
`config :mob_scanner, :nif` (a stub in the tests). Tests:
`test/humdinger/{output,pair}_screen_test.exs` (a real named `Output` and
`Engine` over doubles; the pairing double reports to the screen's process).

Layout notes from the phone: both screens use the board's 20 dp side
padding at full width (a fixed-width column isn't centred by its parent's
`align` on Android); the viewfinder is a 350 × 300 canvas centred in a
full-width box. A `:text` with `text_align` fills the width unless
`fill_width: false` (it pushed a weighted sibling to zero width), and
`<Progress>` inside a row grows to fill the sheet: the scan row uses a lime
dot instead.

Checked on the moto g power (Android 11), 2026-11-12: both screens opened
over `Mob.Test.navigate/3`, compared with the boards; real `adb shell input
tap` on the USB switch, channel 5 and Send test note (Output and Engine
state followed, "A4 off · ch 5" in Last sent), Scan Bluetooth (sheet,
`:midi_bluetooth` already granted, a 10 s scan with nothing nearby), Pair
(navigated), the viewfinder (Android's camera prompt, then
`MobScannerActivity`; closing it returns to idle), `adb shell input text`
of the code (all keys kept, `KQ7M-X2PD` lime, a real pairing that failed
`:not_found` with no FMutate on the Wi-Fi) and back (the pairing service
left with no owner).

## The audio engine

`c_src/hum_audio.c` is a static NIF (`mob.exs` `:static_nifs`, Android
only), `ERL_NIF_INIT(Elixir.Humdinger.Audio.Nif, …)`. It includes
`pitch_yin.c` and `spectrum.c`, which are plain C and build on the Mac.

- **Microphone.** AAudio input, low-latency performance mode, shared, mono
  float at the device's rate (48 kHz everywhere so far), VOICE_PERFORMANCE
  preset (VOICE_RECOGNITION before Android 10, where it doesn't exist), into
  a lock-free ring. Opened with dlopen (the app links android-24 headers).
  `RECORD_AUDIO` is checked over JNI first (`{:error, :permission}`). Why
  that preset, measured with `realtime_check.exs PRESETS=1` (room level,
  then a 220 Hz tone from the Mac at `afplay -v 8`, 5 s each):

  | phone | preset | burst | room | tone (± spread) |
  |---|---|---|---|---|
  | moto e 2020 (A10, armv7) | VOICE_RECOGNITION | 240 | | −21.5 ± 0.2 |
  | | VOICE_PERFORMANCE | 240 | | −21.6 ± 0.1 |
  | | UNPROCESSED | 240 | | −18.6 ± 0.1 |
  | moto g power 2021 (A11) | VOICE_RECOGNITION | 192 | −58.5 | −40.2 ± 3.6 |
  | | VOICE_PERFORMANCE | 192 | −59.4 | −29.0 ± 3.1 |
  | | UNPROCESSED | 960 | −62.5 | −31.8 ± 3.2 |
  | moto g power 5G 2024 (A15) | VOICE_RECOGNITION | 960 (not low latency) | −51.6 | −21.7 ± 0.2 |
  | | VOICE_PERFORMANCE | 240 | −51.2 | −20.7 ± 0.1 |
  | | UNPROCESSED | 960 | −69.2 | −44.1 ± 0.1 |

  None shows AGC (a steady tone stays steady; the moto g 2021's ±3 dB is
  the room, alike in every preset) and all hear the tone's pitch alike.
  VOICE_PERFORMANCE ("live performance": no processing, low latency) is
  never worse: it keeps the moto g 2021's voice 11 dB further above its
  room than VOICE_RECOGNITION, and gets the 2024 phone's low-latency path
  (5 ms bursts instead of 20 ms). UNPROCESSED is optional per device and
  hears the 2024 phone's voice 22 dB quieter. `Nif.set_input_preset/1`
  exists only for such measurements.
- **Readings.** A listen thread (priority −16, Android's audio priority)
  runs YIN every 255 samples (5.3 ms) over a 42 ms window decimated to
  16 kHz, range 60–1600 Hz (a hummed bass to a whistle): threshold 0.15,
  pitched when the dip is ≤ 0.35, nothing below −70 dBFS. The difference
  function, most of a reading, sums in eight independent partial sums
  (NEON on arm64, VFP registers on 32-bit ARM). Readings go out in pairs
  (or alone after 6 ms) as finished `%{t, hz, clarity, db}` maps: the BEAM
  only receives them. `t` is the window's middle, ms since the `listen/2`
  call. More than 30 ms of unread audio (or two bursts and a hop, or a
  window and a hop) means the thread is behind: it restarts on the newest
  window and drops the readings in between (`skipped_ms`, `skips` in
  `info/0`) rather than deliver them late.
- **Spectrum.** Every 1/30 s while on, and only when the readings have
  caught up: Hann window over the last 4096 samples (85 ms); bands narrower
  than two FFT bins (< ~680 Hz) read a second, zoomed FFT of the same
  window low-passed and decimated by 4 (bins 2.9 Hz apart), interpolated at
  the band centre (Goertzel at rates too low to decimate); wider bands the
  largest bin of the radix-2 FFT inside them; levels as sine amplitude,
  −90 → 0 … −10 dBFS → 255.
- **32-bit ARM.** zig builds `armeabi-v7a` soft-float by default (its
  androideabi ABI), which turns every C float operation into a library
  call: a reading cost 11 ms on the moto e 2020, more than its 5.3 ms hop,
  so readings arrived seconds late. `android/app/src/main/jni/build.zig`
  adds `-mfloat-abi=softfp` for that ABI (hardware VFP/NEON, floats passed
  in core registers as the NDK's armeabi-v7a does, so it links with the
  rest), and `hum_audio.c` refuses to compile soft-float. NEON vector
  intrinsics still don't compile under zig's settings there (the backend
  crashes), hence scalar partial sums on 32-bit ARM. The same template
  flaw affects every app built from mob_new's `build.zig` that does float
  math in C on armeabi-v7a.
- **Files.** `analyze_file/3`: AMediaExtractor + AMediaCodec on a thread
  per owner (m4a/AAC, MP3, WAV, Ogg Opus all checked on the moto g),
  mixed to mono and analysed as it decodes (only the readings are kept):
  readings every 10 ms, a peak byte per 50 ms. A container longer than
  10 min is refused before decoding (`:too_long`). `Mob.Files.pick/2` hands
  over a copied local path (never a `content://` URI), so paths are all it
  takes. A job ends early and sends nothing on `cancel_analysis/1`, on a
  newer analysis by the same owner (one per owner), or when the owner
  exits (monitored); the decoder checks its cancel flag every buffer. Each
  owner has one thread: a newer analysis while the owner's previous one is
  still stopping waits for that thread, which then runs it, and an even
  newer one replaces the waiting one, so a burst of replacements never
  piles up decoders. While two other owners have a thread running
  (cancelled ones too, until they notice) a third owner gets `{:error,
  :busy}`. `info/0`'s `analyses` counts the running threads. The Import
  screen cancels its analysis on Back, on `terminate/2` and before another
  file.
  The generated Android bridge copies picker results into random cache
  filenames, obtains their original names from `OpenableColumns.DISPLAY_NAME`,
  and serializes metadata with `JSONObject`. A document's `lastPathSegment`
  is an opaque ID, not a filename: Downloads can return `raw:/storage/…`,
  which previously made the copy fail and report cancellation. Failed copies
  remove their temporary files. Checked through the real Android Downloads
  picker on the moto g power 2021: a three-tone WAV reaches Import's ready
  state with A4, C5 and E5, then opens Review.
- **Background.** Provided by the `mob_background` plugin
  (`io.mob.background.BeamForegroundService`, `mode: :microphone`), which
  delivers notification button taps as `{:mob_background, {:action, id}}`.
  Without the service Android silences a backgrounded app's microphone as soon
  as the app goes idle (about a minute; `adb shell am make-uid-idle
  com.genericjam.humdinger` does it at once): readings keep coming, all at
  −90 dB. A backgrounded app can't open a new microphone stream either
  (`listen/2` → `:microphone_unavailable`) unless the service runs; with it,
  `listen/2` works from the background.
- **Locks.** `lock` (control path: open/start/stop/close, join) → `send_lock`
  (the listener's owner and ref). A stream is closed only once it is quiet;
  one that won't stop is left open, harmless.

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

Keeping up, `scripts/realtime_check.exs` (5 s each; "lag" is `info/0`'s:
from the input callback that delivered a batch's newest sample to the send,
the stream's burst comes before it; "reading" and "column" are what one
costs on the listen thread, which a phone at rest runs at a low clock):

| phone | build | readings/s | lag p50 / p95 / max | reading | column |
|---|---|---|---|---|---|
| moto e 2020 (armv7) | before (soft-float, master) | ≈ 92 | mean ≈ 850, max ≈ 2800 | — | — |
| | soft-float + catch-up | 82 (1.2 s skipped / 5 s) | p95 ≈ 64 | 11.2 ms | 44 ms |
| | now, spectrum off | 188 | 2.0 / 2.5 / 8 | 0.6–0.7 ms | — |
| | now, spectrum on | 188 | 2.0 / 5.5 / 9 | 0.65 ms | 5.3 ms |
| moto g power 2021 (arm64) | before, spectrum on | 188 | (old metric) max 19 | 1.36–1.7 ms | 9.2 ms |
| | now, spectrum on | 188 | 1.5 / 8.0 / 10 | 0.45 ms | 4.5–5.1 ms |
| moto g power 5G 2024 | now, VOICE_RECOGNITION (20 ms bursts) | 188 | 1.0 / 7.5 / 9 | 0.06 ms | 0.6 ms |
| | now, VOICE_PERFORMANCE (5 ms bursts) | 188 | 1.5 / 3.5 / 9 | 0.07–0.3 ms | 0.6–3 ms |

The p95 near 8 ms on some rows is the 6 ms wait of a lone reading for its
partner. Host (Apple silicon, `-Os`): a reading 90 → 13 µs, a column 455
→ 69 µs; the host harness's numbers (cents, octave errors, voiced share)
are unchanged to the printed digit.

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
- Device, keeping up: `SERIAL=<serial> mix run --no-start
  scripts/realtime_check.exs` listens with the spectrum off, then on, and
  prints readings/s, batch size, capture→mailbox delay p50/p95/max, what a
  reading and a column cost, and audio skipped; `PRESETS=1` compares the
  input presets on a 220 Hz tone from the Mac (`afplay -v 8`).
  `scripts/first_run_check.exs` plays 220 Hz then 330 Hz and checks the
  First run range step takes {A3, E4}.
- Device, the service's lifecycle: `SERIAL=<serial> mix run --no-start
  scripts/background_check.exs` (grant POST_NOTIFICATIONS on Android 13+):
  20 × start then immediate stop, start/stop/start, 30 updates then stop,
  owner death, a dead owner; each checks the notification list, the app's
  pid and logcat. The build before these fixes crashed on Android 15
  (`ForegroundServiceDidNotStartInTimeException`) at the first check.
- Device, file analyses ending: `SERIAL=<serial> mix run --no-start
  scripts/analysis_check.exs` with a long (< 10 min) file pushed into the
  app's `files/`: cancel_analysis, a second analysis by the same owner, the
  owner's death, the two-owner cap, a burst of 20 replacements (at most one
  thread), and the Import screen (another file, Back, pop); each checks the
  running count, the app's CPU and threads, and logcat.

## FMutate link

`lib/humdinger/fmutate.ex` and `lib/humdinger/fmutate/`; the wire protocol
and trust model are `design/fmutate/protocol.md` §1.5 and §3 (written from
this implementation, for FMutate to implement the other side).

- **Modules.** `FMutate` (the link: load, connect, reconnect with backoff 1,
  2, 5, 10, 30 s, follow a moved FMutate over mDNS, status, MIDI),
  `Pairing` (the Pair screen's service) and `Pairing.Client` (one exchange),
  `PairLink` (the QR/link), `Code` (Crockford codes), `Srp` (SRP-6a),
  `Wire` (JSON frames over TLS 1.3), `Cert` (self-signed ECDSA certificates,
  pinning `verify_fun`), `Record` + `Store` (the pairing in
  `mob_secure_store`), `Transport` (node, cookie, connection), `Epmd` (port
  mapper), `Tunnel` (TLS distribution), `Discovery` + `Dns` (mDNS browse),
  `Supervisor` (started in `App.on_start`).
- **Reference FMutate side** (`Humdinger.FMutate.Reference.*`: `Epmd`,
  `Pairings`, `Instance`, `PairingServer`, `Responder`; `Reference.start/1`
  runs them). Shippable code FMutate can copy; the tests run it in a
  `:peer` node, and a Mac can stand in for FMutate with it.
- **Distribution on Mob.** Humdinger only connects out: when it starts its
  own node it is hidden, without a listener (`dist_listen: false`),
  auto-connect off, random default cookie, so a release build listens on
  nothing. FMutate's node gets the pairing's cookie (`:erlang.set_cookie/2`)
  and a hidden connection (`hidden_connect_node/1`, messages to
  `:fmutate_instance`). In a dev build on Android, `Mob.Dist` starts the
  loopback dev node a few seconds after boot; the link uses that node (its
  name is what the pairing declares), waiting up to 15 s for it and starting
  its own under the same name if it doesn't come, so `mix mob.connect`
  keeps working with a pairing stored.
  `Transport.setup/1` (in `App.on_start`, before `Mob.Dist`) makes
  `Humdinger.FMutate.Epmd` the kernel `epmd_module`: FMutate's node is
  routed to its port from the pairing, everything else (the dev node's
  registration with the Mac's epmd) goes to OTP's `erl_epmd`.
- **TLS across phones without a relaunch.** `-proto_dist` is an init
  argument (read at boot; `Mob.InitArgs` would only apply it at the next
  launch, and Android starts distribution at runtime anyway). Humdinger's
  node stays on `inet_tcp`; `Tunnel` connects to FMutate's stock
  `inet_tls` listener (mutual TLS 1.3, both certificates pinned), accepts
  one loopback connection from this BEAM only, and reframes the handshake
  (2-byte vs 4-byte lengths) before passing bytes through.
- **OTP on Android.** The Android runtime (`~/.mob/cache/otp-android-d199a49a`)
  ships `crypto` 5.10 (with `crypto.so`), `public_key` 1.21.8, `ssl` 11.7.8
  and `asn1` 5.5.2 (ebin 0.2, 2.9, 2.5 and 1.3 MB); a stripped release
  build must keep all four. `mix.exs` lists them in `extra_applications`.
- **Carriers (security).** Plain `inet_tcp` distribution is loopback only:
  `Record.validate/1` refuses it to any other host, `Transport.connect/2`
  refuses it again, and the reference FMutate grants `inet_tls` to every
  sibling that isn't on its phone (with plain distribution it answers
  `loopback_only`, and its listener is bound to 127.0.0.1 by
  `Reference.boot_args/1`). Reference FMutate also sets a random default
  cookie, restricts plain distribution to paired names
  (`:net_kernel.allow/1`), refuses `fmutate_*` node names, flags a pairing
  that would replace another, strips control characters from the names it
  shows, limits pairing connections to 8, and writes its TLS option file
  0600. mDNS answers are only tried (never loopback, never another node
  name) and saved after they connect. `Record` hides `cookie` and `key` from
  `inspect`.
- **Atoms.** Node names and cookies become atoms only from the stored
  pairing (validated by `Record`), and for TLS only after the tunnel checked
  FMutate's certificate; mDNS and pairing input never make atoms.
- **mDNS.** One-shot legacy unicast queries (from an ephemeral port), so
  replies come back unicast and Android needs no `MulticastLock`. Replies
  must echo a query's id; records are kept per instance *and* reply source,
  so a forged reply under FMutate's label is a second candidate (each tried
  once per outage by host and dport), never a replacement. FMutate on
  Android should advertise with `NsdManager` (the system responder owns
  5353). A Mac standing in for FMutate: advertise with `dns-sd -R "FMutate
  A" _fmutate._tcp local <port> v=1 inst=a node=… fp=… port=… dport=…`;
  `Reference.Responder` binds 5353 next to mDNSResponder, but processes
  started from an agent's terminal can't use LAN multicast on macOS (Local
  Network privacy), so the phone doesn't hear it.
- **Storage.** `mob_secure_store` (git dependency pinned to a commit; not on
  Hex yet, so `mob.exs` acknowledges it as an unsigned plugin). On a phone
  without the plugin's NIF (BEAM-only deploy after adding it) it fails
  closed: pairing reports `{:store, :secure_store_unavailable}` until
  `mix mob.deploy --native`.
- **Device name.** `Mob.Device.model/0` answers `"Android"` on Android (mob's
  NIF doesn't read `Build.MODEL` yet), so pairing reads `getprop
  ro.product.model` ("moto g power (2021)").
- **Not done here:** waking FMutate on the same phone through its
  signature-permission service (FMutate doesn't have it yet); Humdinger
  sends `signing_cert_sha256: null` (a self-reported hash proves nothing;
  protocol §3).
- **Verify (host).** `mix test test/humdinger/fmutate*`: pairing by link and
  by code (SRP, mDNS on loopback), wrong code ×5, expiry, single use,
  fingerprint mismatch, Allow/Deny/withdraw, then real distribution to a
  `:peer` FMutate with no epmd (loopback TCP, and TLS through the tunnel),
  MIDI received, status events, reconnect, revoke, forget.
- **Verify (phone, Mac as FMutate).** Start a node on the Mac with
  `--erl "<Reference.boot_args(dist_port: 45124, ssl_dist_optfile: <file from
  Pairings.write_ssl_dist_optfile/2>) joined by spaces>"` and
  `ERL_LIBS=_build/dev/lib`, run `Humdinger.FMutate.Reference.start/1` with
  `pairing: [cert:, host: <Mac IP>, port: 45123, dist_port: 45124,
  dist_proto: :inet_tls, approve: fn _ -> :allow end]`, advertise with
  `dns-sd -R`, then drive the phone over `mix mob.connect` (RPC
  `Pairing.pair/2`, `FMutate.status/0`, `send_midi/1`). Checked on the moto
  g power (Android 11), 2026-11-12: `ssl`/`public_key`/`crypto`/`asn1`
  load, SRP and certificates work, `MobSecureStore.Native` (Keystore)
  stores and deletes; mDNS found the Mac in 1.5 s without a multicast
  lock; pairing by typed code and by link, TLS distribution through the
  tunnel over Wi-Fi, MIDI and status events arrived; the pairing survived
  app restarts (with `mob.connect`: on Mob's dev node; without: the link's
  own hidden node after the grace); `forget/0` revoked it on both sides.
  Same-phone loopback was only tested on the host (no FMutate app yet).

## Phrase screens: Phrases, Review, Import

`Humdinger.PhrasesScreen`, `Humdinger.PhraseScreen` (Review: Piano roll |
Staff) and `Humdinger.ImportScreen` use `Humdinger.Controls` (back
chevron, header, segmented controls, buttons, stepper, sheets, all with
`on_press_out={held()}`), share `Humdinger.PhraseActions` (write + share sheet,
print, the "Play out to <destination>" label, error wording) and
`Humdinger.Player`. Menus, rename and confirmations are `<Sheet>`s in the
tree (not native alerts), so the tests see them.

**Player** (`Humdinger.Player`, one per screen, linked to it): `play(player,
notes, tag, opts \\ [])` sends `Phrase.quantized_notes/1` out through the
output (`config :humdinger, :output`) at their times, batches same-time
events note offs first, re-strikes an overlapping pitch, tells the owner
`{:player, :finished, tag}`; `stop/1` and the screen going away send the
note offs. Each tick reads the clock and sends everything due, so a late
timer delays but never drops or drifts (`clock:` / `output:` / `audio:`
options for tests). `mode: :piano` plays the notes on the phone instead
(`Audio.play_piano/2`, packaged samples in `priv/piano`, no MIDI sent)
while still holding the Output session, so live MIDI stays out and a newer
session preempts it; the owner gets `{:player, :position, tag, ms}` (the
speaker's actual position, ≤ 30 Hz), then `:finished` or
`{:player, :error, tag, reason}`. Before acquiring, the player resolves and
monitors the exact Output pid (`{:error, :output_down}` if there is none);
Output dying, preemption, Stop, replay and the owner dying all cancel the
native preview before the session is released. `cancel_piano/1` returns
`{:error, :stream_stuck}` when AAudio won't stop the stream: the player
reports it (Stop and Play return the error, the screen shows a notice) and
the next play refuses rather than share the orphaned stream. Review's
highlight follows the played timeline (`note_index`), not the notation's
own rounding.

- **Phrases** (board `saved`): params none (Live pushes it with `%{}`).
  States: loading (`start_async`), the list (`<LazyList>`), empty (Mimi +
  hint). Card: play (lime while playing), name + `list_summary/3`, ⋯,
  thumb; name/thumb open the review. ⋯ sheet: Rename (text field sheet,
  `Phrases.rename/2`), Sheet music (review on Staff), Export .mid (share
  sheet), Share (.mid / sheet music PDF / MusicXML), Delete (confirm
  sheet). "+ From audio file" → Import. Reloads on `:phrases_changed`.
- **Review** (boards `record_review`, `sheet_music`): params `phrase:`
  (unsaved, from Live or Import) or `id:` (loaded async; gone → a
  message), `tab: :roll | :staff`, `notify:` (gets `:phrases_changed` after
  Save), `return_to:` (Live; gets `:hum_again`, then the screen pops to
  Live). Roll: notes on the phrase grid (`PhraseScreen.roll_data/2` maps
  view blocks to `phrase.notes` indexes); a drag's `began` point goes
  through `PianoRoll.hit/5` on the roll as drawn then: body → rows
  (`move_note/3`), ends → time (`resize_note/4`); quiet 1 s ends a drag.
  Quantize, Tempo ±1, Play out / Stop, Save ("Saved" while unchanged),
  Export .mid, Discard (asks when unsaved; Back asks the same). Name taps
  open a rename sheet (an edit like the others, kept by Save). Staff: Clef,
  Rhythm, Note names, key caption, Share as PDF, MusicXML, Print, Play back.
  System Back can't be intercepted (Mob pops without asking) and the app's
  stop order isn't ours, so unsaved work is a draft in `Mob.State`
  (`Humdinger.PhraseDraft`, not the database): a new phrase at mount, each
  edit 500 ms after it settles. `terminate/2` writes the draft, then tries
  to save (Repo exits/raises caught); a draft left behind is saved by
  `PhraseDraft.recover/0` in `App.on_start` after the migrations. Save,
  Discard and Hum again delete the draft.
- **Import** (board `import_audio`): params `notify:`. Stages `:choose`
  (on the phone the picker opens with the screen: `Mob.Files.pick/2`,
  audio types; results checked with `Mob.Files.accept/2`), `:analysing`
  (`Audio.impl().analyze_file/3`; a stale ref is ignored), `:ready`,
  `{:error, text}` (decoding failed, or no `analyze_file/3` in this build).
  Ready keeps the analysis and re-runs `Transcribe.take/2` on every
  change: range (waveform drag: handles, the box, or a touch outside pulls
  the nearer edge; transcribed when the drag ends), Snap (detected key, a
  key from the root/mode sheet, Chromatic), Quantize, Ignore (20–300 ms).
  Edit as a phrase / Sheet music push Review with `Phrase.from_take/2`.

Verifying: `mix test test/humdinger/{player,phrases_screen,phrase_screen,
import_screen}_test.exs` (`Humdinger.Test.FakeOutput`, `Humdinger.Test.Share`
and `Humdinger.Test.Print` report to the test through `config :humdinger,
:test_listener` (`Humdinger.Test.Listener`), file analysis goes through
`Audio.Fake`; the database helper is `test/support/test_repo.ex`). On the phone, over dist:
`Humdinger.Phrases.save/1` a phrase, `Mob.Test.navigate(node,
Humdinger.PhrasesScreen)`; drag notes with `adb shell input swipe` on the
roll; Export/Share/Print open the system share sheet and print dialog.

## Screens: Live, Settings, Spectrum, First run

All four re-render on Engine frames, so every tap target carries
`on_press_out={held()}` (`Humdinger.Controls`) and each screen's
tests assert it (`Humdinger.Test.Screens.assert_every_tap_held/1`). Frames
arm a token-guarded 33 ms tick (`{:tick, token}`); the tick takes the
newest frame. Without a screen-size API (Mob's
`screen_info` is test-only) content sits in a centred 350-wide column,
the boards' 390 minus 20 a side (30 a side on the 411 dp Moto G).

- **Live** (`Humdinger.LiveScreen`, root). Mount: subscribe to Engine and
  Output, ask for `:microphone` (then `:notifications`, only for the
  background notice), `Engine.listen/0`. First launch
  (`first_run_done` false) pushes First run first and asks for the
  microphone when First run reports `{:first_run, :done}`. States: listening
  (note in its pitch colour, `vel N`, tuning meter, `Tracker.cents_label/1`;
  silent: the last note faint, "hum something" / "listening…"); paused
  ("Resume", Mimi asleep, "paused · not sending"); no microphone (refused,
  engine error, or no audio module in the build: Mimi `:no_mic`, what
  happened, "Try again" / "Open settings"); recording (square stop button,
  "recording · 0:07"; stop → `Phrase.from_take/2` → push
  `Humdinger.PhraseScreen` `%{phrase:, return_to: self()}`; an empty take
  says so). `:hum_again` starts a recording; `{:engine, :phrase_saved, _}`
  shows "Saved “name”"; frames' `recording` (when present) is followed, except
  within 0.5 s of a tap here; frames' `background: {:error, _}` adds
  "listening stops when you leave the app". Canvases are memoised per input
  key (`refresh/1`), so silence after the roll empties redraws nothing; Mimi
  blinks on her own timer; the screen is kept awake while the voice is heard
  and released when Mimi idles, pauses or loses the microphone. Geometry:
  `LiveFeed` keeps 4.5 s of frames (sung trace, sent notes from the frames'
  `note`); the roll's centre eases toward the middle of what the last 4 s
  held (`roll_target/1`, within 4 semitones of the voice); the strip's window
  is 15 semitones from a white key and moves when the note leaves its inner
  keys; its overview dims outside the range shifted by octave and transpose.
  The pill names the first enabled destination and sums up the rest
  (`destination_summary/2`); Output, Phrases and the review push by module
  when `Code.ensure_loaded?/1`, else a "not in this build" note.
- **Settings sheet** (`Humdinger.SettingsSheet`, a `<Sheet>` Live renders
  while `sheet: :settings`; the scale picker is a second sheet). Every
  control sends `{:set, field, value}` → `Engine.update_settings/1`. The
  Sensitivity bar is a dragged canvas: room level (smoothed `db` of unvoiced
  frames), voice level (voiced), the gate line; saved on the drag's end or
  after 1 s without drag events (MOB-511). Response shows
  `Tracker.response_ms/1`; bend chips dim outside Open mode. "Your range …
  find again ›" pushes First run `%{step: :range, only: true}`. Deviation:
  the board's dimmed "A4 · still listening" header sits inside the native
  sheet (as its first row) rather than above it.
- **Spectrum** (`Humdinger.SpectrumScreen`): `Engine.spectrum(self(), true)`
  on mount, off in `terminate/2`. Keeps the columns of the last 4 s; a
  column older than the newest starts over (new listen). The trace is the
  raw sung pitch (Hz → MIDI) placed at the frame's `t` when it agrees with
  the columns' clock, else at the newest column's time plus its age.
  "Notes" pops back.
- **First run** (`Humdinger.FirstRunScreen`): Mic (asks; refused → Open
  settings / Try again) · Headphones · Range · Send to (Output's
  destinations with switches, "More in Output ›"). Range uses
  `Humdinger.RangeFinder` on the raw sung pitch: a hold starts on a voiced
  frame, survives silences ≤ 250 ms and stays within ±1 semitone of its start
  (off-note readings count as a new note only after a consistent 100 ms run
  that outnumbers the held note's readings meanwhile, so octave blips are
  ignored; the last held note stays on screen through a pause);
  2 s sets the lowest, then the highest (a highest not above the lowest is
  refused). Both in → saved at once with `octave = RangeFinder.octave_for/1`
  (the shift −3..3 that brings the range's middle nearest E4, MIDI 64: E2–G4
  → +1). Finishing or Skip saves `first_run_done` and pops; `terminate/2`
  sends `{:first_run, :done}` to `return_to` however it closes.

Verifying: `mix test test/humdinger/{live_screen,first_run_screen,
spectrum_screen,range_finder,live_feed}_test.exs` (a real Engine on
`Humdinger.Audio.Fake` and `Humdinger.Test.FakeOutput`;
`Humdinger.Test.Screens.pump_frame/1` waits for the Engine's frame and the
screen's tick). `mise exec -- mix run --no-start scripts/preview_screens.exs`
drives the screens with the boards' data and writes their canvases to
`/tmp/humdinger_screens/{live,settings,spectrum,first_run}.png`. On the
phone: deploy, open each screen (`Mob.Test.navigate(node,
Humdinger.SpectrumScreen)` etc.), `adb exec-out screencap -p`, and tap with
real `adb shell input tap` (Mob.Test.tap skips the native path).

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
- Release APK: README's "Releasing (Android APK)" (`mix mob.release
  --android`, then `./gradlew assembleRelease`). It is signed with
  `android/upload_jks.keystore` + `android/keystore.properties` (gitignored,
  0600, only in the main checkout): the app's permanent signing identity.
  Never print, copy into a worktree's commit, or regenerate them; bump
  `versionCode` every release. Installing a release over a dev build (debug
  key) fails until the dev build is uninstalled, which wipes the phone's
  Humdinger data.
