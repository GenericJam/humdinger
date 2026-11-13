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
`c_src/pitch_yin.c`): see `Humdinger.Audio`. One listener at a time; a new
`listen/2` replaces the old one (its ref goes stale). `Fake` is driven by
tests: `Fake.sing(ref, [reading])`, `Fake.analysis(ref, analysis)`.

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
"flat"/"sharp"), `cents_label(cents)` ("−12¢ · a little flat"). Events
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
before the root screen; starts `:off`, the Live screen calls `listen/0`):
`start_link(audio:, output:, name:)` (defaults `Audio.impl/0`,
`config :humdinger, :output` or `Humdinger.Output`, `Humdinger.Engine`).
Every call also takes the server as an optional first argument.
`subscribe(pid)` (monitored; replies with the current status at once) →
`{:engine, :frame, frame}` ≤ 30/s while listening (token-guarded 33 ms
timer, latest state, only when changed; plus one per status change),
`{:engine, :status, status}` on change, `{:engine, :spectrum, spectrum}`
for subscribers with `spectrum(pid, true)` (the mic computes it only while
someone wants it). `listen/0 :: :ok | {:error, reason}`, `pause/0` (note
off, mic off), `resume/0`, `stop/0`, `status/0` (`:off | :listening |
:paused | {:error, reason}`; audio errors and refusals land here),
`settings/0`, `update_settings(map | fun) :: {:ok, settings} | {:error,
{:invalid, field}}` (saves, then `Tracker.configure/2`; a channel change
calls `output.configure(channel: n)` after the release's note offs),
`record_start/0`, `record_stop/0 :: {:ok, Take.t()} | {:error, :empty |
:not_recording}`, `recording?/0`, pure `describe(event, channel)` (same
wording as `Midi.describe/2`). A frame: `%{t, pitch, note, cents, hz, db,
velocity, voiced, mood, sent}`; `mood`: `:no_mic` (error), `:paused`,
`:idle` (off, or nothing voiced for 5 s and quieter than gate − 10 dB),
`:listening`, `:flat`/`:sharp` (sounding note, voice ≥ 10¢ off),
`:aria` (≥ gate + 35 dB), `:singing`; `sent` = the last note on/off sent
(`describe/2`). Readings move onto one engine clock that runs across
pause/resume; a hold timer fires `Tracker.tick/2` at `Tracker.deadline/1`.
A take's notes come from the note on/off pairs sent (ms from
`record_start`, open notes closed at the stop), its trace is the
tracker's smoothed (shifted) pitch every ≥ 10 ms with one nil per gap.
Host tests drive it with `Humdinger.Test.FakeAudio` (test/support, the
`Audio.Fake` test API) and an output double; host timers can fire late
(macOS), so tests never depend on a timer being on time.

**Output** (`Humdinger.Output`, GenServer; `Humdinger.Midi` pure
encoder): `send_events([event])` (cast, on the settings channel),
`destinations/0 :: [%{id: :fmutate | :port | :usb | :bt, name, detail,
enabled, available}]`, `set_enabled(id, bool)`, `test_note/0`, `panic/0`,
`subscribe(pid)` → `{:output, :destinations, list}`, `{:output, :sent,
summary}` (e.g. `"A4 on · vel 92 · ch 1"`, throttled). `Midi.encode(event,
channel) :: binary`, `Midi.describe(event, channel) :: String.t()`.

**FMutate link** (`Humdinger.FMutate`, GenServer): `status/0 :: :unpaired |
:disconnected | {:connected, %{name, firmware, device}}`, `subscribe(pid)` →
`{:fmutate, :status, status}`, `send_midi(binary)` (dropped while not
connected), `forget/0`. Pairing (`Humdinger.FMutate.Pairing`):
`parse_link/1`, `normalize_code/1`, `discover(owner)` → `{:fmutate_pair,
:found, [candidate]}`, `pair(owner, offer)` → `{:fmutate_pair, :waiting}`,
`{:fmutate_pair, :paired, info}`, `{:fmutate_pair, :failed, reason}`,
`cancel/0`. Messages to FMutate follow `design/fmutate/protocol.md` §4.

**Phrases** (`Humdinger.Phrase` pure, `Humdinger.Phrases` storage):
`Phrase.from_take(take, opts)`, `summary/1` ("8 notes · 2 bars at 96 · D
Dorian"), `quantize` (`:q4 | :q8 | :q16 | :triplet | :off`), edits
(`move_note/3`, `resize_note/4`, `set_tempo/2`), `Phrases.list/0, get/1,
save/1, rename/2, delete/1`. `Humdinger.Smf.encode/1` (`.mid`),
`Humdinger.MusicXml.encode/2`, `Humdinger.Notation.layout(phrase, clef:,
rhythm:)` (measures of notes/rests for the staff), `Humdinger.Transcribe`
(audio analysis → `Take`, with confidence, scale, tempo, one voice or several).

**Views** (pure `Mob.Canvas` op builders under `Humdinger.Views.*`, plus
`Humdinger.Mimi`): the screens compose them; each takes plain data and a
size and returns ops (and, for editable ones, a hit-test function).

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
