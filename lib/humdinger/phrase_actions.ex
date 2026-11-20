defmodule Humdinger.PhraseActions do
  @moduledoc """
  What the phrase screens (Phrases, Review, Import) do with a phrase
  besides editing it: hand an export to another app, print it, name where
  "Play out" goes, and say what went wrong.

  Screens write share files in `Mob.Socket.start_async/3` (`write_share/3`)
  and open the share sheet from `handle_async/3` (`share/3`), so setup
  failures from `Mob.Share.file/3` arrive at the screen process as
  `{:mob_share, :error, reason}`. `print/2` writes the PDF and calls
  `MobPrint.pdf/2` synchronously inside `start_async/3`.
  """

  alias Humdinger.{Export, Phrase}

  @doc """
  Writes the phrase as `kind` (`:mid`, `:musicxml`, `:pdf`; options as
  `Humdinger.Export.render/3`) and returns `{:ok, path, title}` for `share/3`.
  """
  @spec write_share(Phrase.t(), Export.kind(), keyword()) ::
          {:ok, Path.t(), String.t()} | {:error, File.posix()}
  def write_share(%Phrase{} = phrase, kind, opts \\ []) do
    with {:ok, path} <- Export.write(phrase, kind, opts) do
      {:ok, path, phrase.name}
    end
  end

  @doc """
  Opens the share sheet for a written export from the screen process.
  """
  @spec share(Mob.Socket.t(), Path.t(), String.t()) :: Mob.Socket.t()
  def share(socket, path, title) when is_binary(path) and is_binary(title) do
    Export.share(socket, path, title: title)
  end

  @doc "Writes the phrase's sheet music as a PDF and opens the print dialog."
  @spec print(Phrase.t(), keyword()) :: :ok | {:error, term()}
  def print(%Phrase{} = phrase, opts \\ []) do
    with {:ok, path} <- Export.write(phrase, :pdf, opts) do
      Export.print(path, title: phrase.name)
    end
  end

  @doc "The notice for a failed share or print (`nil` for `:ok`)."
  @spec error_text(:ok | {:error, term()} | {:exit, term()}) :: String.t() | nil
  def error_text(:ok), do: nil
  def error_text({:error, :unsupported}), do: "This phone can't hand files to other apps."
  def error_text({:error, :no_app}), do: "No app on this phone can take it."
  def error_text({:error, :not_found}), do: "The exported file went missing. Try again."
  def error_text({:error, reason}) when is_atom(reason), do: "Couldn't hand it over (#{reason})."
  def error_text(_other), do: "Couldn't hand it over."

  @doc """
  The "Play out" button's label: "Play out to <name>" for the first
  destination that is on and reachable (FMutate, the Humdinger port, USB,
  Bluetooth: `Humdinger.Output.destinations/0`), else "Play out".
  """
  @spec play_label([map()]) :: String.t()
  def play_label(destinations) do
    case Enum.find(destinations, &(&1.enabled and &1.available)) do
      %{name: name} -> "Play out to " <> name
      nil -> "Play out"
    end
  end

  @doc """
  The output's destinations (`config :humdinger, :output`, default
  `Humdinger.Output`); `[]` when it isn't running.
  """
  @spec destinations() :: [map()]
  def destinations do
    Application.get_env(:humdinger, :output, Humdinger.Output).destinations()
  catch
    :exit, _ -> []
  end
end
