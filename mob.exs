# mob.exs — Mob project configuration: plugin activation, plugin trust,
# styles, and build settings. Commit it — a clone without it activates no
# plugins, so their NIFs are left out of the native build.
#
# Machine-specific overrides (e.g. a local `mob_dir` checkout) go in
# mob.local.exs, which is gitignored and imported at the end of this file.
#
# OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

import Config

config :mob_dev,
  # Path to the mob library repo (native source files for iOS/Android builds).
  mob_dir: Path.join(File.cwd!(), "deps/mob"),

  # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
  elixir_lib:
    System.get_env("MOB_ELIXIR_LIB", :code.lib_dir(:elixir) |> to_string() |> Path.dirname()),

  # App identity: one id on both platforms (no "_", so Apple accepts it).
  bundle_id: "com.genericjam.humdinger",

  # Humdinger is a portrait phone app (reference artboard 390 × 844 pt).
  ios_target_devices: [:iphone],
  ios_orientations: :portrait,

  # Open the app from <scheme>://... links: each arrives in Elixir as
  # {:link, %{url: url, source: :launch | :running}} (see Mob.Link). Takes a
  # native rebuild (mix mob.deploy --native). Schemes can't contain "_".
  # Also set android:launchMode="singleTask" on MainActivity in
  # android/app/src/main/AndroidManifest.xml (mob_dev refuses to build without it).
  # url_schemes: ["humdinger"],

  # Several windows of the app on iPad (Split View, Stage Manager, the app
  # switcher), each with its own navigation, in one BEAM. Stamped into the
  # built app's Info.plist as UIApplicationSupportsMultipleScenes. iOS only;
  # Android ignores it. The per-window navigation needs a mob release with
  # Mob.Scene (not released yet, mob#184): keep false until then.
  multi_window: false,

  # The audio engine: c_src/hum_audio.c (AAudio microphone, YIN pitch,
  # spectrum, file analysis), linked into the app as a static NIF. Android
  # only for now.
  static_nifs: [%{module: :hum_audio, archs: [:android]}]

# Activated capability plugins (the packages added in mix.exs). Each contributes
# its native code, permissions, and any demo screens at build time. Drop a name
# here to deactivate a plugin without removing the dep; remove both to drop it
# entirely (the native build shrinks and a clean rebuild prunes its artifacts).
#
# mob_midi: virtual MIDI port, device watcher/hot-plug, USB-MIDI, and
# Bluetooth-MIDI central.
# mob_print: printing exported PDFs through the system print dialog.
# mob_background: the microphone foreground service for listening while another
# app is in front.
# mob_camera + mob_scanner: scanning FMutate's pairing QR code (mob_scanner
# needs mob_camera, which owns the :camera permission).
# mob_secure_store: the FMutate pairing (cookie, client key) in the Android
# Keystore / iOS Keychain.
config :mob, :plugins, [
  :mob_midi,
  :mob_print,
  :mob_background,
  :mob_camera,
  :mob_scanner,
  :mob_secure_store
]

# mob_secure_store isn't released yet, so its checkout carries no signature
# for the trust gate below. It is a git dependency pinned to a commit (mix.lock)
# of the same first-party repo; once it is on Hex, drop it from this list and
# add it to :trusted_plugins with the shared release key like the others.
config :mob, :acknowledge_unsafe_plugins, [:mob_secure_store]

# Trust gate for the first-party plugins. Each is signed in CI with the shared
# mob release key; this is that key's public fingerprint. The build refuses an
# ACTIVATED plugin whose signature doesn't verify against a trusted fingerprint
# (tamper protection) — entries for plugins you haven't activated are simply
# unused, so every official plugin is pre-trusted and "just works" the moment
# you add it to deps + :plugins above. For your own/third-party plugins, run
# `mix mob.plugin.trust <name>`, or `config :mob, :acknowledge_unsafe_plugins,
# [...]` for an unsigned prototype.
config :mob, :trusted_plugins, %{
  mob_midi: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_print: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_background: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_audio_capture: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_camera: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_location: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_biometric: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_scanner: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_bluetooth: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_screencast: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_photos: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_notify: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_mishka: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_ash: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}

if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")
