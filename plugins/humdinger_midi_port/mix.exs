defmodule HumdingerMidiPort.MixProject do
  use Mix.Project

  # Humdinger's Android MIDI native code, carried as an in-repo Mob plugin: the
  # virtual MIDI port (a MidiDeviceService the manifest must declare, with its
  # res/xml device info), the MIDI device watcher and Bluetooth-MIDI connect,
  # all in Kotlin behind a Zig NIF. A plugin is the only way to ship a Kotlin
  # class, a manifest <service> and a res file through the Mob build. Native
  # plus the Erlang NIF stub only; the Elixir side is Humdinger.Output.Native
  # in the app. See priv/mob_plugin.exs.
  def project do
    [
      app: :humdinger_midi_port,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      # As a path dependency this project is compiled in every mix run of the
      # app, and pruning would then drop the OTP libraries the app's dev
      # tooling needs from the code path (mob_dev's plist check uses xmerl:
      # `mix mob.plugins` and the native build fail with :xmerl_scan undefined).
      prune_code_paths: false
    ]
  end

  def application, do: []
end
