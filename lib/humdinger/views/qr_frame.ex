defmodule Humdinger.Views.QrFrame do
  @moduledoc """
  The Pair screen's viewfinder overlay (board `11-pair`): lime corner
  brackets around the square the code should fill, drawn over the camera
  preview (the canvas is otherwise transparent).

  On the board's 350 × 300 box the square is 210 wide at left 70, top 40
  (5 above centre, leaving room for the "Point at the code" hint at the
  bottom left); each bracket is two `Style.fm/0` bars 30 long and 5 thick
  with radius 2. At other sizes the square is 0.7 × min(w, h), centred
  horizontally and 5/210 of its side above centre, and the bars scale with
  it.

  `state: :found` adds a soft lime fill and a ring just inside the brackets
  so the screen can confirm a hit before it moves on; any other state draws
  the brackets alone.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @type data :: %{state: :scanning | :found}

  @doc "Ops for the overlay in a `w` × `h` canvas (board: 350 × 300)."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    {left, top, side} = square(w, h)
    arm = side / 7
    bar = max(side / 42, 3)
    right = left + side
    bottom = top + side

    brackets =
      [
        {left, top, arm, bar},
        {left, top, bar, arm},
        {right - arm, top, arm, bar},
        {right - bar, top, bar, arm},
        {left, bottom - bar, arm, bar},
        {left, bottom - arm, bar, arm},
        {right - arm, bottom - bar, arm, bar},
        {right - bar, bottom - arm, bar, arm}
      ]
      |> Enum.map(fn {x, y, rw, rh} ->
        rect(Draw.r1(x), Draw.r1(y), Draw.r1(rw), Draw.r1(rh),
          color: Style.fm(),
          fill: true,
          radius: 2
        )
      end)

    if Map.get(data, :state) == :found,
      do: found(left, top, side, bar) ++ brackets,
      else: brackets
  end

  @doc "The target square `{left, top, side}` in a `w` × `h` canvas."
  @spec square(number(), number()) :: {float(), float(), float()}
  def square(w, h) do
    side = 0.7 * min(w, h)
    {Draw.r1((w - side) / 2), Draw.r1((h - side) / 2 - side * 5 / 210), Draw.r1(side)}
  end

  defp found(left, top, side, bar) do
    inset = bar + 4
    x = Draw.r1(left + inset)
    y = Draw.r1(top + inset)
    s = Draw.r1(side - 2 * inset)

    [
      rect(x, y, s, s, color: Style.alpha(Style.fm(), 0.14), fill: true, radius: 8),
      rect(x, y, s, s, color: Style.alpha(Style.fm(), 0.7), width: 2, radius: 8)
    ]
  end
end
