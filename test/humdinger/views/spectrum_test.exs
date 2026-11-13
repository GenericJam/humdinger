defmodule Humdinger.Views.SpectrumTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Audio, Music, Style}
  alias Humdinger.Views.Spectrum

  @w 350
  @h 470
  @ramp [0xFF2A2240, 0xFF3E2F7A, 0xFF6A52C9, 0xFFB9A2FF, 0xFFF3EFF8]

  defp bins(fun), do: for(i <- 0..127, into: <<>>, do: <<fun.(i)>>)

  defp data(columns, opts \\ []) do
    Map.merge(%{columns: columns, trace: [], now_ms: 4000, pitch: nil}, Map.new(opts))
  end

  defp cells(ops), do: Enum.filter(ops, &(&1.op == :rect and &1.color in @ramp))
  defp texts(ops), do: Enum.filter(ops, &(&1.op == :text))
  defp text_y(ops, label), do: Enum.find(texts(ops), &(&1.text == label)).y

  describe "shade/1" do
    test "silence draws nothing, full scale is the brightest ramp colour" do
      assert Spectrum.shade(0) == nil
      assert Spectrum.shade(255) == 0xFFF3EFF8
    end

    test "louder levels never map to a darker shade" do
      ranks = for l <- 0..255, do: Enum.find_index([nil | @ramp], &(&1 == Spectrum.shade(l)))
      assert ranks == Enum.sort(ranks)
      assert Enum.uniq(ranks) == [0, 1, 2, 3, 4, 5]
    end
  end

  describe "ops/3 cells" do
    test "a bin at 100 Hz sits under the 100 axis label" do
      i = 20 * :math.log2(100 / 50)
      assert Audio.bin_hz(round(i)) == 100.0
      cols = [%{t: 0, bins: bins(fn b -> if b == 20, do: 255, else: 0 end)}]
      ops = Spectrum.ops(data(cols, now_ms: 33, window_ms: 33), @w, @h)

      [cell] = cells(ops)
      centre = cell.y + (cell.h - 0.5) / 2
      assert_in_delta centre, Spectrum.y_of_hz(100, @h), 0.2
      # label top is y(f) − 5: a 10-high label centred on the row
      assert_in_delta text_y(ops, "100") + 5, centre, 0.7
    end

    test "a uniform column becomes one rect spanning 80..2400 Hz" do
      cols = [%{t: 3967, bins: bins(fn _ -> 200 end)}]
      [cell] = cells(Spectrum.ops(data(cols), @w, @h))
      assert cell.color == 0xFFF3EFF8
      # rows end at the half-way edges of the outermost in-range bins
      assert cell.y >= 0 and cell.y < 5
      assert cell.y + cell.h > @h - 5 and cell.y + cell.h <= @h + 0.6
    end

    test "bins outside 80..2400 Hz are dropped" do
      loud_outside =
        bins(fn i -> if Audio.bin_hz(i) < 80 or Audio.bin_hz(i) > 2400, do: 255, else: 0 end)

      assert cells(Spectrum.ops(data([%{t: 3967, bins: loud_outside}]), @w, @h)) == []
    end

    test "columns sit at their time and are as wide as the gap to the next" do
      level = bins(fn i -> if i == 40, do: 200, else: 0 end)
      other = bins(fn i -> if i == 80, do: 200, else: 0 end)

      cols = [
        %{t: 2000, bins: level},
        %{t: 3000, bins: other},
        %{t: 3100, bins: other},
        %{t: 3200, bins: level}
      ]

      ops = Spectrum.ops(data(cols), @w, @h)
      [a, c] = ops |> cells() |> Enum.filter(&(&1.y > 200)) |> Enum.sort_by(& &1.x)
      [b] = ops |> cells() |> Enum.filter(&(&1.y < 200))
      assert a.x == 175.0
      assert_in_delta a.w, 87.5 + 0.5, 0.1
      # two equal columns in a row draw one rect
      assert b.x == 262.5
      assert_in_delta b.w, 17.5 + 0.5, 0.1
      # the newest column is as wide as the median gap (100 ms)
      assert c.x == 280.0
      assert_in_delta c.w, 8.75 + 0.5, 0.1
    end

    test "an unchanged run in consecutive columns is drawn once" do
      level = bins(fn i -> if i in 40..44, do: 150, else: 0 end)
      cols = for t <- 0..3966//33, do: %{t: t, bins: level}
      assert [cell] = cells(Spectrum.ops(data(cols), @w, @h))
      assert cell.x == 0.0
      assert_in_delta cell.x + cell.w, @w, 0.6
    end

    test "columns older than the window are skipped" do
      cols = [%{t: -100, bins: bins(fn _ -> 255 end)}, %{t: -50, bins: bins(fn _ -> 255 end)}]
      assert cells(Spectrum.ops(data(cols), @w, @h)) == []
    end

    test "a custom bins_hz list maps rows" do
      hz = for i <- 0..127, do: 100 * :math.pow(2, i / 10)
      cols = [%{t: 3967, bins: bins(fn i -> if i == 0, do: 255, else: 0 end)}]
      [cell] = cells(Spectrum.ops(data(cols, bins_hz: hz), @w, @h))
      assert_in_delta cell.y + (cell.h - 0.5) / 2, Spectrum.y_of_hz(100, @h), 0.2
    end
  end

  describe "ops/3 overlays" do
    test "axis labels sit at y(f) − 5" do
      ops = Spectrum.ops(data([]), @w, @h)

      for {f, label} <- [{100, "100"}, {800, "800"}, {1600, "1.6k"}] do
        assert text_y(ops, label) == Float.round(Spectrum.y_of_hz(f, @h) - 5)
        assert Enum.find(texts(ops), &(&1.text == label)).x == 6
      end
    end

    test "harmonic chips sit at y(k · f0) − 8, right-aligned 8 from the edge" do
      ops = Spectrum.ops(data([], pitch: 69.0), @w, @h)

      for {k, label} <- [{1, "note"}, {2, "×2"}, {3, "×3"}] do
        y = Float.round(Spectrum.y_of_hz(440 * k, @h) - 8)
        assert text_y(ops, label) == y + 2
        pad = Enum.find(ops, &(&1.op == :rect and &1.y == y and &1.color == Style.bg()))
        assert_in_delta pad.x + pad.w, @w - 8, 0.1
      end

      assert Enum.find(texts(ops), &(&1.text == "note")).color == Style.text()
    end

    test "chips that would leave the box are dropped" do
      # ×3 of 1000 Hz is above 2400 Hz
      ops = Spectrum.ops(data([], pitch: Music.hz_to_midi(1000)), @w, @h)
      labels = Enum.map(texts(ops), & &1.text)
      assert "note" in labels and "×2" in labels
      refute "×3" in labels
    end

    test "chips that would overlap are dropped" do
      # in a short box the harmonics are only a few dp apart
      ops = Spectrum.ops(data([], pitch: 69.0), 200, 60)
      labels = for t <- texts(ops), t.text in ["note", "×2", "×3"], do: {t.text, t.y}
      # ×2 would overlap the note chip; ×3 clears it
      assert Enum.map(labels, &elem(&1, 0)) == ["note", "×3"]
      [{_, note}, {_, x3}] = labels
      assert note - x3 >= 14
    end

    test "the trace is drawn in the current pitch's colour and breaks on silence" do
      trace = [{1000, 60.0}, {1100, 60.2}, {1200, nil}, {2000, 67.0}, {2100, 67.1}]
      ops = Spectrum.ops(data([], trace: trace, pitch: 67.4), @w, @h)
      paths = Enum.filter(ops, &(&1.op == :path and &1[:width] == 3))
      assert [_, _] = paths
      assert Enum.all?(paths, &(&1.color == Style.pitch_color(67)))
      [[x, y] | _] = hd(paths).points
      assert x == 87.5
      assert_in_delta y, Spectrum.y_of_hz(Music.midi_to_hz(60.0), @h), 0.1
    end

    test "without a current pitch the trace keeps its last heard colour and no chips show" do
      ops = Spectrum.ops(data([], trace: [{3000, 57.0}, {3100, 57.0}, {3200, nil}]), @w, @h)
      assert [%{color: color}] = Enum.filter(ops, &(&1.op == :path and &1[:width] == 3))
      assert color == Style.pitch_color(57)
      refute Enum.any?(texts(ops), &(&1.text == "note"))
    end

    test "empty data draws the box and axis only" do
      ops = Spectrum.ops(%{columns: [], trace: [], now_ms: 0, pitch: nil}, @w, @h)

      assert hd(ops) ==
               Mob.Canvas.rect(0, 0, @w, @h, color: Style.surface(), fill: true, radius: 16)

      assert cells(ops) == []
      assert Enum.map(texts(ops), & &1.text) == ["100", "200", "400", "800", "1.6k"]
    end

    test "malformed bins draw nothing for the missing levels" do
      cols = [%{t: 3967, bins: <<255, 255>>}, %{t: 3990, bins: nil}]
      assert cells(Spectrum.ops(data(cols), @w, @h)) == []
    end
  end

  test "legend draws the five ramp squares quiet → loud" do
    ops = Spectrum.legend_ops(100, 10)

    assert Enum.map(ops, &{&1.x, &1.w, &1.h, &1.color}) ==
             Enum.map(Enum.with_index(@ramp), fn {c, i} -> {i * 20, 18, 10, c} end)
  end
end
