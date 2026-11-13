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
    [extra_applications: [:logger]]
  end

  # Test doubles (e.g. the scripted microphone) compile in test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:mob, "~> 0.9.27"},
      {:mob_dev, "~> 0.7.31", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # USB-MIDI and Bluetooth-MIDI output.
      {:mob_midi, "~> 0.2.0"},
      # The virtual MIDI port, device watcher and Bluetooth-MIDI connect
      # (Android native, in this repo).
      {:humdinger_midi_port, path: "plugins/humdinger_midi_port"},
      # Scanning FMutate's pairing QR code (mob_scanner needs mob_camera).
      {:mob_camera, "~> 0.1.15"},
      {:mob_scanner, "~> 0.1.8"},
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
