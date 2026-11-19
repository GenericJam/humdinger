defmodule Humdinger.Views.PianoRollTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Scale, Style}
  alias Humdinger.Views.PianoRoll

  @w 350
  @h 312
  @eighth 312.5

  # The Review board's phrase: 2 bars of 4/4 at 96 bpm (5000 ms) in D Dorian.
  @review %{
    notes:
      Enum.map(
        [
          {0, 2, 62},
          {2, 1, 64},
          {3, 1, 65},
          {4, 3, 69},
          {8, 2, 65},
          {10, 2, 64},
          {12, 2, 62},
          {14, 2, 60}
        ],
        fn {s, d, m} -> %{start_ms: s * @eighth, dur_ms: d * @eighth, midi: m} end
      ),
    trace: [],
    scale: %Scale{root: 2, mode: :dorian},
    tempo_bpm: 96,
    beats_per_bar: 4,
    selected: 4
  }

  defp layout(data \\ @review), do: PianoRoll.layout(data, @w, @h)
  defp hit(x, y, data \\ @review), do: PianoRoll.hit(data, @w, @h, x, y)

  describe "rows" do
    test "a scale's notes over the phrase range, padded to fill the height" do
      l = layout()

      assert Enum.map(l.rows, & &1.midi) == [72, 71, 69, 67, 65, 64, 62, 60, 59, 57, 55, 53]
      assert l.row_h == 26.0
      assert l.x0 == 36
    end

    test "without a scale every semitone in the range has a row" do
      notes = [%{start_ms: 0, dur_ms: 500, midi: 60}, %{start_ms: 500, dur_ms: 500, midi: 64}]
      midis = layout(%{notes: notes, scale: nil}).rows |> Enum.map(& &1.midi)

      assert Enum.all?(60..64, &(&1 in midis))
      assert midis == Enum.to_list(hd(midis)..List.last(midis)//-1)
      assert hd(midis) > 64 and List.last(midis) < 60
    end

    test "a note outside the scale still gets its row" do
      notes = [%{start_ms: 0, dur_ms: 500, midi: 61}, %{start_ms: 500, dur_ms: 500, midi: 64}]
      midis = layout(%{notes: notes, scale: Scale.new("C", :major)}).rows |> Enum.map(& &1.midi)

      assert 61 in midis
      refute 63 in midis
    end

    test "short canvases get shorter rows, smaller labels and a narrower label column" do
      l = PianoRoll.layout(@review, @w, 180)

      assert l.row_h < 23
      assert l.x0 == 30
      assert Enum.find(PianoRoll.ops(@review, @w, 180), &(&1.op == :text)).size == 9
    end
  end

  describe "blocks" do
    test "x and width come from start and duration" do
      # 306 dp for 5000 ms from x0 = 36.
      %{x: x, w: w, y: y, h: h} = Enum.at(layout().blocks, 4)

      assert_in_delta x, 36 + 2500 * 306 / 5000 + 1, 1.0e-9
      assert_in_delta w, 625 * 306 / 5000 - 3, 1.0e-9
      # F4 is the 5th row: top 104, block 22 high centred in it.
      assert {y, h} == {106.0, 22.0}
    end

    test "blocks are drawn in the note's pitch colour" do
      rects =
        PianoRoll.ops(@review, @w, @h) |> Enum.filter(&(&1.op == :rect and &1[:radius] == 6))

      assert Enum.map(rects, & &1.color) == Enum.map(@review.notes, &Style.pitch_color(&1.midi))
    end

    test "the selected note gets a ring and two end handles" do
      b = Enum.at(layout().blocks, 4)
      ops = PianoRoll.ops(@review, @w, @h)

      assert Enum.any?(ops, &(&1.op == :rect and &1[:width] == 2 and &1.color == Style.text()))

      handles = Enum.filter(ops, &(&1.op == :rect and &1[:radius] == 3 and &1.w == 6))
      assert Enum.map(handles, & &1.x) == [Float.round(b.x - 3, 1), Float.round(b.x + b.w - 3, 1)]
      assert Enum.all?(handles, &(&1.h == 30.0))
    end

    test "beat lines every beat, wider at bars" do
      lines =
        PianoRoll.ops(@review, @w, @h)
        |> Enum.filter(&(&1.op == :rect and &1.color == 0xFF34304A))

      assert Enum.map(lines, & &1.w) == [2, 1, 1, 1, 2, 1, 1, 1, 2]
      assert hd(lines).x == 36.0
    end
  end

  describe "unsure notes" do
    test "are faded and counted in a chip" do
      notes = List.update_at(@review.notes, 1, &Map.put(&1, :unsure, true))
      notes = List.update_at(notes, 6, &Map.put(&1, :unsure, true))
      ops = PianoRoll.ops(%{@review | notes: notes}, @w, @h)

      faded = Enum.filter(ops, &(&1.op == :rect and &1[:opacity] == 0.4))
      assert Enum.map(faded, & &1.color) == [Style.pitch_color(64), Style.pitch_color(62)]

      chip = Enum.find(ops, &(&1.op == :text and &1.color == Style.warn()))
      assert chip.text == "2 unsure · faded"
    end

    test "no chip when every note is sure" do
      refute Enum.any?(
               PianoRoll.ops(@review, @w, @h),
               &(&1.op == :text and &1.color == Style.warn())
             )
    end
  end

  describe "hit/5" do
    setup do
      %{b: Enum.at(layout().blocks, 2), l: layout()}
    end

    test "the ends of a block, just inside and just outside", %{b: b} do
      cy = b.y + b.h / 2

      assert hit(b.x + 2, cy) == {:note, 2, :start}
      assert hit(b.x - 5, cy) == {:note, 2, :start}
      assert hit(b.x + b.w - 2, cy) == {:note, 2, :end}
      assert hit(b.x + b.w + 5, cy) == {:note, 2, :end}
    end

    test "edge zones are at least 12 dp wide and leave a body on long notes" do
      b = Enum.at(layout().blocks, 3)
      cy = b.y + b.h / 2

      assert hit(b.x + 11, cy) == {:note, 3, :start}
      assert hit(b.x + b.w / 2, cy) == {:note, 3, :body}
      assert hit(b.x + b.w - 11, cy) == {:note, 3, :end}
    end

    test "the top and bottom of the row still hit the block", %{b: b} do
      assert hit(b.x + b.w / 2, b.y - 1) == {:note, 2, :body}
      assert hit(b.x + b.w / 2, b.y + b.h + 1) == {:note, 2, :body}
    end

    test "an empty spot gives the time and the row's note", %{l: l} do
      # G4's row (index 3) under bar 2, where no note is.
      y = 3 * 26 + 20
      x = PianoRoll.x_of(l, 3750)

      assert {:empty, %{ms: ms, midi: 67}} = hit(x, y)
      assert_in_delta ms, 3750, 1.0e-6
    end

    test "the label column and outside the canvas are :none", %{l: l} do
      assert hit(10, 100) == :none
      assert hit(200, -1) == :none
      assert hit(200, @h + 1) == :none
      assert hit(@w + 1, 100) == :none
      assert PianoRoll.hit(l, @w, @h, 10, 100) == :none
    end

    test "a layout works in place of the data", %{l: l, b: b} do
      assert PianoRoll.hit(l, @w, @h, b.x + b.w / 2, b.y + 5) == hit(b.x + b.w / 2, b.y + 5)
    end

    test "the selected note wins where blocks overlap" do
      notes = [%{start_ms: 0, dur_ms: 2000, midi: 62}, %{start_ms: 500, dur_ms: 2000, midi: 62}]
      data = %{@review | notes: notes, selected: 0}
      [_, top] = PianoRoll.layout(data, @w, @h).blocks
      x = top.x + 30
      y = top.y + 5

      assert PianoRoll.hit(data, @w, @h, x, y) == {:note, 0, :body}
      assert PianoRoll.hit(%{data | selected: nil}, @w, @h, x, y) == {:note, 1, :body}
    end
  end

  describe "geometry" do
    test "time and pitch round-trip through x and y" do
      l = layout()

      assert_in_delta PianoRoll.ms_at(l, PianoRoll.x_of(l, 1234)), 1234, 1.0e-9

      for %{midi: m} <- l.rows do
        assert PianoRoll.midi_at(l, PianoRoll.y_of(l, m)) == m
      end
    end

    test "a pitch between two rows sits between them in proportion" do
      l = layout()
      # 66 lies between G4 (67) and F4 (65).
      assert PianoRoll.y_of(l, 66) == (PianoRoll.y_of(l, 67) + PianoRoll.y_of(l, 65)) / 2
      assert PianoRoll.midi_at(l, -1) == nil
      assert PianoRoll.midi_at(l, @h + 1) == nil
    end

    test "the sung line breaks where unvoiced and is faint" do
      trace = [{0, 62.0}, {400, 62.1}, {600, nil}, {900, 64.0}, {1200, 64.2}]

      paths =
        PianoRoll.ops(%{@review | trace: trace}, @w, @h)
        |> Enum.filter(&(&1.op == :path and &1[:width] == 2))

      assert [_, _] = paths
      assert Enum.all?(paths, &(&1.opacity == 0.35))
    end
  end

  test "empty data renders an empty roll" do
    ops = PianoRoll.ops(%{notes: [], trace: [], scale: nil, tempo_bpm: nil, selected: 3}, @w, @h)

    assert Enum.any?(ops, &(&1.op == :text))
    refute Enum.any?(ops, &(&1.op == :rect and &1[:radius] in [3, 6]))
    assert {:empty, %{midi: _}} = PianoRoll.hit(%{notes: []}, @w, @h, 200, 100)
  end

  describe "playhead and active-note highlight" do
    test "renders playhead line at actual ms and outlines the block at active" do
      l = layout()
      b4 = Enum.at(l.blocks, 4)
      ops = PianoRoll.ops(Map.merge(@review, %{playhead_ms: 2700, active: 4}), @w, @h)

      bars = Enum.filter(ops, &(&1.op == :rect and &1.color == Style.fm() and &1[:fill]))
      rings = Enum.filter(ops, &(&1.op == :rect and &1.color == Style.fm() and &1[:width] == 2))

      assert [bar] = bars
      assert bar.w == 2 and bar.h == @h
      assert bar.x == Float.round(PianoRoll.x_of(l, 2700) - 1, 1)

      assert [ring] = rings
      assert ring.x == Float.round(b4.x + 1, 1)
      assert ring.y == Float.round(b4.y + 1, 1)
    end

    test "draws no active outline when active is nil and clamps playhead beyond duration" do
      gap_ops = PianoRoll.ops(Map.merge(@review, %{playhead_ms: 2700, active: nil}), @w, @h)
      assert [_bar] = Enum.filter(gap_ops, &(&1.color == Style.fm() and &1[:fill]))
      assert [] == Enum.filter(gap_ops, &(&1.color == Style.fm() and &1[:width] == 2))

      past_ops = PianoRoll.ops(Map.put(@review, :playhead_ms, 10_000), @w, @h)
      [clamped] = Enum.filter(past_ops, &(&1.color == Style.fm() and &1[:fill]))
      assert clamped.x == @w - 8 - 1
    end
  end
end
