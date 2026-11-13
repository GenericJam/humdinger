defmodule Humdinger.Phrase do
  @moduledoc """
  A recorded phrase: the notes as sung, the sung-pitch trace, a tempo and a
  quantize grid. The notes are kept as sung; the grid is a view over them
  (`quantized_notes/1`, `grid_notes/3`), so changing the tempo or the grid
  never loses timing. The Review screen's piano roll edits go through
  `move_note/3` and `resize_note/4`.

  `scale` is the scale the phrase was sung in, or `nil` for a phrase hummed
  in Live's "Open + bend" mode; the boards show that as "open". Sheet music
  of an open phrase has no key signature but still spells black keys the way
  its detected key would (`spelling_scale/1`).

  Times are ms. A phrase starts on its first grid line: `from_take/2` drops
  the take's leading silence.
  """

  alias Humdinger.{Scale, Take, Tempo}

  @default_name "New phrase"
  @default_bpm 120
  @bpm_range 40..240
  @quantizes [:q4, :q8, :q16, :triplet, :off]
  @min_free_ms 60

  defstruct id: nil,
            name: @default_name,
            notes: [],
            trace: [],
            duration_ms: 0,
            tempo_bpm: @default_bpm,
            tempo_detected: false,
            scale: nil,
            quantize: :q8,
            source: :hum,
            created_at: nil,
            updated_at: nil

  @type quantize :: :q4 | :q8 | :q16 | :triplet | :off
  @type note :: Take.note()
  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          notes: [note()],
          trace: [{non_neg_integer(), float() | nil}],
          duration_ms: non_neg_integer(),
          tempo_bpm: pos_integer(),
          tempo_detected: boolean(),
          scale: Scale.t() | nil,
          quantize: quantize(),
          source: :hum | {:file, String.t()},
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc "A note on a grid: `start` and `stop` in grid steps, `index` into `phrase.notes`."
  @type grid_note :: %{
          index: non_neg_integer(),
          start: non_neg_integer(),
          stop: pos_integer(),
          midi: 0..127,
          velocity: 1..127,
          unsure: boolean()
        }

  @doc "The name a new phrase gets."
  def default_name, do: @default_name

  @doc "The quantize settings, coarsest first."
  def quantizes, do: @quantizes

  @doc """
  A phrase from a `Humdinger.Take`.

  The tempo is the take's when it has one (a metronome), else detected from
  the note onsets (`tempo_detected: true`), else #{@default_bpm} bpm for a
  take with too few notes. The take's leading silence is dropped so the
  first note starts on the nearest grid line.

  Options: `name` (default "#{@default_name}"), `quantize` (default `:q8`),
  `now` (a `DateTime`, for `created_at` when the take has no
  `recorded_at`).
  """
  @spec from_take(Take.t(), keyword()) :: t()
  def from_take(%Take{} = take, opts \\ []) do
    notes = Enum.sort_by(take.notes, & &1.start_ms)
    onsets = Enum.map(notes, & &1.start_ms)

    {bpm, detected, offset} = timing(take.tempo_bpm, onsets)

    notes = Enum.flat_map(notes, &shift_note(&1, offset))

    trace =
      for {t, pitch} <- take.trace, t >= offset, do: {round(t - offset), pitch}

    now = DateTime.truncate(take.recorded_at || opts[:now] || DateTime.utc_now(), :second)

    %__MODULE__{
      name: opts[:name] || @default_name,
      notes: notes,
      trace: trace,
      duration_ms: max(round(take.duration_ms - offset), notes_end(notes)),
      tempo_bpm: bpm,
      tempo_detected: detected,
      scale: take.scale,
      quantize: opts[:quantize] || :q8,
      source: take.source,
      created_at: now,
      updated_at: now
    }
  end

  # {bpm, detected?, ms of leading silence to drop}
  defp timing(bpm, onsets) when is_number(bpm) do
    bpm = clamp_bpm(bpm)
    {bpm, false, whole_beats_before(onsets, bpm)}
  end

  defp timing(nil, onsets) do
    case Tempo.detect(onsets) do
      %{bpm: bpm, phase_ms: phase} -> {bpm, true, grid_line_near(onsets, bpm, phase)}
      nil -> {@default_bpm, false, List.first(onsets, 0)}
    end
  end

  # With a known tempo the take's time 0 is on a beat: drop whole beats.
  defp whole_beats_before([], _bpm), do: 0

  defp whole_beats_before([first | _], bpm) do
    beat = 60_000 / bpm
    Float.floor(first / beat) * beat
  end

  # The detected eighth-note grid line nearest the first onset.
  defp grid_line_near([first | _], bpm, phase) do
    eighth = Tempo.eighth_ms(bpm)
    max(phase + Float.round((first - phase) / eighth) * eighth, 0.0)
  end

  defp shift_note(note, offset) do
    start = note.start_ms - offset
    stop = start + note.dur_ms
    start = max(round(start), 0)
    stop = round(stop)

    if stop > start, do: [%{note | start_ms: start, dur_ms: stop - start}], else: []
  end

  @doc """
  The Review header line: "8 notes · 2 bars at 96 · D Dorian" ("open" for a
  phrase without a scale).
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = p) do
    Enum.join(
      [
        count(length(p.notes), "note"),
        "#{count(bars(p), "bar")} at #{p.tempo_bpm}",
        scale_label(p)
      ],
      " · "
    )
  end

  @doc """
  A Phrases list row: "8 notes · 2 bars · D Dorian · today". The day is
  "today", "yesterday", a weekday ("Tue") within the past week, else a date
  ("3 Mar", with the year when it isn't this year's).

  `now` is a `DateTime`; `utc_offset:` (seconds) is the phone's offset from
  UTC for deciding what "today" is, default the system's.
  """
  @spec list_summary(t(), DateTime.t(), keyword()) :: String.t()
  def list_summary(%__MODULE__{} = p, %DateTime{} = now, opts \\ []) do
    offset = Keyword.get_lazy(opts, :utc_offset, &local_utc_offset/0)

    Enum.join(
      [
        count(length(p.notes), "note"),
        count(bars(p), "bar"),
        scale_label(p),
        relative_day(p.created_at || now, now, offset)
      ],
      " · "
    )
  end

  defp count(1, word), do: "1 " <> word
  defp count(n, word), do: "#{n} #{word}s"

  defp scale_label(%__MODULE__{scale: nil}), do: "open"
  defp scale_label(%__MODULE__{scale: scale}), do: Scale.name(scale)

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp relative_day(at, now, offset) do
    day = at |> DateTime.add(offset, :second) |> DateTime.to_date()
    today = now |> DateTime.add(offset, :second) |> DateTime.to_date()

    case Date.diff(today, day) do
      0 -> "today"
      1 -> "yesterday"
      d when d in 2..6 -> Enum.at(@weekdays, Date.day_of_week(day) - 1)
      _ when day.year == today.year -> "#{day.day} #{Enum.at(@months, day.month - 1)}"
      _ -> "#{day.day} #{Enum.at(@months, day.month - 1)} #{day.year}"
    end
  end

  defp local_utc_offset do
    utc = :calendar.universal_time()
    local = :calendar.universal_time_to_local_time(utc)

    :calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc)
  end

  @doc """
  How many 4/4 bars the phrase fills, at least 1: up to the end of its last
  note on the phrase's grid.
  """
  @spec bars(t()) :: pos_integer()
  def bars(%__MODULE__{notes: []}), do: 1

  def bars(%__MODULE__{quantize: :off} = p) do
    beats(notes_end(p.notes) / beat_ms(p.tempo_bpm))
  end

  def bars(%__MODULE__{} = p) do
    stop = p.notes |> grid_notes(p.tempo_bpm, p.quantize) |> List.last() |> Map.fetch!(:stop)
    beats(stop / steps_per_beat(p.quantize))
  end

  defp beats(beats), do: max(1, ceil(beats / 4 - 1.0e-6))

  @doc "A quarter note at `bpm`, in ms."
  def beat_ms(bpm), do: 60_000 / bpm

  @doc "Grid steps per quarter note: 1, 2, 4, or 3 for eighth-note triplets."
  def steps_per_beat(:q4), do: 1
  def steps_per_beat(:q8), do: 2
  def steps_per_beat(:q16), do: 4
  def steps_per_beat(:triplet), do: 3

  @doc "One grid step at `bpm`, in ms."
  def step_ms(bpm, quantize), do: beat_ms(bpm) / steps_per_beat(quantize)

  @doc "The phrase's notes on its grid, in ms (see `quantize_notes/3`)."
  @spec quantized_notes(t()) :: [note()]
  def quantized_notes(%__MODULE__{} = p), do: quantize_notes(p.notes, p.tempo_bpm, p.quantize)

  @doc """
  Notes snapped to a grid at `bpm`: `:q4` quarters, `:q8` eighths, `:q16`
  sixteenths, `:triplet` eighth-note triplets; `:off` keeps them as sung.

  The result is a clean monophonic line: every note at least one step long
  (with `:off`, at least 1 ms), none overlapping the next (a note is cut
  where the next starts). Notes that land on the same step keep the longer
  one, as sung.
  """
  @spec quantize_notes([note()], number(), quantize()) :: [note()]
  def quantize_notes(notes, _bpm, :off) do
    notes
    |> Enum.sort_by(& &1.start_ms)
    |> Enum.chunk_by(& &1.start_ms)
    |> Enum.map(fn same_start -> Enum.max_by(same_start, & &1.dur_ms) end)
    |> trim_overlaps()
  end

  def quantize_notes(notes, bpm, quantize) do
    step = step_ms(bpm, quantize)

    for g <- grid_notes(notes, bpm, quantize) do
      start = round(g.start * step)

      %{
        start_ms: start,
        dur_ms: round(g.stop * step) - start,
        midi: g.midi,
        velocity: g.velocity,
        unsure: g.unsure
      }
    end
  end

  defp trim_overlaps(notes) do
    notes
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [n, next] -> [%{n | dur_ms: min(n.dur_ms, next.start_ms - n.start_ms)}]
      [n] -> [n]
    end)
  end

  @doc """
  Notes on a grid (any setting but `:off`) in whole grid steps, with their
  index into `notes`. The rules are those of `quantize_notes/3`.
  """
  @spec grid_notes([note()], number(), :q4 | :q8 | :q16 | :triplet) :: [grid_note()]
  def grid_notes(notes, bpm, quantize) do
    step = step_ms(bpm, quantize)

    notes
    |> Enum.with_index()
    |> Enum.sort_by(fn {n, i} -> {n.start_ms, i} end)
    |> Enum.map(fn {n, i} ->
      start = round_half_up(n.start_ms / step)
      stop = max(round_half_up((n.start_ms + n.dur_ms) / step), start + 1)

      {n.dur_ms,
       %{index: i, start: start, stop: stop, midi: n.midi, velocity: n.velocity, unsure: n.unsure}}
    end)
    |> Enum.chunk_by(fn {_dur, g} -> g.start end)
    |> Enum.map(fn same_step ->
      {_dur, g} = Enum.max_by(same_step, fn {dur, g} -> {dur, -g.index} end)
      g
    end)
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [g, next] -> %{g | stop: min(g.stop, next.start)}
      [g] -> g
    end)
  end

  defp round_half_up(x), do: trunc(Float.floor(x + 0.5))

  @doc """
  The scale to spell notes in: the phrase's own, or for an open (or
  chromatic) phrase the key its notes suggest (`Scale.detect/1`). `nil` for
  an open phrase without notes.
  """
  @spec spelling_scale(t()) :: Scale.t() | nil
  def spelling_scale(%__MODULE__{scale: %Scale{mode: mode} = scale}) when mode != :chromatic,
    do: scale

  def spelling_scale(%__MODULE__{notes: notes}),
    do: notes |> Enum.map(&{&1.midi, &1.dur_ms}) |> Scale.detect()

  # Edits ------------------------------------------------------------------

  @doc """
  Moves note `i` up (positive) or down by semitones, within 0..127. An edited
  note is no longer unsure.
  """
  @spec move_note(t(), non_neg_integer(), integer()) :: t()
  def move_note(%__MODULE__{} = p, i, semitones) when is_integer(semitones) do
    update_note(p, i, fn n -> %{n | midi: (n.midi + semitones) |> max(0) |> min(127)} end)
  end

  @doc """
  Moves the `:start` or `:end` of note `i` to `ms`. With a grid the new edge
  snaps to it and the note stays at least one step long; with `:off` at
  least #{@min_free_ms} ms. The edge stops at the neighbouring notes. An edge
  that can't move (no room) leaves the note as it was.
  """
  @spec resize_note(t(), non_neg_integer(), :start | :end, number()) :: t()
  def resize_note(%__MODULE__{} = p, i, edge, ms) when edge in [:start, :end] and is_number(ms) do
    note = Enum.fetch!(p.notes, i)
    {snapped, min_len} = snap_edge(p, ms)
    {lo, hi} = edge_range(p, i, note, edge, min_len)

    cond do
      hi != :infinity and lo > hi -> p
      edge == :start -> put_edges(p, i, clamp(snapped, lo, hi), note_end(note))
      true -> put_edges(p, i, note.start_ms, clamp(snapped, lo, hi))
    end
  end

  defp snap_edge(%__MODULE__{quantize: :off}, ms), do: {round(ms), @min_free_ms}

  defp snap_edge(%__MODULE__{} = p, ms) do
    step = step_ms(p.tempo_bpm, p.quantize)
    {round(Float.round(ms / step) * step), round(step)}
  end

  defp edge_range(p, i, note, :start, min_len) do
    prev_end = if i > 0, do: note_end(Enum.at(p.notes, i - 1)), else: 0
    {prev_end, note_end(note) - min_len}
  end

  defp edge_range(p, i, note, :end, min_len) do
    case Enum.at(p.notes, i + 1) do
      nil -> {note.start_ms + min_len, :infinity}
      next -> {note.start_ms + min_len, next.start_ms}
    end
  end

  defp clamp(x, lo, :infinity), do: max(x, lo)
  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)

  defp put_edges(p, i, start, stop) do
    update_note(p, i, fn n -> %{n | start_ms: start, dur_ms: stop - start} end)
  end

  defp update_note(p, i, fun) do
    note = Enum.fetch!(p.notes, i)
    notes = List.replace_at(p.notes, i, %{fun.(note) | unsure: false})
    %{p | notes: notes, duration_ms: max(p.duration_ms, notes_end(notes))}
  end

  @doc "Sets the tempo (whole bpm, #{@bpm_range.first}..#{@bpm_range.last}); it is no longer the detected one."
  @spec set_tempo(t(), number()) :: t()
  def set_tempo(%__MODULE__{} = p, bpm) when is_number(bpm),
    do: %{p | tempo_bpm: clamp_bpm(bpm), tempo_detected: false}

  defp clamp_bpm(bpm), do: bpm |> round() |> max(@bpm_range.first) |> min(@bpm_range.last)

  @doc "Sets the quantize grid."
  @spec set_quantize(t(), quantize()) :: t()
  def set_quantize(%__MODULE__{} = p, quantize) when quantize in @quantizes,
    do: %{p | quantize: quantize}

  @doc "Renames the phrase; a blank name becomes \"#{@default_name}\"."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = p, name) when is_binary(name) do
    case String.trim(name) do
      "" -> %{p | name: @default_name}
      trimmed -> %{p | name: trimmed}
    end
  end

  defp notes_end([]), do: 0
  defp notes_end(notes), do: notes |> Enum.map(&note_end/1) |> Enum.max()

  defp note_end(n), do: n.start_ms + n.dur_ms
end
