defmodule Humdinger.Test.Database do
  @moduledoc """
  A fresh in-memory database for a test module: `start!/0` from
  `setup_all` starts `Humdinger.Repo` (test config: `:memory:`) and runs the
  migrations. The migration files are compiled once per test run, so
  modules sharing them don't redefine the migration modules.
  """

  alias Humdinger.Repo

  def start! do
    ExUnit.Callbacks.start_supervised!(Repo)
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)
    :ok
  end

  defp migrations do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        list =
          :humdinger
          |> Application.app_dir("priv/repo/migrations")
          |> Path.join("*.exs")
          |> Path.wildcard()
          |> Enum.sort()
          |> Enum.map(fn file ->
            [{module, _} | _] = Code.compile_file(file)
            {file |> Path.basename() |> Integer.parse() |> elem(0), module}
          end)

        :persistent_term.put(__MODULE__, list)
        list

      list ->
        list
    end
  end
end
