defmodule Humdinger.PhraseActions do
  @moduledoc """
  What the phrase screens (Phrases, Review, Import) do with a phrase
  besides editing it: hand an export to another app, print it, name where
  "Play out" goes, and say what went wrong. Screens run `share/3` and
  `print/2` in `Mob.Socket.start_async/3` (they write a file first).
  """

  alias Humdinger.{Export, Phrase}

  @doc """
  Writes the phrase as `kind` (`:mid`, `:musicxml`, `:pdf`; options as
  `Humdinger.Export.render/3`) and opens the share sheet with it.
  """
  @spec share(Phrase.t(), Export.kind(), keyword()) :: :ok | {:error, term()}
  def share(%Phrase{} = phrase, kind, opts \\ []) do
    with {:ok, path} <- Export.write(phrase, kind, opts) do
      Export.share(path, title: phrase.name)
    end
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
