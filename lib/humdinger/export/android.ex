defmodule Humdinger.Export.Android do
  @moduledoc """
  `Humdinger.Export.Native` on Android, through the in-repo
  `humdinger_file_share` plugin (`plugins/humdinger_file_share/`): the share
  chooser with the file from the app's FileProvider, and the system print
  dialog for a PDF. Errors: `:not_found`, `:no_activity`, `:no_app`,
  `:failed`; `:unsupported` where the NIF isn't linked (host, iOS).
  """

  @behaviour Humdinger.Export.Native

  @impl true
  def share_file(path, mime, title) do
    path |> :humdinger_file_share_nif.share_file(mime, title) |> result()
  end

  @impl true
  def print_pdf(path, title) do
    path |> :humdinger_file_share_nif.print_pdf(title) |> result()
  end

  defp result({:error, :unavailable}), do: {:error, :unsupported}
  defp result(other), do: other
end
