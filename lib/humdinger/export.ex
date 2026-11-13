defmodule Humdinger.Export do
  @moduledoc """
  Files of a phrase for other apps: `.mid` (`Humdinger.Smf`), MusicXML
  (`Humdinger.MusicXml`) and sheet-music PDF (`Humdinger.Export.Pdf`), and
  handing them to the phone's share sheet or print dialog.

  Files go to the export directory, overwritten per phrase name and kind;
  exports older than a day are removed when a new one is written. On Android
  that is `cache/exports` next to the app's files directory: the app's
  `FileProvider` (`res/xml/file_provider_paths.xml`, `<cache-path
  path=".">`) can grant other apps access to anything under the cache
  directory.

  Mob itself can only share plain text (`Mob.Share.text/2`) and has no
  printing, so sharing a file and printing go through a native hook set with
  `config :humdinger, :file_share, Module` (a `Humdinger.Export.Native`).
  Without one, `share/2` and `print/2` return `{:error, :unsupported}`.
  """

  alias Humdinger.Export.Pdf
  alias Humdinger.{MusicXml, Phrase, Smf}

  @type kind :: :mid | :musicxml | :pdf

  @extensions %{mid: ".mid", musicxml: ".musicxml", pdf: ".pdf"}
  @mimes %{
    mid: "audio/midi",
    musicxml: "application/vnd.recordare.musicxml+xml",
    pdf: "application/pdf"
  }
  @max_age_s 24 * 60 * 60

  @doc "The file's bytes. Options: `clef:`, `rhythm:` (MusicXML, PDF), `note_names:` (PDF)."
  @spec render(Phrase.t(), kind(), keyword()) :: binary()
  def render(%Phrase{} = phrase, :mid, _opts), do: Smf.encode(phrase)

  def render(%Phrase{} = phrase, :musicxml, opts),
    do: MusicXml.encode(phrase, Keyword.take(opts, [:clef, :rhythm]))

  def render(%Phrase{} = phrase, :pdf, opts),
    do: Pdf.render(phrase, Keyword.take(opts, [:clef, :rhythm, :note_names]))

  @doc """
  Writes the phrase as `kind` into the export directory (or `dir:`), and
  returns the file's path. Options as `render/3`.
  """
  @spec write(Phrase.t(), kind(), keyword()) :: {:ok, Path.t()} | {:error, File.posix()}
  def write(%Phrase{} = phrase, kind, opts \\ []) when is_map_key(@extensions, kind) do
    dir = Keyword.get_lazy(opts, :dir, &dir/0)
    path = Path.join(dir, file_name(phrase, kind))

    with :ok <- File.mkdir_p(dir),
         :ok <- remove_stale(dir),
         :ok <- File.write(path, render(phrase, kind, opts)) do
      {:ok, path}
    end
  end

  @doc """
  The file name for a phrase: its name without characters file systems or
  share targets choke on, plus the extension ("Bus stop riff.mid").
  """
  @spec file_name(Phrase.t(), kind()) :: String.t()
  def file_name(%Phrase{name: name}, kind) do
    base =
      name
      |> String.replace(~r{[/\\:*?"<>|\x00-\x1F]}u, "")
      |> String.trim()
      |> String.trim_leading(".")
      |> String.slice(0, 80)

    base = if base == "", do: "phrase", else: base
    base <> Map.fetch!(@extensions, kind)
  end

  @doc "The MIME type of an export kind."
  @spec mime(kind()) :: String.t()
  def mime(kind), do: Map.fetch!(@mimes, kind)

  @doc """
  The export directory: `config :humdinger, :export_dir` when set; on
  Android the app's `cache/exports`; elsewhere `exports` in `Mob.data_dir/0`.
  """
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:humdinger, :export_dir) do
      nil -> default_dir(System.get_env("MOB_DATA_DIR"))
      dir -> dir
    end
  end

  # Android's MOB_DATA_DIR is getFilesDir(), a sibling of getCacheDir().
  defp default_dir(data_dir) when is_binary(data_dir) do
    if Path.basename(data_dir) == "files",
      do: Path.join([Path.dirname(data_dir), "cache", "exports"]),
      else: Path.join(data_dir, "exports")
  end

  defp default_dir(nil), do: Path.join(Mob.data_dir(), "exports")

  defp remove_stale(dir) do
    cutoff = System.os_time(:second) - @max_age_s

    with {:ok, files} <- File.ls(dir) do
      for file <- files,
          path = Path.join(dir, file),
          {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
          mtime < cutoff,
          do: File.rm(path)

      :ok
    end
  end

  @doc """
  Opens the share sheet with an exported file. `{:error, :unsupported}`
  when the app has no native file-share hook (see the moduledoc).
  """
  @spec share(Path.t(), keyword()) :: :ok | {:error, term()}
  def share(path, opts \\ []) when is_binary(path) do
    kind = kind_of(path)

    with {:ok, native} <- native() do
      native.share_file(path, mime(kind), Keyword.get(opts, :title, Path.basename(path)))
    end
  end

  @doc """
  Opens the print dialog with an exported PDF. `{:error, :unsupported}`
  when the app has no native print hook.
  """
  @spec print(Path.t(), keyword()) :: :ok | {:error, term()}
  def print(path, opts \\ []) when is_binary(path) do
    :pdf = kind_of(path)

    with {:ok, native} <- native() do
      native.print_pdf(path, Keyword.get(opts, :title, Path.rootname(Path.basename(path))))
    end
  end

  defp kind_of(path) do
    ext = Path.extname(path)

    Enum.find_value(@extensions, fn {kind, e} -> if e == ext, do: kind end) ||
      raise ArgumentError, "not an export: #{path}"
  end

  defp native do
    case Application.get_env(:humdinger, :file_share) do
      nil -> {:error, :unsupported}
      module -> {:ok, module}
    end
  end
end
