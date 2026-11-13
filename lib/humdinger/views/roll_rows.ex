defmodule Humdinger.Views.RollRows do
  @moduledoc """
  Pieces `Humdinger.Views.PitchRoll` and `Humdinger.Views.PianoRoll` share:
  the rounded box, full-width row bands that stay inside its rounded corners,
  row labels and the faint sung line.

  The boards draw rows inside a rounded box with `overflow: hidden`. Mob's
  canvas clips only to its rectangle, so a band that reaches into a corner
  is drawn as a polygon following the corner's arc instead of a rect.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @row_a 0xFF221F2D
  @row_b 0xFF1F1C29
  @row_out 0xFF17151E

  @doc "In-scale row background: #221F2D for even `n`, #1F1C29 for odd (the boards' stripes)."
  @spec stripe(integer()) :: integer()
  def stripe(n), do: if(rem(n, 2) == 0, do: @row_a, else: @row_b)

  @doc "Background of a row whose note is outside the scale (Live)."
  @spec out_of_scale :: integer()
  def out_of_scale, do: @row_out

  @doc "The box: a `w`×`h` rect, corner radius `r`, in `Style.surface/0`."
  @spec box(number(), number(), number()) :: map()
  def box(w, h, r), do: rect(0, 0, w, h, color: Style.surface(), fill: true, radius: r)

  @doc """
  How far the box's left (or right) edge sits inside the canvas at height
  `y`, for a box `h` high with corner radius `r`.
  """
  @spec inset(number(), number(), number()) :: float()
  def inset(y, h, r) do
    dy =
      cond do
        y < r -> r - y
        y > h - r -> y - (h - r)
        true -> 0
      end

    dy = min(dy, r)
    r - :math.sqrt(max(r * r - dy * dy, 0.0))
  end

  @doc """
  A full-width band from `y` to `y + bh` in `color`, clipped to the canvas
  and to the rounded box (`w`×`h`, radius `r`). `[]` when nothing of it is
  visible.
  """
  @spec band(number(), number(), number(), number(), number(), integer()) :: [map()]
  def band(y, bh, w, h, r, color) do
    y0 = max(y, 0)
    y1 = min(y + bh, h)

    cond do
      y1 <= y0 ->
        []

      y0 >= r and y1 <= h - r ->
        [rect(Draw.r1(0), Draw.r1(y0), w, Draw.r1(y1 - y0), color: color, fill: true)]

      true ->
        ys = band_samples(y0, y1, h, r)
        left = Enum.map(ys, &{Draw.r1(inset(&1, h, r)), Draw.r1(&1)})
        right = ys |> Enum.reverse() |> Enum.map(&{Draw.r1(w - inset(&1, h, r)), Draw.r1(&1)})
        [path(left ++ right, color: color, fill: true, closed: true)]
    end
  end

  # The band's edges plus a point every 2 dp where it crosses a corner.
  defp band_samples(y0, y1, h, r) do
    steps = Enum.to_list(0..trunc(r)//2)
    corner = Enum.filter(steps ++ Enum.map(steps, &(h - &1)), &(&1 > y0 and &1 < y1))

    Enum.sort(Enum.uniq([y0, y1 | corner]))
  end

  @doc "A row label (JetBrains Mono 600) with its top at `y`."
  @spec label(number(), number(), String.t(), number(), integer()) :: map()
  def label(x, y, name, size, color) do
    text(Draw.r1(x), Draw.r1(y), name,
      color: color,
      size: size,
      weight: :semibold,
      family: Style.font_family(:mono_semibold)
    )
  end

  @doc """
  Polyline runs of a pitch trace: `samples` are `{t_ms, pitch | nil}` in
  time order, `x_of`/`y_of` map time and pitch to canvas units. A `nil`
  pitch breaks the line. Points closer than 1 dp in x to the previous kept
  one are skipped (a trace has up to 100 samples a second).
  """
  @spec runs([{number(), number() | nil}], (number() -> number()), (number() -> number())) ::
          [[Draw.point()]]
  def runs(samples, x_of, y_of) do
    samples
    |> Enum.chunk_by(fn {_t, p} -> is_nil(p) end)
    |> Enum.reject(fn [{_t, p} | _] -> is_nil(p) end)
    |> Enum.map(fn run ->
      run
      |> Enum.map(fn {t, p} -> {Draw.r1(x_of.(t)), Draw.r1(y_of.(p))} end)
      |> thin()
    end)
  end

  defp thin([first | rest]) do
    {kept, last} =
      Enum.reduce(rest, {[first], first}, fn {x, _} = pt, {[{kx, _} | _] = acc, _seen} ->
        if abs(x - kx) >= 1, do: {[pt | acc], pt}, else: {acc, pt}
      end)

    kept = if hd(kept) == last, do: kept, else: [last | kept]
    Enum.reverse(kept)
  end

  @doc """
  Ops for trace runs: a path per run of two or more points, a dot for a
  lone point; runs entirely outside the `w`×`h` canvas are dropped.
  """
  @spec trace_ops([[Draw.point()]], number(), number(), keyword()) :: [map()]
  def trace_ops(runs, w, h, opts) do
    width = Keyword.fetch!(opts, :width)
    style = [color: Style.text(), width: width, cap: :round, join: :round]
    style = if o = opts[:opacity], do: Keyword.put(style, :opacity, o), else: style

    for run <- runs, visible?(run, w, h, width) do
      case run do
        [{x, y}] ->
          circle(x, y, width / 2, [{:fill, true} | style])

        pts ->
          path(pts, style)
      end
    end
  end

  defp visible?(pts, w, h, pad) do
    {xs, ys} = Enum.unzip(pts)

    Enum.max(xs) >= -pad and Enum.min(xs) <= w + pad and Enum.max(ys) >= -pad and
      Enum.min(ys) <= h + pad
  end
end
