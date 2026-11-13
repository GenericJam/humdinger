defmodule Humdinger.PhraseTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Phrase, Scale, Take}

  # The Review board's phrase: {start, length} in eighths at 96 bpm.
  @board [
    {0, 2, 62},
    {2, 1, 64},
    {3, 1, 65},
    {4, 3, 69},
    {8, 2, 65},
    {10, 2, 64},
    {12, 2, 62},
    {14, 2, 60}
  ]
  @eighth 312.5

  defp sung(spec, opts \\ []) do
    lead = Keyword.get(opts, :lead, 0)
    jitter = Keyword.get(opts, :jitter, [])
    eighth = Keyword.get(opts, :eighth, @eighth)

    spec
    |> Enum.with_index()
    |> Enum.map(fn {{s, l, m}, i} ->
      j = Enum.at(jitter, rem(i, max(length(jitter), 1)), 0)
      start = round(lead + s * eighth + j)
      %{start_ms: start, dur_ms: round(l * eighth) - 30, midi: m, velocity: 90, unsure: false}
    end)
  end

  defp take(notes, fields \\ []) do
    struct!(
      %Take{
        notes: notes,
        trace: [],
        duration_ms: notes |> Enum.map(&(&1.start_ms + &1.dur_ms)) |> Enum.max(fn -> 0 end),
        source: :hum
      },
      fields
    )
  end

  defp board(fields \\ []) do
    struct!(
      %Phrase{notes: sung(@board), tempo_bpm: 96, scale: Scale.new("D", :dorian), quantize: :q8},
      fields
    )
  end

  describe "from_take/2" do
    test "detects the tempo of a jittery performance and starts on the first note" do
      notes = sung(@board, lead: 740, jitter: [12, -25, 30, -8, 20, -33, 5, 18])
      trace = [{0, nil}, {700, nil}, {740, 62.1}, {760, 62.0}]

      phrase =
        Phrase.from_take(take(notes, trace: trace, scale: Scale.new("D", :dorian)),
          now: ~U[2026-11-12 10:00:00Z]
        )

      assert phrase.tempo_bpm == 96
      assert phrase.tempo_detected
      assert hd(phrase.notes).start_ms in 0..40

      assert Enum.map(Phrase.quantized_notes(phrase), & &1.start_ms) ==
               Enum.map(@board, fn {s, _, _} -> round(s * @eighth) end)

      assert Enum.all?(phrase.trace, fn {t, _} -> t >= 0 end)
      assert Enum.any?(phrase.trace, fn {_, p} -> p == 62.0 end)
      assert phrase.name == "New phrase"
      assert phrase.created_at == ~U[2026-11-12 10:00:00Z]
      assert Phrase.summary(phrase) == "8 notes · 2 bars at 96 · D Dorian"
    end

    test "keeps a take's own tempo and drops only whole beats before the first note" do
      beat = 500

      notes =
        for {b, m} <- [{2.5, 60}, {3, 62}, {4, 64}],
            do: %{start_ms: round(b * beat), dur_ms: 400, midi: m, velocity: 80, unsure: false}

      phrase = Phrase.from_take(take(notes, tempo_bpm: 120))

      refute phrase.tempo_detected
      assert phrase.tempo_bpm == 120
      assert Enum.map(phrase.notes, & &1.start_ms) == [250, 500, 1000]
    end

    test "an open take stays open" do
      phrase = Phrase.from_take(take(sung(@board)))
      assert phrase.scale == nil
      assert Phrase.summary(phrase) =~ ~r/ · open$/
    end

    test "too few notes for a tempo fall back to 120 bpm, not detected" do
      phrase =
        Phrase.from_take(
          take([%{start_ms: 300, dur_ms: 500, midi: 60, velocity: 80, unsure: false}])
        )

      assert phrase.tempo_bpm == 120
      refute phrase.tempo_detected
      assert [%{start_ms: 0, dur_ms: 500}] = phrase.notes
      assert Phrase.summary(phrase) == "1 note · 1 bar at 120 · open"
    end

    test "an empty take makes an empty phrase" do
      phrase = Phrase.from_take(take([]), name: "Nothing", quantize: :q16)
      assert phrase.notes == []
      assert phrase.name == "Nothing"
      assert phrase.quantize == :q16
      assert Phrase.bars(phrase) == 1
    end
  end

  describe "list_summary/3" do
    @now ~U[2026-11-12 15:00:00Z]

    test "relative days" do
      at = fn iso -> board(created_at: DateTime.from_iso8601(iso) |> elem(1)) end

      assert Phrase.list_summary(at.("2026-11-12T08:00:00Z"), @now, utc_offset: 0) ==
               "8 notes · 2 bars · D Dorian · today"

      assert Phrase.list_summary(at.("2026-11-11T23:59:00Z"), @now, utc_offset: 0) =~
               ~r/· yesterday$/

      # 2026-11-10 is a Tuesday, 2026-11-06 a Friday.
      assert Phrase.list_summary(at.("2026-11-10T12:00:00Z"), @now, utc_offset: 0) =~ ~r/· Tue$/
      assert Phrase.list_summary(at.("2026-11-06T12:00:00Z"), @now, utc_offset: 0) =~ ~r/· Fri$/
      assert Phrase.list_summary(at.("2026-11-05T12:00:00Z"), @now, utc_offset: 0) =~ ~r/· 5 Nov$/

      assert Phrase.list_summary(at.("2025-12-31T12:00:00Z"), @now, utc_offset: 0) =~
               ~r/· 31 Dec 2025$/
    end

    test "today is the phone's local day" do
      phrase = board(created_at: ~U[2026-11-11 23:30:00Z])
      now = ~U[2026-11-12 00:30:00Z]

      assert Phrase.list_summary(phrase, now, utc_offset: 0) =~ ~r/yesterday$/
      assert Phrase.list_summary(phrase, now, utc_offset: 3600) =~ ~r/today$/
    end

    test "open phrases and singular counts" do
      phrase = %Phrase{
        notes: [%{start_ms: 0, dur_ms: 3000, midi: 40, velocity: 80, unsure: false}],
        tempo_bpm: 100,
        created_at: @now
      }

      assert Phrase.list_summary(phrase, @now, utc_offset: 0) == "1 note · 2 bars · open · today"
    end
  end

  describe "bars/1" do
    test "counts bars up to the last note's end on the grid" do
      assert Phrase.bars(board()) == 2
      assert Phrase.bars(board(notes: sung(@board ++ [{16, 1, 62}]))) == 3
      assert Phrase.bars(board(quantize: :off)) == 2
      assert Phrase.bars(board(notes: [])) == 1
    end
  end

  describe "quantize_notes/3" do
    test "snaps starts and ends to the grid" do
      notes = [%{start_ms: 290, dur_ms: 340, midi: 60, velocity: 80, unsure: true}]

      assert [%{start_ms: 313, dur_ms: 312, unsure: true}] = Phrase.quantize_notes(notes, 96, :q8)
      assert [%{start_ms: 0, dur_ms: 625}] = Phrase.quantize_notes(notes, 96, :q4)
      assert [%{start_ms: 313, dur_ms: 312}] = Phrase.quantize_notes(notes, 96, :q16)
      assert [%{start_ms: 208, dur_ms: 417}] = Phrase.quantize_notes(notes, 96, :triplet)
      assert Phrase.quantize_notes(notes, 96, :off) == notes
    end

    test "a note shorter than a step still lasts one step" do
      assert [%{start_ms: 0, dur_ms: 313}] =
               Phrase.quantize_notes(
                 [%{start_ms: 10, dur_ms: 40, midi: 60, velocity: 80, unsure: false}],
                 96,
                 :q8
               )
    end

    test "notes landing on the same step keep the longer one" do
      notes = [
        %{start_ms: 0, dur_ms: 80, midi: 60, velocity: 80, unsure: false},
        %{start_ms: 90, dur_ms: 500, midi: 62, velocity: 80, unsure: false}
      ]

      assert [%{midi: 62, start_ms: 0}] = Phrase.quantize_notes(notes, 96, :q8)

      assert [%{midi: 62}] =
               Phrase.quantize_notes([%{hd(notes) | start_ms: 90} | tl(notes)], 96, :off)
    end

    test "any line comes out monophonic with no empty notes" do
      :rand.seed(:exsss, {7, 8, 9})

      for q <- Phrase.quantizes() do
        notes =
          Enum.map(1..200, fn _ ->
            %{
              start_ms: :rand.uniform(20_000),
              dur_ms: :rand.uniform(900),
              midi: 60,
              velocity: 80,
              unsure: false
            }
          end)

        out = Phrase.quantize_notes(notes, 87, q)

        assert Enum.all?(out, &(&1.dur_ms > 0))

        for [a, b] <- Enum.chunk_every(out, 2, 1, :discard) do
          assert a.start_ms + a.dur_ms <= b.start_ms
        end
      end
    end
  end

  describe "edits" do
    test "move_note/3 transposes within MIDI range and confirms the note" do
      phrase = board(notes: [%{start_ms: 0, dur_ms: 300, midi: 125, velocity: 80, unsure: true}])

      assert [%{midi: 127, unsure: false}] = Phrase.move_note(phrase, 0, 5).notes
      assert [%{midi: 120}] = Phrase.move_note(phrase, 0, -5).notes
    end

    test "resize_note/4 snaps to the grid and stops at the neighbours" do
      phrase = board()

      # Note 4 (F4) starts at eighth 8; drag its start to eighth 6, inside A4
      # (which ends just before eighth 7): it stops at A4's end.
      resized = Phrase.resize_note(phrase, 4, :start, 6.4 * @eighth)
      a4 = Enum.at(resized.notes, 3)
      assert Enum.at(resized.notes, 4).start_ms == a4.start_ms + a4.dur_ms

      # Drag it to 7.4 eighths: it snaps to eighth 7, clear of A4.
      assert Enum.at(Phrase.resize_note(phrase, 4, :start, 7.4 * @eighth).notes, 4).start_ms ==
               round(7 * @eighth)

      # Lengthen the end to just before eighth 11: snaps to 11, but the next note starts at 10.
      resized = Phrase.resize_note(phrase, 4, :end, 10.9 * @eighth)

      assert Enum.at(resized.notes, 4).start_ms + Enum.at(resized.notes, 4).dur_ms ==
               Enum.at(phrase.notes, 5).start_ms

      # Shorten the end to nothing: one eighth remains.
      resized = Phrase.resize_note(phrase, 4, :end, 0)
      assert Enum.at(resized.notes, 4).dur_ms == round(@eighth)

      # Snapping: drag the end to 9.2 eighths.
      resized = Phrase.resize_note(phrase, 4, :end, 9.2 * @eighth)
      f4 = Enum.at(resized.notes, 4)
      assert f4.start_ms + f4.dur_ms == round(9 * @eighth)
    end

    test "resize_note/4 without a grid keeps 60 ms and grows the phrase at the end" do
      phrase = board(quantize: :off)
      last = length(phrase.notes) - 1

      shortened = Phrase.resize_note(phrase, 0, :end, 10)
      assert hd(shortened.notes).dur_ms == 60

      grown = Phrase.resize_note(phrase, last, :end, 9000)
      assert grown.duration_ms == 9000
      assert List.last(grown.notes).start_ms + List.last(grown.notes).dur_ms == 9000
    end

    test "resize_note/4 leaves a note alone when there is no room" do
      notes = [
        %{start_ms: 0, dur_ms: 300, midi: 60, velocity: 80, unsure: false},
        %{start_ms: 300, dur_ms: 30, midi: 62, velocity: 80, unsure: true}
      ]

      phrase = %Phrase{notes: notes, tempo_bpm: 96, quantize: :off}
      assert Phrase.resize_note(phrase, 1, :start, 0) == phrase
    end

    test "set_tempo/2 rounds, clamps, and is no longer detected" do
      phrase = board(tempo_detected: true)

      assert %{tempo_bpm: 97, tempo_detected: false} = Phrase.set_tempo(phrase, 96.6)
      assert Phrase.set_tempo(phrase, 5).tempo_bpm == 40
      assert Phrase.set_tempo(phrase, 999).tempo_bpm == 240
    end

    test "set_quantize/2 and rename/2" do
      assert Phrase.set_quantize(board(), :triplet).quantize == :triplet
      assert_raise FunctionClauseError, fn -> Phrase.set_quantize(board(), Enum.at([:q32], 0)) end
      assert Phrase.rename(board(), "  Bus stop riff ").name == "Bus stop riff"
      assert Phrase.rename(board(name: "x"), "   ").name == "New phrase"
    end
  end

  describe "spelling_scale/1" do
    test "a phrase's own scale, or the key its notes suggest when open" do
      assert Phrase.spelling_scale(board()) == Scale.new("D", :dorian)

      f_major =
        for {m, i} <- Enum.with_index([65, 67, 69, 70, 72, 70, 69, 67, 65]),
            do: %{start_ms: i * 400, dur_ms: 380, midi: m, velocity: 80, unsure: false}

      assert Phrase.spelling_scale(%Phrase{notes: f_major}) |> Scale.flats?()
      assert Phrase.spelling_scale(%Phrase{notes: []}) == nil
    end
  end
end
