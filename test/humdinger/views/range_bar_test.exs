defmodule Humdinger.Views.RangeBarTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.RangeBar

  @w 342

  defp marker(ops), do: Enum.find(ops, &(&1.op == :rect and &1.color == Style.text()))

  defp opacity(ops, m), do: ops |> Enum.at(m - 21) |> Map.get(:opacity, 1)

  test "the marker's left edge follows fractional pitch (board: E2 at round(19 · w/88))" do
    assert RangeBar.marker_x(40, @w) == 73.8
    assert RangeBar.marker_x(40.5, @w) == 75.8
    assert %{x: 75.8, y: 0, w: 3, h: 34} = marker(RangeBar.ops(%{pitch: 40.5}, @w, 46))
  end

  test "the marker clamps at A0 and C8" do
    assert RangeBar.marker_x(10.0, @w) == 0.0
    assert RangeBar.marker_x(21, @w) == 0.0
    assert RangeBar.marker_x(130.0, @w) == 339.0
  end

  test "nil pitch draws no marker" do
    assert marker(RangeBar.ops(%{pitch: nil, low: 40}, @w, 46)) == nil
  end

  test "with only low chosen, keys below it dim" do
    ops = RangeBar.ops(%{pitch: 40.0, low: 40, high: nil}, @w, 46)
    assert opacity(ops, 39) == 0.35
    assert opacity(ops, 40) == 1
    assert opacity(ops, 108) == 1
  end

  test "with both chosen, keys outside low..high dim" do
    ops = RangeBar.ops(%{low: 45, high: 79}, @w, 46)
    assert Enum.map([44, 45, 79, 80], &opacity(ops, &1)) == [0.35, 1, 1, 0.35]
  end

  test "nothing chosen: nothing dims; keys sit below the marker's 6 px" do
    ops = RangeBar.ops(%{}, @w, 46)
    refute ops |> Enum.take(88) |> Enum.any?(&Map.has_key?(&1, :opacity))
    assert %{y: 12, h: 16, color: c} = Enum.at(ops, 0)
    assert c == Style.pitch_color(21)
    assert %{y: 6, h: 12} = Enum.at(ops, 1)
  end

  test "A0 and C8 label the ends" do
    labels = RangeBar.ops(%{}, @w, 46) |> Enum.filter(&(&1.op == :text))
    assert [%{text: "A0", x: 0}, %{text: "C8", x: 342.0, anchor: :end}] = labels
  end
end
