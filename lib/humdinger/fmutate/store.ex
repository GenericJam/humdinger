defmodule Humdinger.FMutate.Store do
  @moduledoc """
  Keeps the one FMutate pairing in the platform's secure store
  (`MobSecureStore`): EncryptedSharedPreferences under an Android Keystore
  master key on Android, the Keychain (this device only) on iOS, a 0600 file
  on the host.

  The record holds the per-app cookie and Humdinger's TLS private key, which
  together let a node into FMutate with full trust; the Keystore keeps them
  out of backups and other devices. On a phone whose build lacks the plugin's
  NIF the store fails closed (`{:error, :secure_store_unavailable}`) rather
  than writing them to a plain file: rebuild with `mix mob.deploy --native`.

  A store is `{module, opts}`; `Humdinger.FMutate` takes one as `:store` so
  tests can use their own key.
  """

  alias Humdinger.FMutate.Record

  @callback load(keyword()) :: {:ok, Record.t()} | :none | {:error, term()}
  @callback save(Record.t(), keyword()) :: :ok | {:error, term()}
  @callback delete(keyword()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  @key "humdinger.fmutate.pairing"

  @doc """
  The stored pairing, `:none`, or `{:error, reason}` when the store failed or
  the stored value is unreadable (`:corrupt`).
  """
  @impl true
  def load(opts \\ []) do
    case MobSecureStore.get(key(opts)) do
      {:ok, json} -> Record.from_json(json)
      :error -> :none
      {:error, _} = error -> error
    end
  end

  @doc "Stores the pairing, replacing any other."
  @impl true
  def save(%Record{} = record, opts \\ []),
    do: MobSecureStore.put(key(opts), Record.to_json(record))

  @doc "Forgets the pairing."
  @impl true
  def delete(opts \\ []), do: MobSecureStore.delete(key(opts))

  defp key(opts), do: Keyword.get(opts, :key, @key)
end
