defmodule Humdinger.FMutate.Supervisor do
  @moduledoc """
  Runs the FMutate link (`Humdinger.FMutate`) and the pairing service
  (`Humdinger.FMutate.Pairing`). Started from `App.on_start`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Humdinger.FMutate, Humdinger.FMutate.Pairing], strategy: :one_for_one)
  end
end
