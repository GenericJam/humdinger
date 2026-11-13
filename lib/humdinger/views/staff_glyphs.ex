defmodule Humdinger.Views.StaffGlyphs.Shape do
  @moduledoc false
  # Polygon helpers for the engraved music symbols: smoothed variable-width
  # strokes ("ribbons") and several polygons merged into one fillable path.

  alias Humdinger.Views.Draw

  @typep point :: {float(), float()}
  @typep control :: {number(), number(), number()}

  @doc "One pass of Chaikin corner cutting over `{x, y, width}` controls (ends kept)."
  @spec chaikin([control()]) :: [control()]
  def chaikin([_, _ | _] = pts) do
    cut =
      pts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [a, b] -> [lerp(a, b, 0.25), lerp(a, b, 0.75)] end)

    [hd(pts) | cut] ++ [List.last(pts)]
  end

  def chaikin(pts), do: pts

  @doc """
  The outline of a stroke along `controls` (`{x, y, width}`), smoothed by
  `passes` of Chaikin: the left edge forward, then the right edge back. The
  width varies along the stroke, which is what makes the symbols look
  engraved rather than drawn with a pen of constant width.
  """
  @spec ribbon([control()], non_neg_integer()) :: [point()]
  def ribbon(controls, passes) do
    floats = Enum.map(controls, fn {x, y, w} -> {x * 1.0, y * 1.0, w * 1.0} end)
    pts = Enum.reduce(1..passes//1, floats, fn _, acc -> chaikin(acc) end)

    arr = List.to_tuple(pts)
    n = tuple_size(arr)

    {left, right} =
      0..(n - 1)
      |> Enum.map(fn i ->
        {xa, ya, _} = elem(arr, max(i - 1, 0))
        {xb, yb, _} = elem(arr, min(i + 1, n - 1))
        {x, y, w} = elem(arr, i)
        dx = xb - xa
        dy = yb - ya
        len = max(:math.sqrt(dx * dx + dy * dy), 1.0e-6)
        nx = -dy / len * w / 2
        ny = dx / len * w / 2
        {{x + nx, y + ny}, {x - nx, y - ny}}
      end)
      |> Enum.unzip()

    left ++ Enum.reverse(right)
  end

  @doc "A filled disc as a polygon."
  @spec disc(number(), number(), number()) :: [point()]
  def disc(cx, cy, r), do: Draw.ellipse_points({cx * 1.0, cy * 1.0}, r, r, 14)

  @doc "A filled ellipse as a polygon."
  @spec oval(number(), number(), number(), number()) :: [point()]
  def oval(cx, cy, rx, ry), do: Draw.ellipse_points({cx * 1.0, cy * 1.0}, rx, ry, 16)

  @doc "A quadrilateral of `thickness` (measured vertically) from `{x1, y1}` to `{x2, y2}`."
  @spec slab(number(), number(), number(), number(), number()) :: [point()]
  def slab(x1, y1, x2, y2, thickness) do
    h = thickness / 2
    [{x1, y1 - h}, {x2, y2 - h}, {x2, y2 + h}, {x1, y1 + h}]
  end

  @doc "An axis-aligned rectangle as a polygon."
  @spec box(number(), number(), number(), number()) :: [point()]
  def box(x, y, w, h), do: [{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}]

  @doc """
  Several polygons as one path. Every part is turned the same way round and
  joined to the first through a spoke drawn there and back, so non-zero
  filling (Android's and SVG's default) paints their union and the spokes
  enclose nothing. One op per symbol keeps frames small.
  """
  @spec compound([[point()]]) :: [point()]
  def compound([first | rest]) do
    first = orient(first)
    hub = hd(first)
    first ++ [hub | Enum.flat_map(rest, &spoke(orient(&1), hub))]
  end

  defp spoke(poly, hub), do: poly ++ [hd(poly), hub]

  @doc "Translate points by `{dx, dy}` and round them to 0.1."
  @spec at([point()], number(), number()) :: [point()]
  def at(points, dx, dy),
    do: Enum.map(points, fn {x, y} -> {Draw.r1(x + dx), Draw.r1(y + dy)} end)

  @doc "Mirror points vertically about y = 0."
  @spec flip([point()]) :: [point()]
  def flip(points), do: Enum.map(points, fn {x, y} -> {x, -y} end)

  defp orient(poly), do: if(area(poly) < 0, do: Enum.reverse(poly), else: poly)

  defp area(poly) do
    poly
    |> Enum.zip(tl(poly) ++ [hd(poly)])
    |> Enum.reduce(0.0, fn {{x1, y1}, {x2, y2}}, acc -> acc + x1 * y2 - x2 * y1 end)
  end

  defp lerp({x0, y0, w0}, {x1, y1, w1}, t),
    do: {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, w0 + (w1 - w0) * t}
end

defmodule Humdinger.Views.StaffGlyphs do
  @moduledoc """
  Music symbols for `Humdinger.Views.Staff`, drawn as filled polygons: one
  `path` op per symbol. Android's canvas ignores `family:`, so the board's
  music font (Noto Music) is unavailable and clefs, accidentals, rests and
  flags are traced here instead, sized for a 12-unit staff space like the
  sheet music board (`design/boards/10-sheet_music.html`).

  Strokes are variable-width ribbons smoothed with Chaikin corner cutting
  (the treble clef follows the one proven in choir_coach's practice view,
  refined against the board's Noto Music glyph). Geometry is computed at
  compile time; drawing only translates it.
  """

  import Mob.Canvas

  alias Humdinger.Views.Draw
  alias Humdinger.Views.StaffGlyphs.Shape

  # ── Clefs ───────────────────────────────────────────────────────────────
  # Coordinates from the start barline (x) and the staff's top line (y),
  # staff space 12. Treble: traced from the board's Noto Music G clef. The
  # stroke starts at the end of the inner curl, spirals out round the belly
  # (centred on the middle line), climbs diagonally to the loop above the
  # staff, comes back down its left side and falls through the belly as the
  # thin descender, ending in the tail and its ball.
  @treble Shape.compound([
            Shape.ribbon(
              [
                {21.5, 30.0, 1.4},
                {18.0, 27.0, 3.0},
                {16.2, 22.0, 4.2},
                {17.0, 17.0, 3.6},
                {21.0, 14.0, 2.6},
                {27.0, 13.2, 2.4},
                {32.0, 15.5, 3.4},
                {34.6, 21.5, 4.8},
                {33.0, 28.0, 4.4},
                {29.0, 32.6, 2.6},
                {22.5, 34.3, 2.0},
                {15.5, 33.0, 2.4},
                {11.0, 29.5, 3.4},
                {8.6, 24.0, 4.4},
                {8.8, 17.0, 4.6},
                {10.5, 12.0, 5.0},
                {13.5, 7.0, 5.6},
                {18.0, 2.5, 5.4},
                {22.5, -2.0, 5.0},
                {26.0, -7.0, 4.6},
                {27.6, -13.0, 3.6},
                {27.4, -19.5, 2.6},
                {26.2, -25.0, 2.0},
                {24.2, -27.6, 1.8},
                {21.5, -25.0, 3.4},
                {20.0, -20.0, 4.8},
                {19.4, -14.0, 3.4},
                {18.8, -8.0, 2.4},
                {19.6, -2.0, 2.4},
                {21.0, 5.0, 2.4},
                {22.4, 13.0, 2.4},
                {23.4, 21.0, 2.4},
                {25.0, 30.0, 2.4},
                {26.6, 39.0, 2.4},
                {27.0, 46.0, 2.4},
                {26.0, 51.0, 2.4},
                {22.5, 53.6, 2.0},
                {19.0, 52.0, 1.6}
              ],
              3
            ),
            Shape.disc(16.8, 47.8, 5.0)
          ])

  # Bass: the ball on the F line (2nd from the top), the arc over and down
  # to the 2nd line from the bottom, the two dots either side of the F line.
  @bass Shape.compound([
          Shape.ribbon(
            [
              {8.0, 10.0, 2.0},
              {10.0, 4.0, 2.4},
              {16.0, 0.8, 3.0},
              {23.0, 2.6, 4.4},
              {26.5, 10.0, 5.2},
              {25.5, 19.0, 5.0},
              {20.0, 28.0, 3.6},
              {12.0, 35.0, 2.2},
              {5.0, 39.0, 1.0}
            ],
            3
          ),
          Shape.disc(10.5, 12.0, 4.6),
          Shape.disc(33.0, 6.0, 2.2),
          Shape.disc(33.0, 18.0, 2.2)
        ])

  # ── Accidentals (centred on {0, 0} = the note's line or space) ──────────
  @sharp Shape.compound([
           Shape.box(-3.3, -11.0, 1.3, 23.0),
           Shape.box(2.0, -12.5, 1.3, 23.0),
           Shape.slab(-5.0, -2.8, 5.0, -5.6, 3.0),
           Shape.slab(-5.0, 5.6, 5.0, 2.8, 3.0)
         ])

  @flat Shape.compound([
          Shape.box(-4.0, -16.0, 1.4, 21.8),
          Shape.ribbon(
            [
              {-3.4, -1.8, 1.0},
              {0.0, -4.6, 1.6},
              {3.6, -4.2, 2.4},
              {3.8, -0.5, 2.6},
              {0.5, 3.0, 2.0},
              {-3.4, 5.6, 1.0}
            ],
            3
          )
        ])

  @natural Shape.compound([
             Shape.box(-3.6, -13.0, 1.3, 18.5),
             Shape.box(2.3, -5.5, 1.3, 18.5),
             Shape.slab(-3.6, -1.6, 3.6, -4.0, 2.8),
             Shape.slab(-3.6, 4.0, 3.6, 1.6, 2.8)
           ])

  # ── Rests ───────────────────────────────────────────────────────────────
  # Quarter: from {0, 0} = the middle line, spanning about three spaces: a
  # thin stroke down to the right, the thick zig-zag, and the hook below.
  @quarter_rest Shape.ribbon(
                  [
                    {-2.4, -17.5, 1.4},
                    {3.4, -10.0, 3.6},
                    {3.4, -10.0, 3.6},
                    {-2.6, -3.0, 4.2},
                    {-2.6, -3.0, 4.2},
                    {3.4, 4.2, 3.4},
                    {3.4, 4.2, 3.4},
                    {-1.0, 6.0, 2.4},
                    {-3.0, 10.5, 2.2},
                    {0.8, 16.0, 1.4}
                  ],
                  2
                )

  # Eighth and sixteenth: from {0, 0} = the middle line. The eighth matches
  # the board's (ball in the 3rd space, stem down to the middle line); the
  # sixteenth adds a second ball a space lower.
  @eighth_rest Shape.compound([
                 Shape.ribbon(
                   [{-2.6, -9.0, 1.3}, {0.6, -8.6, 1.6}, {4.0, -11.8, 1.5}, {-0.4, 2.6, 1.5}],
                   1
                 ),
                 Shape.disc(-2.4, -10.6, 2.4)
               ])

  @sixteenth_rest Shape.compound([
                    Shape.ribbon(
                      [{-1.6, -9.0, 1.3}, {1.6, -8.6, 1.6}, {5.0, -11.8, 1.5}, {-2.0, 13.0, 1.5}],
                      1
                    ),
                    Shape.disc(-1.4, -10.6, 2.4),
                    Shape.ribbon([{-4.2, 1.0, 1.3}, {-1.0, 1.4, 1.6}, {2.2, -1.8, 1.5}], 1),
                    Shape.disc(-4.0, -0.6, 2.4)
                  ])

  # ── Flags: from {0, 0} = the end of an up stem (centre), hanging right ──
  @flag Shape.ribbon(
          [
            {0.0, 0.0, 2.6},
            {1.0, 5.0, 3.2},
            {6.0, 11.0, 3.0},
            {10.0, 17.5, 2.4},
            {10.0, 23.5, 1.6},
            {7.0, 29.0, 1.0}
          ],
          3
        )
  @flag_down Shape.flip(@flag)
  # Sixteenths stack two flags 9 apart; shorter ones keep them distinct.
  @flag_short Enum.map(@flag, fn {x, y} -> {x, y * 0.7} end)
  @flag_short_down Shape.flip(@flag_short)

  @doc "Treble clef for a staff whose start barline is at `x` and top line at `top`."
  @spec treble_clef(number(), number(), integer()) :: map()
  def treble_clef(x, top, color), do: fill(@treble, x, top, color)

  @doc "Bass clef for a staff whose start barline is at `x` and top line at `top`."
  @spec bass_clef(number(), number(), integer()) :: map()
  def bass_clef(x, top, color), do: fill(@bass, x, top, color)

  @doc "A sharp, flat or natural centred at `x` on the line or space at `y`."
  @spec accidental(:sharp | :flat | :natural, number(), number(), integer()) :: map()
  def accidental(:sharp, x, y, color), do: fill(@sharp, x, y, color)
  def accidental(:flat, x, y, color), do: fill(@flat, x, y, color)
  def accidental(:natural, x, y, color), do: fill(@natural, x, y, color)

  @doc """
  A quarter, eighth or sixteenth rest centred on `x`. `mid_y` is the
  staff's middle line.
  """
  @spec rest(:quarter | :eighth | :sixteenth, number(), number(), integer()) :: map()
  def rest(:quarter, x, mid_y, color), do: fill(@quarter_rest, x, mid_y, color)
  def rest(:eighth, x, mid_y, color), do: fill(@eighth_rest, x, mid_y, color)
  def rest(:sixteenth, x, mid_y, color), do: fill(@sixteenth_rest, x, mid_y, color)

  @doc """
  A flag on the end of a stem at `{x, y}` (stem centre), for an `:up` or
  `:down` stem. `:short` flags are the sixteenth's pair.
  """
  @spec flag(number(), number(), :up | :down, integer(), :long | :short) :: map()
  def flag(x, y, dir, color, length \\ :long)
  def flag(x, y, :up, color, :long), do: fill(@flag, x, y, color)
  def flag(x, y, :down, color, :long), do: fill(@flag_down, x, y, color)
  def flag(x, y, :up, color, :short), do: fill(@flag_short, x, y, color)
  def flag(x, y, :down, color, :short), do: fill(@flag_short_down, x, y, color)

  @doc """
  A tie from `{x1, y}` to `{x2, y}`, curving `:above` or `:below`: a
  crescent, thickest in the middle and tapering to the ends.
  """
  @spec tie(number(), number(), number(), :above | :below, integer()) :: map()
  def tie(x1, x2, y, side, color) do
    sign = if side == :above, do: -1, else: 1
    h = min(4.0 + (x2 - x1) * 0.04, 8.0)
    mx = (x1 + x2) / 2
    outer = Draw.quad({x1, y}, {mx, y + sign * 2 * h}, {x2, y}, 12)
    inner = Draw.quad({x2, y}, {mx, y + sign * 2 * (h - 1.8)}, {x1, y}, 12)
    path(Shape.at(outer ++ tl(inner), 0, 0), color: color, fill: true)
  end

  defp fill(points, x, y, color), do: path(Shape.at(points, x, y), color: color, fill: true)
end
