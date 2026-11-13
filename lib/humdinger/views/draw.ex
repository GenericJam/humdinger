defmodule Humdinger.Views.Draw do
  @moduledoc """
  Small helpers the views share. `Mob.Canvas` paths are polylines, so the
  boards' Bézier curves are flattened here; canvas text can't be measured
  from Elixir, so its width is estimated (MOB-513).
  """

  @typedoc "A point in canvas units."
  @type point :: {number(), number()}

  # Mob canvas text has no measuring call; ~0.56 em per character is close
  # for Inter, JetBrains Mono and Roboto at the sizes the boards use.
  @em_per_char 0.56

  @doc "Estimated width of `text` drawn at `size` (≈ 0.56 em per character)."
  @spec text_width(String.t(), number()) :: float()
  def text_width(text, size), do: String.length(text) * size * @em_per_char

  @doc "Points along a cubic Bézier from `p0` to `p3`, both ends included."
  @spec cubic(point(), point(), point(), point(), pos_integer()) :: [point()]
  def cubic({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}, segments \\ 10) do
    for i <- 0..segments do
      t = i / segments
      u = 1 - t
      a = u * u * u
      b = 3 * u * u * t
      c = 3 * u * t * t
      d = t * t * t
      {a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3}
    end
  end

  @doc "Points along a quadratic Bézier from `p0` to `p2`, both ends included."
  @spec quad(point(), point(), point(), pos_integer()) :: [point()]
  def quad({x0, y0}, {x1, y1}, {x2, y2}, segments \\ 8) do
    for i <- 0..segments do
      t = i / segments
      u = 1 - t
      {u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2}
    end
  end

  @doc """
  Points around an ellipse centred at `{cx, cy}`, starting at angle 0 (to
  the right) and going clockwise on screen. For shapes `Mob.Canvas.ellipse/5`
  can't draw: rotated or clipped ones.
  """
  @spec ellipse_points(point(), number(), number(), pos_integer()) :: [point()]
  def ellipse_points({cx, cy}, rx, ry, segments \\ 16) do
    for i <- 0..(segments - 1) do
      a = 2 * :math.pi() * i / segments
      {cx + rx * :math.cos(a), cy + ry * :math.sin(a)}
    end
  end

  @doc "Scale and offset points: `{x, y}` → `{ox + x·s, oy + y·s}`."
  @spec place([point()], number(), number(), number()) :: [point()]
  def place(points, ox, oy, s), do: Enum.map(points, fn {x, y} -> {ox + x * s, oy + y * s} end)

  @doc "Round to one decimal (keeps op payloads small; sub-dp precision is invisible)."
  @spec r1(number()) :: float()
  def r1(v), do: Float.round(v * 1.0, 1)

  @doc "Clamp `v` into `lo..hi`."
  @spec clamp(number(), number(), number()) :: number()
  def clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
