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
`tick(tracker, t_ms) :: {tracker, [event]}` (hold timeouts), `release(tracker)
:: {tracker, [event]}` (all off), `display(tracker) :: %{pitch: float | nil,
note: midi | nil, cents: float | nil, hz: float | nil, db: float, velocity:
1..127 | nil, voiced: boolean}`. Events carry no channel:
`{:note_on, note, velocity}`, `{:note_off, note}`, `{:pitch_bend, -8192..8191}`,
`{:cc, number, value}`.

**Settings** (`Humdinger.Settings`, saved with `Mob.State`): `load/0`,
`save/1`, `update/1`. Fields: `sensitivity_db` (gate), `response` (`:fast |
:balanced | :steady`), `pitch_change` (`:legato | :new_note`), `on_stop`
(`:note_off | :hold`, hold = 250 ms), `bend_range` (1, 2, 7, 12),
`velocity_from_loudness`, `cc11_from_loudness`, `cc1_from_vibrato`, `mode`
(`:scale | :open`), `scale`, `octave` (−3..3), `transpose` (−12..12),
`channel` (1..16), `destinations` (`%{fmutate:, port:, usb:, bt:}` booleans),
`range` (`{low, high}` MIDI or nil), `first_run_done`.

**Engine** (`Humdinger.Engine`, GenServer): `subscribe(pid)` (monitored) →
`{:engine, :frame, frame}` ≤ 30/s while listening, `{:engine, :status,
status}` on change, `{:engine, :spectrum, spectrum}` while a subscriber has
`spectrum(true)`. `listen/0`, `pause/0`, `resume/0`, `stop/0`, `status/0`
(`:off | :listening | :paused | {:error, reason}`), `settings/0`,
`update_settings(map | fun)`, `record_start/0`, `record_stop/0 :: {:ok,
Take.t()} | {:error, :empty}`, `recording?/0`. A frame: `%{t, pitch, note,
cents, hz, db, velocity, voiced, mood, sent}` where `mood` is Mimi's
(`:idle | :listening | :singing | :aria | :flat | :sharp | :paused |
:no_mic`) and `sent` the last event summary. The engine sends tracker
events to `Output.send_events/1`.

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
  once): readings keep coming, all at −90 dB.
- **Locks.** `lock` (control path: open/start/stop/close, join) → `send_lock`
  (the listener's owner and ref) → `BG.lock` (the service). A stream is
  closed only once it is quiet; one that won't stop is left open, harmless.

Measured on the moto g power 2021 (Android 11), `scripts/audio_check.exs`:
188 readings/s, 1.85 per message, message interval p50 9.8 ms; from the
newest analysed sample's arrival to the owner's mailbox p50 4–5 ms, p95
8–12 ms (the higher with the spectrum on), max ~17 ms; spectrum 29.9
columns/s. A consumer's per-reading work (match the map, hz → MIDI) is
6–10 µs, 23–25 heap words per reading. A 440 Hz / 660 Hz sine from the Mac
speaker: median +3 / +3 ¢, p95 |error| 13 / 6 ¢, no octave errors in a
quiet room; the spectrum peaks in bin 63 (440 Hz) in every column. A
12.4 s m4a analyses in 0.8–1.6 s. Input timestamps aren't available in
shared mode (`input_latency_ms: -1`), so the latencies above start at the
callback that delivered the samples.

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
  the control), `BUTTONS=1` real taps on the notification's buttons.
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
