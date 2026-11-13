defmodule Humdinger.Notation do
  @moduledoc """
  Sheet music for a phrase: `layout/2` turns its notes into 4/4 measures of
  notes and rests, spelled and grouped the way an engraver would, for the
  staff view (`Humdinger.Views`), the PDF and MusicXML.

  Rhythm comes from the phrase's notes on a grid: "As sung" uses the
  phrase's quantize setting (sixteenths when it is off), "Simpler" quarter
  notes. Durations are split into notatable values with ties by the usual
  4/4 rules:

  - a whole or dotted half only from the downbeat;
  - nothing else crosses the middle of the bar (beat 3);
  - a note starting off the beat ends at or before the next beat;
  - otherwise the longest value that fits (dotted values included for notes,
    not for rests);
  - with eighth-note triplets, beats that aren't one whole value are filled
    with triplet eighths and quarters.

  Eighths and sixteenths in the same beat are beamed. Notes are spelled from
  the key (`Humdinger.Scale.key_fifths/1`); other black keys use sharps, or
  flats in a flat key (an open phrase uses the key its notes suggest, but no
  key signature). An accidental is printed when a note's alteration differs
  from the key signature or from an earlier note on the same line or space in
  the bar; a note tied over the barline doesn't repeat it.

  Internally times are ticks, 12 to the quarter note.
  """

  alias Humdinger.{Phrase, Scale}

  @tpb 12
  @bar 48
  @steps ~w(C D E F G A B)
  @natural_pc %{"C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11}
  @sharp_order ~w(F C G D A E B)
  @flat_order ~w(B E A D G C F)
  # Middle staff line as a diatonic number (octave · 7 + step): B4 and D3.
  @middle_line %{treble: 4 * 7 + 6, bass: 3 * 7 + 1}

  @note_values [
                 {48, :whole, 0},
                 {36, :half, 1},
                 {24, :half, 0},
                 {18, :quarter, 1},
                 {12, :quarter, 0}
               ] ++
                 [{9, :eighth, 1}, {6, :eighth, 0}, {3, :sixteenth, 0}]
  @triplet_whole [{48, :whole, 0}, {36, :half, 1}, {24, :half, 0}, {12, :quarter, 0}]
  @triplet_parts [{8, :quarter, 0}, {4, :eighth, 0}]

  @type item :: %{
          kind: :note | :rest,
          beat: float(),
          type: :whole | :half | :quarter | :eighth | :sixteenth,
          dots: 0 | 1,
          tuplet: nil | {3, 2},
          midi: integer() | nil,
          step: String.t() | nil,
          octave: integer() | nil,
          alter: -1 | 0 | 1 | nil,
          accidental: nil | :sharp | :flat | :natural,
          staff_pos: integer() | nil,
          tie_to_next: boolean(),
          beam: nil | :begin | :continue | :end,
          note_index: integer() | nil
        }
  @type t :: %{
          clef: :treble | :bass,
          key_fifths: integer(),
          time: {4, 4},
          measures: [%{index: non_neg_integer(), items: [item()]}]
        }

  @doc """
  The phrase as measures. Options: `clef: :auto | :treble | :bass` (`:auto`
  picks the clef needing fewer ledger lines, by the notes' median on a tie),
  `rhythm: :as_sung | :simpler`.
  """
  @spec layout(Phrase.t(), keyword()) :: t()
  def layout(%Phrase{} = phrase, opts \\ []) do
    grid = grid(phrase.quantize, Keyword.get(opts, :rhythm, :as_sung))
    ticks = div(@tpb, Phrase.steps_per_beat(grid))

    notes =
      for g <- Phrase.grid_notes(phrase.notes, phrase.tempo_bpm, grid),
          do: %{start: g.start * ticks, stop: g.stop * ticks, midi: g.midi, index: g.index}

    key_fifths = key_fifths(phrase.scale)
    spell = speller(spelling_fifths(phrase), key_fifths)
    clef = clef(Keyword.get(opts, :clef, :auto), Enum.map(notes, & &1.midi), spell)
    last = notes |> Enum.map(& &1.stop) |> Enum.max(fn -> 0 end)
    count = max(1, div(last + @bar - 1, @bar))

    measures =
      for m <- 0..(count - 1) do
        items =
          notes
          |> segments(m * @bar)
          |> Enum.flat_map(&split(&1, grid))
          |> beam()
          |> Enum.map_reduce(key_state(key_fifths), &spell_item(&1, &2, spell, clef))
          |> elem(0)

        %{index: m, items: items}
      end

    %{clef: clef, key_fifths: key_fifths, time: {4, 4}, measures: measures}
  end

  defp grid(_quantize, :simpler), do: :q4
  defp grid(:off, :as_sung), do: :q16
  defp grid(quantize, :as_sung), do: quantize

  defp key_fifths(nil), do: 0
  defp key_fifths(%Scale{} = scale), do: Scale.key_fifths(scale)

  defp spelling_fifths(phrase) do
    case Phrase.spelling_scale(phrase) do
      nil -> 0
      scale -> Scale.key_fifths(scale)
    end
  end

  # Measure segments --------------------------------------------------------

  # The notes and gaps of the measure starting at `from`, as
  # {kind, start, stop, note, tied_in, tied_out} with times relative to the
  # measure.
  defp segments(notes, from) do
    to = from + @bar

    {segs, cursor} =
      notes
      |> Enum.filter(&(&1.start < to and &1.stop > from))
      |> Enum.reduce({[], from}, fn n, {acc, cursor} ->
        start = max(n.start, from)
        stop = min(n.stop, to)
        acc = if start > cursor, do: [rest(cursor - from, start - from) | acc], else: acc

        seg = %{
          kind: :note,
          a: start - from,
          b: stop - from,
          note: n,
          tied_in: n.start < from,
          tied_out: n.stop > to
        }

        {[seg | acc], stop}
      end)

    segs = if cursor < to, do: [rest(cursor - from, @bar) | segs], else: segs
    Enum.reverse(segs)
  end

  defp rest(a, b), do: %{kind: :rest, a: a, b: b, note: nil, tied_in: false, tied_out: false}

  # Splitting into notatable values -------------------------------------------

  defp split(seg, grid) do
    parts = pieces(seg.a, seg.b, seg.kind, grid)
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn {{a, len, type, dots, tuplet}, i} ->
      %{
        kind: seg.kind,
        a: a,
        len: len,
        type: type,
        dots: dots,
        tuplet: tuplet,
        note: seg.note,
        tied_in: seg.kind == :note and (i > 0 or seg.tied_in),
        tie_to_next: seg.kind == :note and (i < last or seg.tied_out)
      }
    end)
  end

  defp pieces(a, b, _kind, _grid) when a >= b, do: []

  defp pieces(a, b, kind, :triplet) do
    {len, type, dots, tuplet} =
      case Enum.find(values(kind, @triplet_whole), fn {len, _, _} -> fits?(a, len, b) end) do
        {len, type, dots} ->
          {len, type, dots, nil}

        nil ->
          {len, type, dots} =
            Enum.find(@triplet_parts, fn {len, _, _} -> a + len <= min(b, next_beat(a)) end)

          {len, type, dots, {3, 2}}
      end

    [{a, len, type, dots, tuplet} | pieces(a + len, b, kind, :triplet)]
  end

  defp pieces(a, b, kind, grid) do
    {len, type, dots} =
      Enum.find(values(kind, @note_values), fn {len, _, _} -> fits?(a, len, b) end)

    [{a, len, type, dots, nil} | pieces(a + len, b, kind, grid)]
  end

  # Rests aren't dotted.
  defp values(:note, values), do: values
  defp values(:rest, values), do: Enum.filter(values, fn {_len, _type, dots} -> dots == 0 end)

  defp fits?(a, len, b) do
    stop = a + len

    cond do
      stop > b -> false
      len >= 36 -> a == 0
      a < 24 and stop > 24 -> false
      rem(a, @tpb) != 0 -> stop <= next_beat(a)
      true -> true
    end
  end

  defp next_beat(a), do: (div(a, @tpb) + 1) * @tpb

  # Beams: runs of two or more eighths/sixteenths within one beat.
  defp beam(items) do
    items
    |> Enum.chunk_by(fn i -> {div(i.a, @tpb), beamable?(i)} end)
    |> Enum.flat_map(fn
      [first, _ | _] = run ->
        if beamable?(first), do: mark_beams(run), else: Enum.map(run, &Map.put(&1, :beam, nil))

      run ->
        Enum.map(run, &Map.put(&1, :beam, nil))
    end)
  end

  defp beamable?(i), do: i.kind == :note and i.type in [:eighth, :sixteenth]

  defp mark_beams(run) do
    last = length(run) - 1

    run
    |> Enum.with_index()
    |> Enum.map(fn
      {i, 0} -> Map.put(i, :beam, :begin)
      {i, ^last} -> Map.put(i, :beam, :end)
      {i, _} -> Map.put(i, :beam, :continue)
    end)
  end

  # Spelling and accidentals -----------------------------------------------

  defp key_state(fifths) do
    Map.new(@steps, &{&1, key_alter(&1, fifths)})
  end

  defp key_alter(step, fifths) when fifths > 0,
    do: if(step in Enum.take(@sharp_order, fifths), do: 1, else: 0)

  defp key_alter(step, fifths) when fifths < 0,
    do: if(step in Enum.take(@flat_order, -fifths), do: -1, else: 0)

  defp key_alter(_step, 0), do: 0

  # pitch class → {step, alter}: the key's own notes as the key spells them,
  # the rest as sharps (or flats in a flat key).
  defp speller(spelling_fifths, key_fifths) do
    flats? = if key_fifths == 0, do: spelling_fifths < 0, else: key_fifths < 0

    chromatic =
      for pc <- 0..11, into: %{} do
        case Enum.find(@steps, &(@natural_pc[&1] == pc)) do
          nil when flats? -> {pc, {Enum.find(@steps, &(@natural_pc[&1] == pc + 1)), -1}}
          nil -> {pc, {Enum.find(@steps, &(@natural_pc[&1] == pc - 1)), 1}}
          step -> {pc, {step, 0}}
        end
      end

    in_key =
      for step <- @steps, into: %{} do
        alter = key_alter(step, spelling_fifths)
        {Integer.mod(@natural_pc[step] + alter, 12), {step, alter}}
      end

    Map.merge(chromatic, in_key)
  end

  defp spell_item(%{kind: :rest} = i, state, _spell, _clef) do
    {item(i, %{
       midi: nil,
       step: nil,
       octave: nil,
       alter: nil,
       accidental: nil,
       staff_pos: nil,
       note_index: nil
     }), state}
  end

  defp spell_item(%{kind: :note} = i, state, spell, clef) do
    midi = i.note.midi
    {step, alter} = Map.fetch!(spell, Integer.mod(midi, 12))
    octave = Integer.floor_div(midi - alter, 12) - 1
    line = {step, octave}
    current = Map.get(state, line, Map.fetch!(state, step))

    accidental =
      cond do
        i.tied_in or alter == current -> nil
        alter == 1 -> :sharp
        alter == -1 -> :flat
        true -> :natural
      end

    state = if i.tied_in, do: state, else: Map.put(state, line, alter)

    fields = %{
      midi: midi,
      step: step,
      octave: octave,
      alter: alter,
      accidental: accidental,
      staff_pos: staff_pos(step, octave, clef),
      note_index: i.note.index
    }

    {item(i, fields), state}
  end

  defp item(i, fields) do
    Map.merge(
      %{
        kind: i.kind,
        beat: i.a / @tpb,
        type: i.type,
        dots: i.dots,
        tuplet: i.tuplet,
        tie_to_next: i.tie_to_next,
        beam: i.beam
      },
      fields
    )
  end

  @doc "Diatonic steps of a note from the middle line of a clef's staff (+ is up)."
  @spec staff_pos(String.t(), integer(), :treble | :bass) :: integer()
  def staff_pos(step, octave, clef) do
    octave * 7 + Enum.find_index(@steps, &(&1 == step)) - Map.fetch!(@middle_line, clef)
  end

  # Clef ---------------------------------------------------------------------

  defp clef(clef, _midis, _spell) when clef in [:treble, :bass], do: clef
  defp clef(:auto, [], _spell), do: :treble

  defp clef(:auto, midis, spell) do
    treble = ledgers(midis, :treble, spell)
    bass = ledgers(midis, :bass, spell)

    cond do
      treble < bass -> :treble
      bass < treble -> :bass
      median(midis) >= 60 -> :treble
      true -> :bass
    end
  end

  defp ledgers(midis, clef, spell) do
    Enum.reduce(midis, 0, fn midi, acc ->
      {step, alter} = Map.fetch!(spell, Integer.mod(midi, 12))
      pos = abs(staff_pos(step, Integer.floor_div(midi - alter, 12) - 1, clef))
      if pos >= 6, do: acc + div(pos - 4, 2), else: acc
    end)
  end

  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  # Key caption ----------------------------------------------------------------

  @counts ~w(no one two three four five six seven)

  @doc """
  The sentence under the staff explaining the key signature: "D Dorian has
  no sharps or flats, so no key signature." `nil` is an open phrase.
  """
  @spec key_caption(Scale.t() | nil) :: String.t()
  def key_caption(nil), do: "An open phrase has no key, so no key signature."
  def key_caption(%Scale{mode: :chromatic}), do: "Chromatic has no key, so no key signature."

  def key_caption(%Scale{} = scale) do
    name = Scale.name(scale)

    case Scale.key_fifths(scale) do
      0 ->
        "#{name} has no sharps or flats, so no key signature."

      k ->
        {order, sign, word} =
          if k > 0, do: {@sharp_order, "#", "sharp"}, else: {@flat_order, "b", "flat"}

        n = abs(k)
        list = order |> Enum.take(n) |> Enum.map_join(", ", &(&1 <> sign))
        plural = if n == 1, do: word, else: word <> "s"
        "#{name} is written with #{Enum.at(@counts, n)} #{plural} (#{list}) in the key signature."
    end
  end
end
