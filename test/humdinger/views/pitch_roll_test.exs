defmodule Humdinger.Views.PitchRollTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Scale, Style}
  alias Humdinger.Views.PitchRoll

  @w 350
  @h 256
  # Playhead at x = 350 − 44 = 306; 4000 ms across it; centre 60 at y = 128.
  @base %{now_ms: 10_000, trace: [], notes: [], scale: nil, center_midi: 60}

  defp ops(data), do: PitchRoll.ops(Map.merge(@base, data), @w, @h)

  defp note_blocks(ops), do: Enum.filter(ops, &(&1.op == :rect and Map.get(&1, :radius) == 5))
  defp trace_paths(ops), do: Enum.filter(ops, &(&1.op == :path and Map.get(&1, :width) == 2.5))
  defp label(ops, name), do: Enum.find(ops, &(&1.op == :text and &1.text == name))

  defp row_rect(ops, y_top) do
    Enum.find(ops, &(&1.op == :rect and &1.y == y_top and &1.h == 22.0))
  end

  describe "note blocks" do
    test "x and width follow start and end times, centred on the note's row" do
      [block] = ops(%{notes: [%{start_ms: 7000, end_ms: 9000, midi: 62}]}) |> note_blocks()

      assert block.x == 76.5
      assert block.w == 153.0
      # Row centre of 62 = 128 − 2·22 = 84; blocks are 16 high.
      assert block.y == 76.0
      assert block.h == 16
      assert block.color == Style.pitch_color(62)
    end

    test "an ended note is drawn at 0.55, a sounding one at full opacity up to the playhead" do
      blocks =
        ops(%{
          notes: [
            %{start_ms: 7000, end_ms: 8000, midi: 60},
            %{start_ms: 9000, end_ms: nil, midi: 62}
          ]
        })
        |> note_blocks()

      assert [%{opacity: 0.55}, %{opacity: 1.0} = sounding] = blocks
      assert sounding.x + sounding.w == 306.0
    end

    test "notes off the canvas are dropped" do
      notes = [
        # ended before the left edge (now − 4000)
        %{start_ms: 5000, end_ms: 5900, midi: 60},
        # far above the visible rows
        %{start_ms: 9000, end_ms: 9500, midi: 80},
        %{start_ms: 9000, end_ms: 9500, midi: 61}
      ]

      assert [%{color: color}] = ops(%{notes: notes}) |> note_blocks()
      assert color == Style.pitch_color(61)
    end

    test "a note scrolling off the left edge is cut at the edge" do
      [block] = ops(%{notes: [%{start_ms: 5000, end_ms: 7000, midi: 60}]}) |> note_blocks()

      assert block.x == 0.0
      assert block.w == 76.5
    end
  end

  describe "rows" do
    test "in-scale rows are striped and labelled; out-of-scale rows are dark with faint labels" do
      ops = ops(%{scale: Scale.new("D", :dorian), center_midi: 67})

      assert row_rect(ops, 73.0).color == 0xFF1F1C29
      assert label(ops, "A4").color == 0xFFA9A3B8
      assert row_rect(ops, 183.0).color == 0xFF221F2D
      assert label(ops, "E4").color == 0xFFA9A3B8
      assert row_rect(ops, 95.0).color == 0xFF17151E
      assert label(ops, "G#4").color == 0xFF4F4A60
      assert label(ops, "A4").y == 79.0
      assert label(ops, "A4").x == 8.0
    end

    test "with no scale the naturals are in scale" do
      ops = ops(%{scale: nil, center_midi: 67})

      assert label(ops, "A4").color == 0xFFA9A3B8
      assert label(ops, "A#4").color == 0xFF4F4A60
      assert label(ops, "F#4").color == 0xFF4F4A60
    end

    test "a fractional centre shifts every row by the fraction of a row" do
      at = fn c -> ops(%{center_midi: c}) |> label("C4") |> Map.fetch!(:y) end

      assert at.(60.5) - at.(60) == 11.0
    end
  end

  describe "sung pitch" do
    test "the line breaks where the pitch is nil" do
      trace = [{8000, 60}, {8500, 61}, {9000, nil}, {9200, nil}, {9500, 62}, {10_000, 62.5}]

      assert [first, second] = ops(%{trace: trace}) |> trace_paths()
      assert first.points == [[153.0, 128.0], [191.3, 106.0]]
      assert List.last(second.points) == [306.0, 73.0]
    end

    test "the playhead dot sits at the latest pitch" do
      ops = ops(%{trace: [{9000, 60}, {10_000, 62.5}]})

      assert [dot] = Enum.filter(ops, &(&1.op == :circle))
      assert {dot.x, dot.y, dot.r} == {307.0, 73.0, 10}
    end

    test "no dot while the latest sample is unvoiced" do
      ops = ops(%{trace: [{9000, 60}, {10_000, nil}]})

      refute Enum.any?(ops, &(&1.op == :circle and &1.r == 10))
    end

    test "a trace older than the window, or off the rows, draws nothing" do
      assert [] = ops(%{trace: [{1000, 60}, {2000, 61}]}) |> trace_paths()
      assert [] = ops(%{trace: [{9000, 90}, {9500, 91}]}) |> trace_paths()
    end

    test "the line enters from the left edge" do
      [path] = ops(%{trace: [{5000, 60}, {7000, 60}, {9000, 60}]}) |> trace_paths()

      assert [[x0, _] | _] = path.points
      # Cut at the edge, so the line starts exactly on it.
      assert x0 == 0
    end
  end

  test "empty data draws the box, rows and playhead only" do
    ops = PitchRoll.ops(%{now_ms: 0, trace: [], notes: [], scale: nil, center_midi: 60}, @w, @h)

    assert hd(ops).color == Style.surface()
    assert note_blocks(ops) == []
    assert trace_paths(ops) == []
    assert Enum.any?(ops, &(&1.op == :rect and &1.x == 306.0 and &1.opacity == 0.4))
  end

  test "every op stays on the canvas" do
    data = %{
      trace: [{0, 50}, {7000, 61}, {10_000, 62}],
      notes: [%{start_ms: 0, end_ms: 100, midi: 60}, %{start_ms: 9000, end_ms: nil, midi: 75}]
    }

    for %{op: :rect} = r <- ops(data) do
      assert r.x < @w and r.x + r.w > 0 and r.y < @h and r.y + r.h > 0
    end
  end
end
