defmodule Humdinger.Views.QrFrameTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.QrFrame

  defp brackets(ops), do: Enum.filter(ops, &(&1.color == Style.fm()))

  test "corner bars at the board's positions in a 350 × 300 box" do
    expected = [
      {70.0, 40.0, 30.0, 5.0},
      {70.0, 40.0, 5.0, 30.0},
      {250.0, 40.0, 30.0, 5.0},
      {275.0, 40.0, 5.0, 30.0},
      {70.0, 245.0, 30.0, 5.0},
      {70.0, 220.0, 5.0, 30.0},
      {250.0, 245.0, 30.0, 5.0},
      {275.0, 220.0, 5.0, 30.0}
    ]

    bars = brackets(QrFrame.ops(%{state: :scanning}, 350, 300))
    assert Enum.map(bars, &{&1.x, &1.y, &1.w, &1.h}) == expected
    assert Enum.all?(bars, &(&1.fill and &1.radius == 2))
  end

  test "the square follows the shorter side" do
    assert QrFrame.square(350, 300) == {70.0, 40.0, 210.0}
    assert {left, _top, 140.0} = QrFrame.square(200, 400)
    assert left == 30.0
  end

  test "found adds a lime fill and ring inside the brackets" do
    scanning = QrFrame.ops(%{state: :scanning}, 350, 300)
    found = QrFrame.ops(%{state: :found}, 350, 300)
    assert brackets(found) == scanning
    [fill, ring] = found -- scanning
    assert fill.fill and not Map.has_key?(ring, :fill)
    assert fill.x > 75 and fill.x + fill.w < 275
  end
end
