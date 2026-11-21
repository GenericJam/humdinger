defmodule Humdinger.MixProject do
  use Mix.Project

  def project do
    [
      app: :humdinger,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    # crypto, public_key and ssl: the FMutate link's TLS (pairing, TLS
    # distribution). The Android OTP runtime ships all three.
    [extra_applications: [:logger, :crypto, :public_key, :ssl]]
  end

  # Test doubles (e.g. the scripted microphone) compile in test only; dev/
  # holds development aids (the views gallery), in dev and test builds but
  # never in a release.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:mob, "~> 0.9.31"},
      {:mob_print, "~> 0.1.0"},
      {:mob_background, "~> 0.3.0"},
      # The audio streams under the app's DSP (c_src/hum_audio.c): the
      # microphone, the piano's output, input devices and file decoding.
      # Temporary: main's commit until 0.1.0 is on Hex, then
      # {:mob_audio_io, "~> 0.1"} (see mob.exs for its trust entry).
      {:mob_audio_io,
       github: "GenericJam/mob_audio_io", ref: "ffe299795a79789730b8b51a199503f7d9743dd9"},
      {:mob_dev, "~> 0.7.31", only: :dev, runtime: false},
      # Resizes the icon master for `mix mob.icon` (scripts/render_icon.exs).
      {:image, "~> 0.54", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # Virtual MIDI port, USB-MIDI, and Bluetooth-MIDI (enumeration, hot-plug, BLE central).
      {:mob_midi, "~> 0.3.0"},
      # Scanning FMutate's pairing QR code (mob_scanner needs mob_camera).
      {:mob_camera, "~> 0.1.15"},
      {:mob_scanner, "~> 0.1.8"},
      # The FMutate pairing (cookie, client key) in the Android Keystore /
      # iOS Keychain. Not on Hex yet: pinned to a commit (see mob.exs for
      # its trust entry).
      {:mob_secure_store,
       github: "GenericJam/mob_secure_store", ref: "99a94bcbdfb4ed6f57c2286e994f885488e5886a"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end
end
