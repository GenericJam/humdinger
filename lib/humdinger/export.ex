defmodule Humdinger.Export do
  @moduledoc """
  Files of a phrase for other apps: `.mid` (`Humdinger.Smf`), MusicXML
  (`Humdinger.MusicXml`) and sheet-music PDF (`Humdinger.Export.Pdf`), and
  handing them to the phone's share sheet or print dialog.

  Each export gets a directory of its own under the export directory
  (`exports/<unique>/Bus stop riff.mid`), so two phrases with the same name
  never overwrite each other's file while a share target is still reading
  it, and the file keeps the phrase's name. Exports older than a day are
  removed when a new one is written. On Android the export directory is
  `cache/exports` next to the app's files directory: the app's
  `FileProvider` (`res/xml/file_provider_paths.xml`, `<cache-path
  path=".">`) can grant other apps access to anything under the cache
  directory.

  Sharing hands the file to `Mob.Share.file/3` (`config :humdinger, :share`,
  default `Mob.Share`). It is fire-and-forget and returns the screen socket;
  setup failures arrive at `self()` as `{:mob_share, :error, reason}`, so
  call `share/3` from the screen process rather than a `start_async` task.
  Printing is PDF-only and calls `MobPrint.pdf/2` (`config :humdinger,
  :print`, default `MobPrint`), which is synchronous.
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
  # A file name component is at most 255 bytes on Android's file systems;
  # leave room under it.
  @max_name_bytes 200

  @doc "The file's bytes. Options: `clef:`, `rhythm:` (MusicXML, PDF), `note_names:` (PDF)."
  @spec render(Phrase.t(), kind(), keyword()) :: binary()
  def render(%Phrase{} = phrase, :mid, _opts), do: Smf.encode(phrase)

  def render(%Phrase{} = phrase, :musicxml, opts),
    do: MusicXml.encode(phrase, Keyword.take(opts, [:clef, :rhythm]))

  def render(%Phrase{} = phrase, :pdf, opts),
    do: Pdf.render(phrase, Keyword.take(opts, [:clef, :rhythm, :note_names]))

  @doc """
  Writes the phrase as `kind` into a new directory of its own under the
  export directory (or `dir:`), and returns the file's path. Options as
  `render/3`.
  """
  @spec write(Phrase.t(), kind(), keyword()) :: {:ok, Path.t()} | {:error, File.posix()}
  def write(%Phrase{} = phrase, kind, opts \\ []) when is_map_key(@extensions, kind) do
    root = Keyword.get_lazy(opts, :dir, &dir/0)
    dir = Path.join(root, unique())
    path = Path.join(dir, file_name(phrase, kind))

    with :ok <- File.mkdir_p(root),
         :ok <- remove_stale(root),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, render(phrase, kind, opts)) do
      {:ok, path}
    end
  end

  defp unique do
    "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  @doc """
  The file name for a phrase: its name without characters file systems or
  share targets choke on, cut on a character boundary to at most
  #{@max_name_bytes} bytes with the extension ("Bus stop riff.mid").
  """
  @spec file_name(Phrase.t(), kind()) :: String.t()
  def file_name(%Phrase{name: name}, kind) do
    ext = Map.fetch!(@extensions, kind)

    base =
      name
      |> String.replace(~r{[/\\:*?"<>|\x00-\x1F\x7F]}u, "")
      |> String.trim()
      |> String.trim_leading(".")
      |> take_bytes(@max_name_bytes - byte_size(ext))
      |> String.trim()

    base = if base == "", do: "phrase", else: base
    base <> ext
  end

  # The longest prefix of whole graphemes within `budget` bytes.
  defp take_bytes(string, budget) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      size = byte_size(g)
      if used + size <= budget, do: {:cont, {[g | acc], used + size}}, else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
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

  # Removes exports (each in its own directory) last written over a day ago.
  defp remove_stale(root) do
    cutoff = System.os_time(:second) - @max_age_s

    with {:ok, entries} <- File.ls(root) do
      for entry <- entries,
          path = Path.join(root, entry),
          {:ok, %File.Stat{mtime: mtime}} <- [File.stat(path, time: :posix)],
          mtime < cutoff,
          do: File.rm_rf(path)

      :ok
    end
  end

  @doc """
  Opens the share sheet with an exported file (`Mob.Share.file/3`).
  Fire-and-forget: returns `socket` unchanged, and setup failures arrive at
  `self()` as `{:mob_share, :error, reason}`. Call from the screen process,
  not inside a `start_async` task.
  """
  @spec share(Mob.Socket.t(), Path.t(), keyword()) :: Mob.Socket.t()
  def share(socket, path, opts \\ []) when is_binary(path) do
    kind = kind_of(path)
    title = Keyword.get(opts, :title, Path.basename(path))
    share_module().file(socket, path, mime: mime(kind), title: title)
  end

  @doc """
  Opens the print dialog with an exported PDF (`MobPrint.pdf/2`).
  """
  @spec print(Path.t(), keyword()) :: :ok | {:error, term()}
  def print(path, opts \\ []) when is_binary(path) do
    :pdf = kind_of(path)
    title = Keyword.get(opts, :title, Path.rootname(Path.basename(path)))
    print_module().pdf(path, title: title)
  end

  defp kind_of(path) do
    ext = Path.extname(path)

    Enum.find_value(@extensions, fn {kind, e} -> if e == ext, do: kind end) ||
      raise ArgumentError, "not an export: #{path}"
  end

  defp share_module, do: Application.get_env(:humdinger, :share, Mob.Share)
  defp print_module, do: Application.get_env(:humdinger, :print, MobPrint)
end
