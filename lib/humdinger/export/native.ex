defmodule Humdinger.Export.Native do
  @moduledoc """
  The native side `Humdinger.Export` needs to hand a file to another app,
  set with `config :humdinger, :file_share, Module`. Mob 0.9 has neither
  (its share sheet takes text only), so the app provides it:

  - `share_file/3`, Android: an `Intent.ACTION_SEND` with the MIME type,
    `EXTRA_STREAM` = `FileProvider.getUriForFile(activity,
    "${applicationId}.fileprovider", file)`, `FLAG_GRANT_READ_URI_PERMISSION`,
    through `Intent.createChooser` (title as `EXTRA_TITLE`). iOS: a
    `UIActivityViewController` with the file URL.
  - `print_pdf/2`, Android: `PrintManager.print(title, adapter, null)` with a
    `PrintDocumentAdapter` that copies the PDF file to the print output.
    iOS: `UIPrintInteractionController` with the file URL.

  Both are fire-and-forget: `:ok` once the dialog has been asked for.
  """

  @callback share_file(path :: Path.t(), mime :: String.t(), title :: String.t()) ::
              :ok | {:error, term()}
  @callback print_pdf(path :: Path.t(), title :: String.t()) :: :ok | {:error, term()}
end
