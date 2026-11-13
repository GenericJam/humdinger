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
  name is what the pairing declares) and waits 15 s for it before starting
  its own under the same name, so `mix mob.connect` keeps working.
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
- **Atoms.** Node names and cookies become atoms only from the stored
  pairing (validated by `Record`), and for TLS only after the tunnel checked
  FMutate's certificate; mDNS and pairing input never make atoms.
- **mDNS.** One-shot legacy unicast queries (from an ephemeral port), so
  replies come back unicast and Android needs no `MulticastLock`.
- **Storage.** `mob_secure_store` (git dependency pinned to a commit; not on
  Hex yet, so `mob.exs` acknowledges it as an unsigned plugin). On a phone
  without the plugin's NIF (BEAM-only deploy after adding it) it fails
  closed: pairing reports `{:store, :secure_store_unavailable}` until
  `mix mob.deploy --native`.
- **Not done here:** waking FMutate on the same phone through its
  signature-permission service (FMutate doesn't have it yet); Humdinger
  sends `signing_cert_sha256: null` (a self-reported hash proves nothing;
  protocol §3).
- **Verify.** `mix test test/humdinger/fmutate*`: pairing by link and by
  code (SRP, mDNS on loopback), wrong code ×5, expiry, single use,
  fingerprint mismatch, Allow/Deny/withdraw, then real distribution to a
  `:peer` FMutate with no epmd (loopback TCP and TLS through the tunnel),
  MIDI received, status events, reconnect, revoke, forget. A Mac can play
  FMutate for a phone: run `Humdinger.FMutate.Reference.start/1` in a node
  started with `Reference.Epmd` (and `-proto_dist inet_tls
  -ssl_dist_optfile` for TLS), pairing on `0.0.0.0` with `advertise:`.

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
