defmodule Humdinger.Repo.Migrations.CreatePhrases do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:phrases) do
      add :name, :text, null: false
      add :notes, :binary, null: false
      add :note_count, :integer, null: false
      add :trace, :binary, null: false
      add :duration_ms, :integer, null: false
      add :tempo_bpm, :integer, null: false
      add :tempo_detected, :boolean, null: false, default: false
      add :scale_root, :integer
      add :scale_mode, :text
      add :quantize, :text, null: false
      add :source, :text, null: false
      add :created_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create_if_not_exists index(:phrases, [:created_at])
  end
end
