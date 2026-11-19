defmodule HumdingerFileShare.MixProject do
  use Mix.Project

  # Hands an exported file (MIDI, MusicXML, PDF) to another app or the print
  # dialog on Android: a FileProvider share intent and PrintManager, in Kotlin
  # behind a Zig NIF. Mob 0.9 shares text only and can't print. Native plus
  # the Erlang NIF stub only; the Elixir side is Humdinger.Export.Android in
  # the app. See priv/mob_plugin.exs.
  def project do
    [
      app: :humdinger_file_share,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      # As a path dependency, pruning would drop the OTP libraries (xmerl)
      # mob_dev's tooling needs from the code path.
      prune_code_paths: false
    ]
  end

  def application, do: []
end
