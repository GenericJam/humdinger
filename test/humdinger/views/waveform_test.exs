defmodule Humdinger.Views.WaveformTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.Waveform

  # The board's strip: 330 × 54 plus the 7 / 4 dp overhang margins.
  @w 344
  @h 62
  @outside 0xFF4A4560

  defp data(opts \\ []) do
    Map.merge(
      %{peaks: :binary.copy(<<200>>, 760), duration_ms: 38_000, selection: {9_000, 21_000}},
      Map.new(opts)
    )
  end

  defp bars(ops), do: Enum.filter(ops, &(&1.op == :rect and &1.color in [Style.fm(), @outside]))
  defp white(ops), do: Enum.filter(ops, &(&1.color == Style.text()))

  describe "ops/3" do
    test "110 bars on a 3 dp pitch across the strip, lime inside the selection" do
      bars = bars(Waveform.ops(data(), @w, @h))
      assert Enum.count(bars) == 110
      assert hd(bars).x == 7.0
      assert_in_delta List.last(bars).x + List.last(bars).w, @w - 7, 0.1

      for b <- bars do
        mid_ms = (b.x + b.w / 2 - 7) / 330 * 38_000
        expected = if mid_ms >= 9_000 and mid_ms < 21_000, do: Style.fm(), else: @outside
        assert b.color == expected
      end

      assert Enum.count(bars, &(&1.color == Style.fm())) in 34..36
    end

    test "bars are the loudest of their peaks, normalised, at least 4 %, centred" do
      peaks = [100] ++ List.duplicate(0, 108) ++ [50]
      [first | rest] = bars(Waveform.ops(data(peaks: peaks, duration_ms: 5_500), @w, @h))
      assert first.h == 54.0
      assert first.y == 4.0
      assert_in_delta List.last(rest).h, 27, 0.1
      quiet = Enum.at(rest, 3)
      assert_in_delta quiet.h, 54 * 0.04, 0.1
      assert_in_delta quiet.y + quiet.h / 2, 31, 0.1
    end

    test "selection box and handles straddle the selection's edges" do
      ops = Waveform.ops(data(selection: {0, 19_000}), @w, @h)
      [box, left, right] = white(ops)
      # box: 2 outside the selection, inset 2 dp stroke over the full height
      assert {box.x, box.y, box.h, box.width} == {6.0, 1, 60, 2}
      assert_in_delta box.x + box.w, 7 + 165 + 2 - 1, 0.1
      assert {left.x, left.y, left.w, left.h} == {0.0, 17.0, 10, 28}
      assert_in_delta right.x + 5, 7 + 165 + 2, 0.1
    end

    test "no selection: no box, every bar outside" do
      ops = Waveform.ops(data(selection: nil), @w, @h)
      assert white(ops) == []
      assert Enum.all?(bars(ops), &(&1.color == @outside))
    end

    test "empty peaks draw only the selection" do
      assert bars(Waveform.ops(data(peaks: <<>>), @w, @h)) == []
      assert [_, _, _] = white(Waveform.ops(data(peaks: []), @w, @h))
    end
  end

  describe "hit/5" do
    # selection 9 000..21 000 of 38 000 ms: box edges at x 83.2 and 191.4
    test "handles grab within 12 dp of the box edges" do
      for x <- [72, 83.2, 95] do
        assert Waveform.hit(data(), @w, @h, x, 30) == {:handle, :start}
      end

      for x <- [180, 191.4, 203] do
        assert Waveform.hit(data(), @w, @h, x, 30) == {:handle, :end}
      end
    end

    test "inside the selection grabs the range, outside reports the time" do
      assert {:range, ms} = Waveform.hit(data(), @w, @h, 7 + 165, 30)
      assert ms == 19_000
      assert Waveform.hit(data(), @w, @h, 7, 30) == {:outside, 0}
      assert Waveform.hit(data(), @w, @h, 0, 30) == {:outside, 0}
      assert Waveform.hit(data(), @w, @h, @w, 30) == {:outside, 38_000}
      assert Waveform.hit(data(selection: nil), @w, @h, 90, 30) == {:outside, 9_558}
    end

    test "touches outside the canvas hit nothing" do
      assert Waveform.hit(data(), @w, @h, -1, 30) == :none
      assert Waveform.hit(data(), @w, @h, 100, @h + 1) == :none
    end

    test "a narrow selection gives the nearer handle" do
      d = data(selection: {10_000, 10_500})
      assert Waveform.hit(d, @w, @h, 90, 30) == {:handle, :start}
      assert Waveform.hit(d, @w, @h, 99, 30) == {:handle, :end}
    end

    test "dragging by ms_per_dp follows the finger" do
      dx = 33
      {:range, ms} = Waveform.hit(data(), @w, @h, 120, 30)
      {:range, ms2} = Waveform.hit(data(), @w, @h, 120 + dx, 30)
      assert_in_delta ms + dx * Waveform.ms_per_dp(38_000, @w), ms2, 1
    end
  end

  describe "drag/5" do
    test "moves an edge, stopping min_ms short of the other and at the file ends" do
      assert Waveform.drag({9_000, 21_000}, :start, -1_000, 38_000, 500) == {8_000, 21_000}
      assert Waveform.drag({9_000, 21_000}, :start, -20_000, 38_000, 500) == {0, 21_000}
      assert Waveform.drag({9_000, 21_000}, :start, 20_000, 38_000, 500) == {20_500, 21_000}
      assert Waveform.drag({9_000, 21_000}, :end, 30_000, 38_000, 500) == {9_000, 38_000}
      assert Waveform.drag({9_000, 21_000}, :end, -30_000, 38_000, 500) == {9_000, 9_500}
    end

    test "shifts the range keeping its length inside the file" do
      assert Waveform.drag({9_000, 21_000}, :range, 2_000, 38_000, 500) == {11_000, 23_000}
      assert Waveform.drag({9_000, 21_000}, :range, -10_000, 38_000, 500) == {0, 12_000}
      assert Waveform.drag({9_000, 21_000}, :range, 30_000, 38_000, 500) == {26_000, 38_000}
    end

    test "a minimum longer than the file is capped at the file" do
      assert Waveform.drag({0, 300}, :end, -100, 300, 500) == {0, 300}
    end
  end
end
