defmodule Humdinger.Views.TuningMeterTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.TuningMeter

  @w 213

  defp marker(ops), do: Enum.find(ops, &(&1.op == :rect and &1.color == Style.text()))

  test "−12 ¢ puts the marker 12/50 of the half-width left of centre" do
    assert TuningMeter.marker_x(-12, @w) == 80.9
    assert %{x: 78.9, w: 4, y: 3, h: 16} = marker(TuningMeter.ops(%{cents: -12.0}, @w, 22))
  end

  test "the marker clamps inside at ±50 ¢ and beyond" do
    assert TuningMeter.marker_x(-50, @w) == 2.0
    assert TuningMeter.marker_x(-80, @w) == 2.0
    assert TuningMeter.marker_x(80, @w) == 211.0
  end

  test "nil cents: track, band and tick only" do
    ops = TuningMeter.ops(%{cents: nil}, @w, 22)
    assert marker(ops) == nil
    assert [_track, _band, _tick] = ops
  end

  test "the in-tune band spans ±tolerance" do
    band = fn tol ->
      TuningMeter.ops(%{cents: 0, tolerance: tol}, @w, 22) |> Enum.find(&(&1.color == Style.fm()))
    end

    assert %{x: 85.2, w: 42.6} = band.(10)
    assert %{x: 63.9, w: 85.2} = band.(20)
  end

  test "caption thresholds" do
    assert TuningMeter.caption(-12.0) == "−12¢ · a little flat"
    assert TuningMeter.caption(0.2) == "0¢ · in tune"
    assert TuningMeter.caption(10) == "+10¢ · in tune"
    assert TuningMeter.caption(-10.4) == "−10¢ · a little flat"
    assert TuningMeter.caption(25) == "+25¢ · a little sharp"
    assert TuningMeter.caption(26) == "+26¢ · sharp"
    assert TuningMeter.caption(-30) == "−30¢ · flat"
    assert TuningMeter.caption(15, 20) == "+15¢ · in tune"
    assert TuningMeter.caption(nil) == ""
  end

  test "velocity label" do
    assert TuningMeter.velocity_label(92) == "vel 92"
    assert TuningMeter.velocity_label(nil) == ""
  end
end
