defmodule Humdinger.PhraseDraft do
  @moduledoc """
  Unsaved phrases kept safe outside the phrase database: the Review screen
  (`Humdinger.PhraseScreen`) writes its phrase here while it has unsaved
  work, so nothing depends on the database still running when the screen is
  torn down (system Back, the app stopping: Mob gives a screen no say in
  either, and the order the app's processes stop in isn't the app's).

  Drafts live in `Mob.State` (a `:dets` file of its own), one per open
  Review screen under `{:phrase_draft, key}`. The screen deletes its draft
  once the phrase is saved or deliberately dropped (Discard, Hum again).
  `recover/0`, run at app start once the database is up, saves whatever
  drafts are left over into the Phrases list.

  Every call catches a store that has stopped (an exit) and answers
  `{:error, reason}` instead, so it is safe from `terminate/2`.
  """

  require Logger

  alias Humdinger.{Phrase, Phrases}

  @type key :: {integer(), pos_integer()}

  @doc "A key for a new draft, unique across app launches."
  @spec new_key() :: key()
  def new_key, do: {System.os_time(:microsecond), System.unique_integer([:positive])}

  @doc "Keeps `phrase` as the draft under `key`."
  @spec put(key(), Phrase.t()) :: :ok | {:error, term()}
  def put(key, %Phrase{} = phrase),
    do: safely(fn -> Mob.State.put({:phrase_draft, key}, phrase) end)

  @doc "Forgets the draft under `key`."
  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key), do: safely(fn -> Mob.State.delete({:phrase_draft, key}) end)

  @doc "Every draft, as `{key, phrase}`."
  @spec all() :: [{key(), Phrase.t()}]
  def all do
    case safely(fn -> Mob.State.match({:phrase_draft, :_}) end) do
      {:error, _} -> []
      entries -> for {{:phrase_draft, key}, %Phrase{} = p} <- entries, do: {key, p}
    end
  end

  @doc """
  Saves `phrase` with `Humdinger.Phrases.save/1`, catching a database that
  isn't running. A draft of a saved phrase that has since been deleted is
  saved as a new one.
  """
  @spec save(Phrase.t()) :: {:ok, Phrase.t()} | {:error, term()}
  def save(%Phrase{} = phrase) do
    case safely(fn -> Phrases.save(phrase) end) do
      {:error, :not_found} -> safely(fn -> Phrases.save(%{phrase | id: nil}) end)
      result -> result
    end
  end

  @doc """
  Saves every leftover draft into the Phrases list and deletes it. A draft
  the database refuses (an invalid phrase) is logged and dropped; one that
  couldn't be tried (the database isn't running) is kept for next time.
  Returns how many were saved.
  """
  @spec recover() :: non_neg_integer()
  def recover do
    Enum.count(all(), fn {key, phrase} ->
      case save(phrase) do
        {:ok, _} ->
          delete(key)
          true

        {:error, {:unavailable, _}} ->
          false

        {:error, reason} ->
          Logger.warning(
            "Humdinger.PhraseDraft: dropped a draft the database refused: #{inspect(reason)}"
          )

          delete(key)
          false
      end
    end)
  end

  # A store or Repo that isn't running exits (a GenServer call) or raises
  # (Ecto can't look the Repo up); either is {:error, {:unavailable, _}}.
  defp safely(fun) do
    fun.()
  rescue
    error in [RuntimeError, ArgumentError, DBConnection.ConnectionError] ->
      {:error, {:unavailable, error.__struct__}}
  catch
    :exit, reason -> {:error, {:unavailable, exit_reason(reason)}}
  end

  defp exit_reason({reason, _call}), do: reason
  defp exit_reason(reason), do: reason
end
