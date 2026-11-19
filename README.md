# Humdinger

**Hum it, get MIDI.**

Humdinger is a [Mob](https://hexdocs.pm/mob) mobile application (Elixir on the BEAM rendering native UI) that listens to a singer humming, singing, or whistling, detects pitch in real time, converts it into MIDI events, and routes those events to external or sibling synthesizers.

> **Status:** Active development (`dev` and `test` workflows only; no production release pipeline). Singing produces MIDI only; the one local sound is Review's sampled-piano preview of a recorded phrase.

## Current features & platform support

**Android-first** (`com.genericjam.humdinger`, `minSdk 28`, `compileSdk 35`, `targetSdk 35`, ABIs `arm64-v8a`, `armeabi-v7a`, `x86_64`, NDK `27.2.12479018`). Template files exist under [`ios/`](ios/), and pure Elixir/view code stays platform-neutral where cheap, but iOS is a later port: `mob.exs` registers `:hum_audio` for `archs: [:android]` only, the in-repo file-share plugin is an Android-only Kotlin + Zig NIF, and `config/config.exs` configures `Humdinger.Export.Android`.

- **Real-time voice-to-MIDI** (`c_src/hum_audio.c`, `c_src/pitch_yin.c`, `c_src/spectrum.c`, `Humdinger.Engine`, `Humdinger.Tracker`):
  - Live AAudio pitch detection (YIN, 60–1600 Hz, ~5.3 ms hop) and 128-bin log-spaced spectrum analysis.
  - Scale (snap with hysteresis) and Open (pitch-bend tracking) modes, configurable sensitivity gate, response time (`:fast` / `:balanced` / `:steady`), pitch-change mode (`:legato` / `:new_note`), stop behaviour (`:hold` / `:note_off`), velocity, CC 11, CC 1 vibrato, octave, transpose, and MIDI channel.
  - Portrait UI (`Humdinger.LiveScreen`, `Humdinger.SettingsSheet`, `Humdinger.SpectrumScreen`, `Humdinger.FirstRunScreen`) with the mascot **Mimi** (`Humdinger.Mimi`) and canvas views (`Humdinger.Views.*`).
  - Android foreground microphone service (`Humdinger.Background` / `HumListenService.kt`) with ongoing notification controls (Pause, Resume, Record, Stop rec, Stop) so listening continues when another app is in front.
- **MIDI output destinations** (`Humdinger.Output`, exclusive session arbitration to prevent stuck notes):
  - **FMutate** (`Humdinger.FMutate`, `Humdinger.PairScreen`): pairing over QR/link or Crockford code (SRP-6a, mDNS discovery, TLS 1.3 certificate pinning, `mob_secure_store` backed by Android Keystore) and MIDI over Erlang distribution. Same-phone background wake of FMutate via signature-permission service is not yet wired on FMutate's side.
  - **Humdinger virtual MIDI port** (`mob_midi` `~> 0.3.0`, `io.mob.midi.MobMidiDeviceService`): `"Humdinger"` output port declared via `mix mob_midi.gen.virtual_device` (`res/xml/mob_midi_device.xml`) that other Android apps can open.
  - **USB-MIDI & Bluetooth-MIDI**: device enumeration, hot-plug, BLE-MIDI central scan/connect, and queued output via `mob_midi`.
- **Phrases, review, audio import & export**:
  - Record live phrases or import audio files up to 10 minutes (`Humdinger.ImportScreen`, `AMediaExtractor` + `AMediaCodec` decoding, `Humdinger.Transcribe`, `Humdinger.Tempo`).
  - Browse and manage saved phrases (`Humdinger.PhrasesScreen`), inspect/edit on Piano roll or Staff tabs (`Humdinger.PhraseScreen`), and play phrases out to configured MIDI destinations (`Humdinger.Player`).
  - Preview a phrase on the phone as sampled piano (`Player` `mode: :piano`, `c_src/piano.c` mixed into an AAudio output stream in `c_src/hum_audio.c`), with a playhead and the sounding note highlighted on the roll and staff. Samples (`priv/piano/`, prepared by `scripts/prepare_piano.exs`) come from the University of Iowa Musical Instrument Samples; see [`priv/piano/LICENSE`](priv/piano/LICENSE).
  - Local SQLite persistence via `ecto_sqlite3` (`Humdinger.Repo`, migrations in [`priv/repo/migrations/`](priv/repo/migrations/)) plus crash-safe draft recovery (`Humdinger.PhraseDraft`).
  - Export, share, and print Standard MIDI (`.mid`), MusicXML 4.0 (`.musicxml`), and engraved PDF sheet music (`Humdinger.Export`, `Humdinger.Smf`, `Humdinger.MusicXml`, `Humdinger.Export.Pdf`, `plugins/humdinger_file_share/`).

## Toolchain & dev-only setup

Pinned versions in [`.tool-versions`](.tool-versions):

| Tool | Version | Purpose |
|---|---|---|
| Erlang/OTP | `29.1.2` | BEAM runtime (matches Android runtime tarballs) |
| Elixir | `1.20.0-otp-29` | Application and host tooling |
| Java | `temurin-17.0.18` | Gradle / Android build |
| Zig | `0.17.0` | Native NIF compilation (`build.zig` tracks this exact version) |

1. Install pinned tools with [mise](https://mise.jdx.dev) and always invoke Mix via `mise exec --` so the pinned Zig and OTP/Elixir take precedence over global installs:

   ```bash
   mise install
   ```

2. Fetch Elixir dependencies (Hex packages locked in [`mix.lock`](mix.lock), plus `mob_secure_store` pinned by commit from GitHub):

   ```bash
   mise exec -- mix deps.get
   ```

   Note: `mix.exs` includes `{:image, "~> 0.54", only: :dev, runtime: false}` (backed by `vix` / libvips) for dev-only asset/preview scripts (`scripts/render_icon.exs`, `scripts/preview_views.exs`, `scripts/preview_screens.exs`). Under `MIX_ENV=test`, only `:test` / `[:dev, :test]` / unconditional dependencies are required.

3. For Android native builds, install Android SDK (`compileSdk 35`) + Android NDK `27.2.12479018`, then fetch the bundled OTP Android runtimes into `~/.mob/cache/`:

   ```bash
   mise exec -- mix mob.install
   ```

4. Keep any machine-local overrides (such as a local `mob` path checkout) in a gitignored `mob.local.exs` rather than editing [`mob.exs`](mob.exs).

5. Dev-only views gallery: `dev/humdinger/gallery_screen.ex` is compiled in `dev` and `test` only and can be opened on a connected phone with `Mob.Test.navigate(node, Humdinger.GalleryScreen)` or rendered on the host via `mise exec -- mix run --no-start scripts/preview_views.exs`.

## Host verification gates

These match [`.github/workflows/ci.yml`](.github/workflows/ci.yml) and `AGENTS.md`:

```bash
# Elixir gates (MIX_ENV=test)
mise exec -- env MIX_ENV=test mix deps.get
mise exec -- env MIX_ENV=test mix compile --warnings-as-errors
mise exec -- env MIX_ENV=test mix format --check-formatted
mise exec -- env MIX_ENV=test mix credo --strict
mise exec -- env MIX_ENV=test mix test

# Pure-C DSP host harnesses
cc -O2 -o /tmp/pitch_host c_src/test/pitch_host.c -lm && /tmp/pitch_host synth
cc -O2 -o /tmp/spectrum_host c_src/test/spectrum_host.c -lm && /tmp/spectrum_host
```
CI pins Ubuntu 24.04 and fetches dependencies into an empty `deps/` directory;
only compiled `_build/` artifacts are cached. The pitch harness requires at least
99% voiced coverage per tone family, no octave errors, p95 pitch error at most
10 cents, and no detected pitch in noise or silence. A detector producing no
pitches fails the gate rather than reporting zero error as success.


Run `mise exec -- mix format` before committing if formatting changes are needed.

## Safe leased device deployment (Android)

Connected Android phones and emulators are shared across sessions. Always hold an exclusive `agent-lease` before running `adb`, `mix mob.deploy`, or `mix mob.connect`:

```bash
# 1. Inspect existing claims and acquire a device lease
agent-lease status
agent-lease acquire <your-agent-name> --serial <android-serial>

# 2. Verify the lease before each device step (or run via `agent-lease run`)
agent-lease check <your-agent-name>

# 3. Build and deploy
#    Use --native after changes to c_src/, plugins/, or android/
agent-lease run <your-agent-name> -- \
  mise exec -- mix mob.deploy --native --android --device <android-serial>

#    Or for Elixir-only changes:
agent-lease run <your-agent-name> -- \
  mise exec -- mix mob.deploy --android --device <android-serial>

# 4. Restart / attach over Erlang distribution
agent-lease run <your-agent-name> -- \
  mise exec -- mix mob.connect --no-iex --android-only --device <android-serial>

# 5. Always release the lease when done (leases do not expire while their daemon runs)
agent-lease release <your-agent-name>
```

- Mix aliases in [`mix.exs`](mix.exs): `mix android --device <serial>` (`mob.deploy --android`) and `mix android.native --device <serial>` (`mob.deploy --native --android`).
- On-device verification scripts under [`scripts/`](scripts/) (`audio_check.exs`, `realtime_check.exs`, `engine_check.exs`, `background_check.exs`, `analysis_check.exs`, `first_run_check.exs`) run against a connected app via `SERIAL=<android-serial> mise exec -- mix run --no-start scripts/<script>.exs`.
- Android allows only one `UiAutomation` client at a time: if `mobile-mcp` was used on the phone before `agent-device`, stop `com.mobilenext.mobilecli.DeviceServer` first (`adb -s <android-serial> shell pkill -f mobilecli.DeviceServer`).

## Design & source references

- [`AGENTS.md`](AGENTS.md) — module contracts, architecture, measurement baselines, Mob screen rules, and verification procedures
- [`CLAUDE.md`](CLAUDE.md) — pointer to `AGENTS.md`
- [`mix.exs`](mix.exs) & [`mob.exs`](mob.exs) — dependencies, Mix aliases, static NIF declarations, and plugin trust config
- [`config/config.exs`](config/config.exs) — Repo, Audio, and FileShare environment bindings
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — CI pipeline for host Elixir gates and C DSP harnesses
- [`design/boards/`](design/boards/) & [`design/shots/`](design/shots/) — Claude Design HTML boards and rendered 390×844 reference artboards (`mimi-component.html`, `00-identity.html`–`12-import_audio.html`)
- [`design/fmutate/protocol.md`](design/fmutate/protocol.md) & [`design/fmutate/HANDOFF.md`](design/fmutate/HANDOFF.md) — FMutate pairing, TLS distribution, and MIDI protocol specification
- [`design/choir-coach-handoff.md`](design/choir-coach-handoff.md) — audio engine and pitch detector design notes ported from Choir Coach
- [`c_src/`](c_src/) & [`c_src/test/`](c_src/test/) — native AAudio/YIN/spectrum/file-analysis C sources and host test harnesses
- [`plugins/humdinger_file_share/`](plugins/humdinger_file_share/) — in-repo Android native plugin for exporting/printing files
- [`priv/repo/migrations/`](priv/repo/migrations/) — SQLite schema migrations (`20260507000001_create_mob_screen_states.exs`, `20261112000001_create_phrases.exs`, `20261114000001_add_phrases_format.exs`)
