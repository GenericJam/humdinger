defmodule Humdinger.Phrases.Row do
  @moduledoc """
  A saved phrase as stored in SQLite (table `phrases`). Notes and the trace
  are packed binaries (see `Humdinger.Phrases`); the scale is its root and
  mode, both `nil` for an open phrase.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "phrases" do
    field(:name, :string)
    field(:notes, :binary)
    field(:note_count, :integer)
    field(:trace, :binary)
    field(:duration_ms, :integer)
    field(:tempo_bpm, :integer)
    field(:tempo_detected, :boolean)
    field(:scale_root, :integer)
    field(:scale_mode, :string)
    field(:quantize, :string)
    field(:source, :string)
    field(:created_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
  end

  @fields [
    :name,
    :notes,
    :note_count,
    :trace,
    :duration_ms,
    :tempo_bpm,
    :tempo_detected,
    :scale_root,
    :scale_mode,
    :quantize,
    :source,
    :created_at,
    :updated_at
  ]

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:scale_root, :scale_mode])
    |> validate_number(:tempo_bpm, greater_than: 0)
    |> validate_inclusion(:scale_root, 0..11)
  end
end
