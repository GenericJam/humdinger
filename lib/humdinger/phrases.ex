defmodule Humdinger.Phrases do
  @moduledoc """
  Saved phrases, in the app's SQLite database (`Humdinger.Repo`). Phrases
  stay on the phone.

  Notes are packed 11 bytes each (start and length in ms as 32-bit, MIDI
  note, velocity, unsure flag). The sung-pitch trace is thinned to at most
  one sample per 20 ms (every voiced/unvoiced change kept) and packed 6
  bytes each: time in ms, and the pitch in hundredths of a semitone
  (`0xFFFF` for unvoiced).

  `list/0` returns light phrases: everything but the trace (`trace: []`),
  enough for the Phrases list rows and their mini piano rolls.
  """

  import Ecto.Query

  alias Humdinger.{Phrase, Repo, Scale}
  alias Humdinger.Phrases.Row

  @trace_step_ms 20
  @unvoiced 0xFFFF

  @doc "All saved phrases, newest first, without their traces."
  @spec list() :: [Phrase.t()]
  def list do
    Row
    |> select([r], struct(r, ^(Row.__schema__(:fields) -- [:trace])))
    |> order_by([r], desc: r.created_at, desc: r.id)
    |> Repo.all()
    |> Enum.map(&to_phrase/1)
  end

  @doc "A saved phrase by id, or `nil`."
  @spec get(integer()) :: Phrase.t() | nil
  def get(id) when is_integer(id) do
    case Repo.get(Row, id) do
      nil -> nil
      row -> to_phrase(row)
    end
  end

  @doc """
  Saves a phrase: inserts it when it has no `id` (keeping its `created_at`,
  or now), else updates the saved one. `updated_at` becomes now. Returns the
  phrase as stored (with its id, and the trace thinned).
  """
  @spec save(Phrase.t()) :: {:ok, Phrase.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def save(%Phrase{id: nil} = phrase) do
    now = now()
    attrs = attrs(%{phrase | created_at: phrase.created_at || now, updated_at: now})

    %Row{}
    |> Row.changeset(attrs)
    |> Repo.insert()
    |> stored()
  end

  def save(%Phrase{id: id} = phrase) do
    case Repo.get(Row, id) do
      nil ->
        {:error, :not_found}

      row ->
        attrs = attrs(%{phrase | created_at: row.created_at, updated_at: now()})

        row
        |> Row.changeset(attrs)
        |> Repo.update()
        |> stored()
    end
  end

  @doc "Renames a saved phrase (a blank name becomes \"#{Phrase.default_name()}\")."
  @spec rename(integer(), String.t()) ::
          {:ok, Phrase.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(id, name) when is_integer(id) and is_binary(name) do
    case Repo.get(Row, id) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Row.changeset(%{name: Phrase.rename(%Phrase{}, name).name, updated_at: now()})
        |> Repo.update()
        |> stored()
    end
  end

  @doc "Deletes a saved phrase."
  @spec delete(integer()) :: :ok | {:error, :not_found}
  def delete(id) when is_integer(id) do
    case Repo.delete_all(from(r in Row, where: r.id == ^id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp stored({:ok, row}), do: {:ok, to_phrase(row)}
  defp stored({:error, _} = error), do: error

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp attrs(%Phrase{} = p) do
    {root, mode} =
      case p.scale do
        nil -> {nil, nil}
        %Scale{root: root, mode: mode} -> {root, Atom.to_string(mode)}
      end

    %{
      name: p.name,
      notes: pack_notes(p.notes),
      note_count: length(p.notes),
      trace: pack_trace(p.trace),
      duration_ms: p.duration_ms,
      tempo_bpm: p.tempo_bpm,
      tempo_detected: p.tempo_detected,
      scale_root: root,
      scale_mode: mode,
      quantize: Atom.to_string(p.quantize),
      source: source_to_string(p.source),
      created_at: DateTime.truncate(p.created_at, :second),
      updated_at: p.updated_at
    }
  end

  defp to_phrase(%Row{} = r) do
    %Phrase{
      id: r.id,
      name: r.name,
      notes: unpack_notes(r.notes),
      trace: unpack_trace(r.trace || <<>>),
      duration_ms: r.duration_ms,
      tempo_bpm: r.tempo_bpm,
      tempo_detected: r.tempo_detected,
      scale: scale(r.scale_root, r.scale_mode),
      quantize: atom_in(r.quantize, Phrase.quantizes()),
      source: source_from_string(r.source),
      created_at: r.created_at,
      updated_at: r.updated_at
    }
  end

  defp scale(nil, _mode), do: nil
  defp scale(root, mode), do: Scale.new(root, atom_in(mode, Scale.modes()))

  defp atom_in(string, atoms), do: Enum.find(atoms, &(Atom.to_string(&1) == string))

  defp source_to_string(:hum), do: "hum"
  defp source_to_string({:file, name}), do: "file:" <> name

  defp source_from_string("file:" <> name), do: {:file, name}
  defp source_from_string("hum"), do: :hum

  @doc false
  def pack_notes(notes) do
    for n <- notes, into: <<>> do
      <<n.start_ms::32, n.dur_ms::32, n.midi::8, n.velocity::8, if(n.unsure, do: 1, else: 0)::8>>
    end
  end

  @doc false
  def unpack_notes(bin) do
    for <<start::32, dur::32, midi::8, velocity::8, unsure::8 <- bin>> do
      %{start_ms: start, dur_ms: dur, midi: midi, velocity: velocity, unsure: unsure == 1}
    end
  end

  @doc false
  def pack_trace(trace) do
    trace
    |> thin()
    |> Enum.map(fn
      {t, nil} ->
        <<t::32, @unvoiced::16>>

      {t, pitch} ->
        <<t::32, pitch |> Kernel.*(100) |> round() |> max(0) |> min(@unvoiced - 1)::16>>
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  def unpack_trace(bin) do
    for <<t::32, p::16 <- bin>>, do: {t, if(p == @unvoiced, do: nil, else: p / 100)}
  end

  # Keeps a sample when it is at least @trace_step_ms after the last kept one,
  # or when voicing changes.
  defp thin(trace) do
    trace
    |> Enum.reduce([], fn
      sample, [] ->
        [sample]

      {t, p} = sample, [{last_t, last_p} | _] = acc ->
        if t - last_t >= @trace_step_ms or is_nil(p) != is_nil(last_p),
          do: [sample | acc],
          else: acc
    end)
    |> Enum.reverse()
  end
end
