# Humdinger's file share and print: an exported file to the share sheet
# (ACTION_SEND through the app's FileProvider) and a PDF to the print dialog
# (PrintManager). Android only; the Elixir side is Humdinger.Export.Android
# (see AGENTS.md, "Phrases"). The app's FileProvider
# (${applicationId}.fileprovider, <cache-path path=".">) already covers the
# exports in cache/exports, so the plugin adds no manifest entry or res file.
%{
  name: :humdinger_file_share,
  description: "Humdinger's file share sheet and PDF printing",
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  nifs: [
    %{
      module: :humdinger_file_share_nif,
      native_dir: "priv/native/jni",
      lang: :zig,
      platform: :android
    }
  ],
  android: %{
    bridge_kt: "priv/native/android/HumdingerFileShareBridge.kt",
    bridge_class: "com.genericjam.humdinger.share.HumdingerFileShareBridge"
  }
}
