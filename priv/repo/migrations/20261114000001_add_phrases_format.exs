defmodule Humdinger.Repo.Migrations.AddPhrasesFormat do
  use Ecto.Migration

  # The version of a row's stored representation (packed notes and trace,
  # enum strings): rows written before it existed are format 1.
  def change do
    alter table(:phrases) do
      add :format, :integer, null: false, default: 1
    end
  end
end
