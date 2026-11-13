defmodule Humdinger.NotationTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Notation, Phrase, Scale}

  @beats %{whole: 4, half: 2, quarter: 1, eighth: 0.5, sixteenth: 0.25}

  # Notes given as {start_beat, beats, midi} at 60 bpm (a beat is 1000 ms).
  defp phrase(spec, fields \\ []) do
    notes =
      for {s, l, m} <- spec,
          do: %{
            start_ms: round(s * 1000),
            dur_ms: round(l * 1000),
            midi: m,
            velocity: 80,
            unsure: false
          }

    struct!(
      %Phrase{notes: notes, tempo_bpm: 60, scale: Scale.new("C", :major), quantize: :q8},
      fields
    )
  end

  defp beats(item) do
    b = @beats[item.type] * if(item.dots == 1, do: 1.5, else: 1)
    if item.tuplet, do: b * 2 / 3, else: b
  end

  defp items(layout, m), do: Enum.at(layout.measures, m).items

  defp shape(items), do: Enum.map(items, &{&1.kind, &1.beat, &1.type, &1.dots, &1.tie_to_next})

  test "the sheet board's phrase" do
    e = 0.5

    spec =
      for {s, l, m} <- [
            {0, 2, 62},
            {2, 1, 64},
            {3, 1, 65},
            {4, 3, 69},
            {8, 2, 65},
            {10, 2, 64},
            {12, 2, 62},
            {14, 2, 60}
          ],
          do: {s * e, l * e - 0.03, m}

    layout = Notation.layout(phrase(spec, scale: Scale.new("D", :dorian)))

    assert %{clef: :treble, key_fifths: 0, time: {4, 4}} = layout
    assert [_, _] = layout.measures

    assert [
             %{
               kind: :note,
               beat: +0.0,
               type: :quarter,
               dots: 0,
               step: "D",
               octave: 4,
               staff_pos: -5,
               beam: nil
             },
             %{kind: :note, beat: 1.0, type: :eighth, step: "E", staff_pos: -4, beam: :begin},
             %{kind: :note, beat: 1.5, type: :eighth, step: "F", staff_pos: -3, beam: :end},
             %{kind: :note, beat: 2.0, type: :quarter, dots: 1, step: "A", staff_pos: -1},
             %{kind: :rest, beat: 3.5, type: :eighth, dots: 0, midi: nil, note_index: nil}
           ] = items(layout, 0)

    bar2 = items(layout, 1)

    assert Enum.map(bar2, &{&1.type, &1.step, &1.octave}) == [
             {:quarter, "F", 4},
             {:quarter, "E", 4},
             {:quarter, "D", 4},
             {:quarter, "C", 4}
           ]

    assert List.last(bar2).staff_pos == -6
    assert Enum.map(bar2, & &1.note_index) == [4, 5, 6, 7]

    assert Enum.all?(
             items(layout, 0) ++ bar2,
             &(&1.accidental == nil and &1.tuplet == nil and not &1.tie_to_next)
           )
  end

  describe "rhythm spelling in 4/4" do
    test "whole, dotted half and half notes from the downbeat" do
      layout =
        Notation.layout(phrase([{0, 4, 60}, {4, 3, 62}, {7, 1, 64}, {8, 2, 65}, {10, 2, 67}]))

      assert shape(items(layout, 0)) == [{:note, 0.0, :whole, 0, false}]

      assert shape(items(layout, 1)) == [
               {:note, 0.0, :half, 1, false},
               {:note, 3.0, :quarter, 0, false}
             ]

      assert shape(items(layout, 2)) == [
               {:note, 0.0, :half, 0, false},
               {:note, 2.0, :half, 0, false}
             ]
    end

    test "nothing but a downbeat note crosses the middle of the bar" do
      layout = Notation.layout(phrase([{1, 2, 60}, {3, 1, 62}]))

      assert shape(items(layout, 0)) == [
               {:rest, 0.0, :quarter, 0, false},
               {:note, 1.0, :quarter, 0, true},
               {:note, 2.0, :quarter, 0, false},
               {:note, 3.0, :quarter, 0, false}
             ]
    end

    test "an off-beat note ends at the next beat, tied on" do
      layout = Notation.layout(phrase([{0, 0.5, 60}, {0.5, 1, 62}, {1.5, 2.5, 64}]))

      assert shape(items(layout, 0)) == [
               {:note, 0.0, :eighth, 0, false},
               {:note, 0.5, :eighth, 0, true},
               {:note, 1.0, :eighth, 0, false},
               {:note, 1.5, :eighth, 0, true},
               {:note, 2.0, :half, 0, false}
             ]

      assert Enum.map(items(layout, 0), & &1.beam) == [:begin, :end, :begin, :end, nil]
    end

    test "notes tie over the barline without repeating the accidental" do
      layout = Notation.layout(phrase([{3, 2, 61}, {5, 1, 61}]))

      assert [
               %{kind: :rest, type: :half},
               %{kind: :rest, beat: 2.0},
               %{beat: 3.0, step: "C", alter: 1, accidental: :sharp, tie_to_next: true}
             ] =
               items(layout, 0)

      assert [
               %{beat: +0.0, accidental: nil, tie_to_next: false},
               %{beat: 1.0, accidental: :sharp} | _
             ] = items(layout, 1)
    end

    test "rests are not dotted and an empty phrase is a whole-bar rest" do
      layout = Notation.layout(phrase([{1.5, 0.5, 60}, {3.5, 0.5, 60}]))
      assert Enum.all?(items(layout, 0), &(&1.dots == 0))

      assert shape(items(layout, 0)) == [
               {:rest, 0.0, :quarter, 0, false},
               {:rest, 1.0, :eighth, 0, false},
               {:note, 1.5, :eighth, 0, false},
               {:rest, 2.0, :quarter, 0, false},
               {:rest, 3.0, :eighth, 0, false},
               {:note, 3.5, :eighth, 0, false}
             ]

      assert %{
               measures: [%{index: 0, items: [%{kind: :rest, type: :whole, beat: +0.0}]}],
               clef: :treble
             } =
               Notation.layout(phrase([]))
    end

    test "sixteenths are beamed in fours within a beat, dotted eighth + sixteenth in pairs" do
      spec = [
        {0, 0.25, 60},
        {0.25, 0.25, 62},
        {0.5, 0.25, 64},
        {0.75, 0.25, 65},
        {1, 0.75, 67},
        {1.75, 0.25, 65},
        {2, 2, 64}
      ]

      layout = Notation.layout(phrase(spec, quantize: :q16))

      assert Enum.map(items(layout, 0), &{&1.type, &1.dots, &1.beam}) == [
               {:sixteenth, 0, :begin},
               {:sixteenth, 0, :continue},
               {:sixteenth, 0, :continue},
               {:sixteenth, 0, :end},
               {:eighth, 1, :begin},
               {:sixteenth, 0, :end},
               {:half, 0, nil}
             ]
    end

    test "eighth-note triplets" do
      third = 1 / 3

      spec = [
        {0, third, 60},
        {third, third, 62},
        {2 * third, third, 64},
        {1, 2 * third, 65},
        {1 + 2 * third, third, 67},
        {2, 2, 69}
      ]

      layout = Notation.layout(phrase(spec, quantize: :triplet))

      assert Enum.map(items(layout, 0), &{&1.type, &1.tuplet, &1.beam}) == [
               {:eighth, {3, 2}, :begin},
               {:eighth, {3, 2}, :continue},
               {:eighth, {3, 2}, :end},
               {:quarter, {3, 2}, nil},
               {:eighth, {3, 2}, nil},
               {:half, nil, nil}
             ]
    end

    test "simpler rhythm uses quarter notes" do
      layout =
        Notation.layout(phrase([{0, 0.5, 60}, {0.5, 0.5, 62}, {1, 0.5, 64}, {1.5, 2.5, 65}]),
          rhythm: :simpler
        )

      assert Enum.all?(items(layout, 0), &(&1.type in [:quarter, :half, :whole]))
      assert Enum.all?(items(layout, 0), &(&1.beat == Float.round(&1.beat)))
    end

    test "as sung with quantize off reads at sixteenths" do
      layout = Notation.layout(phrase([{0, 0.25, 60}, {0.25, 3.75, 62}], quantize: :off))
      assert [%{type: :sixteenth} | _] = items(layout, 0)
    end
  end

  describe "invariants" do
    test "every measure adds up to four beats, follows the 4/4 rules, and keeps every note" do
      :rand.seed(:exsss, {3, 1, 4})

      for quantize <- [:q4, :q8, :q16, :triplet, :off],
          rhythm <- [:as_sung, :simpler],
          _ <- 1..15 do
        spec =
          Enum.scan(1..12, {0.0, 0.0, 60}, fn _, {s, l, _} ->
            {s + l + Enum.random([0, 0, 0.25, 0.5, 1.5]),
             Enum.random([0.2, 0.33, 0.5, 0.75, 1, 1.5, 2, 3, 5]), 55 + :rand.uniform(20)}
          end)

        p =
          phrase(spec,
            quantize: quantize,
            scale: Enum.random([nil, Scale.new("Eb", :major), Scale.new("E", :minor)])
          )

        layout = Notation.layout(p, rhythm: rhythm)

        for m <- layout.measures do
          assert_in_delta Enum.sum(Enum.map(m.items, &beats/1)), 4.0, 1.0e-9

          Enum.reduce(m.items, 0.0, fn i, at ->
            assert_in_delta i.beat, at, 1.0e-9
            stop = i.beat + beats(i)
            if i.type in [:whole] or (i.type == :half and i.dots == 1), do: assert(i.beat == 0.0)
            if i.beat > 0, do: refute(i.beat < 2 and stop > 2.0 + 1.0e-9)
            if i.beat != Float.floor(i.beat), do: assert(stop <= Float.floor(i.beat) + 1 + 1.0e-9)
            stop
          end)
        end

        all = Enum.flat_map(layout.measures, & &1.items)

        grid =
          if rhythm == :simpler, do: :q4, else: if(quantize == :off, do: :q16, else: quantize)

        kept = p.notes |> Phrase.grid_notes(60, grid) |> Enum.map(& &1.index)
        assert all |> Enum.map(& &1.note_index) |> Enum.reject(&is_nil/1) |> Enum.dedup() == kept

        for [a, b] <- Enum.chunk_every(all, 2, 1, :discard), a.kind == :note and a.tie_to_next do
          assert b.kind == :note and b.midi == a.midi and b.note_index == a.note_index
        end
      end
    end
  end

  describe "spelling and accidentals" do
    test "in E minor F# needs nothing, F natural is marked once per bar" do
      layout =
        Notation.layout(
          phrase([{0, 1, 66}, {1, 1, 65}, {2, 1, 65}, {3, 1, 77}, {4, 1, 66}],
            scale: Scale.new("E", :minor)
          )
        )

      assert layout.key_fifths == 1

      assert Enum.map(items(layout, 0), &{&1.step, &1.alter, &1.accidental}) == [
               {"F", 1, nil},
               {"F", 0, :natural},
               {"F", 0, nil},
               {"F", 0, :natural}
             ]

      assert [%{step: "F", alter: 1, accidental: nil} | _] = items(layout, 1)
    end

    test "a flat key spells black keys as flats" do
      layout =
        Notation.layout(
          phrase([{0, 1, 70}, {1, 1, 61}, {2, 1, 70}, {3, 1, 71}], scale: Scale.new("Bb", :major))
        )

      assert layout.key_fifths == -2

      assert Enum.map(items(layout, 0), &{&1.step, &1.alter, &1.accidental}) == [
               {"B", -1, nil},
               {"D", -1, :flat},
               {"B", -1, nil},
               {"B", 0, :natural}
             ]
    end

    test "an open phrase has no key signature but spells like its likely key" do
      f_major = [
        {0, 1, 65},
        {1, 1, 67},
        {2, 1, 69},
        {3, 1, 70},
        {4, 1, 72},
        {5, 1, 70},
        {6, 1, 69},
        {7, 1, 65}
      ]

      layout = Notation.layout(phrase(f_major, scale: nil))

      assert layout.key_fifths == 0
      assert %{step: "B", alter: -1, accidental: :flat} = Enum.at(items(layout, 0), 3)
    end

    test "a chromatic phrase also spells like its likely key" do
      a_major = [
        {0, 1, 69},
        {1, 1, 71},
        {2, 1, 73},
        {3, 1, 74},
        {4, 1, 76},
        {5, 1, 73},
        {6, 1, 71},
        {7, 1, 69}
      ]

      layout = Notation.layout(phrase(a_major, scale: Scale.chromatic()))

      assert layout.key_fifths == 0
      assert %{step: "C", alter: 1, accidental: :sharp} = Enum.at(items(layout, 0), 2)
    end
  end

  describe "clef and staff positions" do
    test "staff_pos counts diatonic steps from the middle line" do
      assert Notation.staff_pos("B", 4, :treble) == 0
      assert Notation.staff_pos("C", 4, :treble) == -6
      assert Notation.staff_pos("F", 5, :treble) == 4
      assert Notation.staff_pos("D", 3, :bass) == 0
      assert Notation.staff_pos("C", 4, :bass) == 6
      assert Notation.staff_pos("G", 2, :bass) == -4
    end

    test "auto picks the clef with fewer ledger lines" do
      low = phrase([{0, 1, 43}, {1, 1, 47}, {2, 1, 50}, {3, 1, 52}])
      high = phrase([{0, 1, 72}, {1, 1, 74}, {2, 1, 67}])

      assert Notation.layout(low).clef == :bass
      assert Notation.layout(high).clef == :treble
      assert Notation.layout(low, clef: :treble).clef == :treble
      assert [%{staff_pos: -16} | _] = items(Notation.layout(low, clef: :treble), 0)
      # Around middle C both clefs need one ledger line; the median decides.
      assert Notation.layout(phrase([{0, 1, 60}, {1, 1, 62}])).clef == :treble
      assert Notation.layout(phrase([{0, 1, 60}, {1, 1, 59}])).clef == :bass
    end
  end

  test "key_caption/1" do
    assert Notation.key_caption(Scale.new("D", :dorian)) ==
             "D Dorian has no sharps or flats, so no key signature."

    assert Notation.key_caption(Scale.new("E", :minor)) ==
             "E minor is written with one sharp (F#) in the key signature."

    assert Notation.key_caption(Scale.new("Eb", :major)) ==
             "Eb major is written with three flats (Bb, Eb, Ab) in the key signature."

    assert Notation.key_caption(nil) == "An open phrase has no key, so no key signature."
    assert Notation.key_caption(Scale.chromatic()) == "Chromatic has no key, so no key signature."
  end
end
