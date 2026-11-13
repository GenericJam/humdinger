# Renders Mob.Canvas ops on the host: ops → SVG → PNG, so views can be
# compared with design/shots/* without a phone. Rasterises with libvips
# (the `image` dev dependency: `Image.from_svg/2`, librsvg inside), so it
# runs in dev only. Load it from a script or IEx:
#
#     Code.require_file("scripts/canvas_svg.exs")
#     CanvasSvg.render([{"mimi", 220, 192, ops}], "/tmp/mimi.png")
#
# `render/3` lays the scenes out on one captioned sheet at 2x; `png/5` writes
# one scene at its exact size with a transparent background (icons). Text
# follows Android's canvas renderer, which ignores `family:`: a system
# sans-serif, bold for :medium and heavier. `scripts/preview_views.exs`
# renders every scene of Humdinger.GalleryScreen.

defmodule CanvasSvg do
  import Bitwise

  # Where the text's top sits above its baseline, as a fraction of its size.
  # Mob draws canvas text with y at the top (Android: baseline − ascent).
  @ascent 0.93
  @sans "Roboto, Helvetica Neue, Helvetica, Arial, sans-serif"
  @gap 24
  @caption_h 22

  @doc "One scene as an `<svg>` element; `x:`/`y:` place it inside a sheet."
  def svg(ops, w, h, opts \\ []) do
    at =
      case {Keyword.get(opts, :x), Keyword.get(opts, :y)} do
        {nil, nil} -> ~s(xmlns="http://www.w3.org/2000/svg")
        {x, y} -> ~s(x="#{n(x)}" y="#{n(y)}")
      end

    [
      ~s(<svg #{at} width="#{n(w)}" height="#{n(h)}" viewBox="0 0 #{n(w)} #{n(h)}" overflow="hidden">),
      case Keyword.get(opts, :background) do
        nil -> ""
        bg -> ~s(<rect width="#{n(w)}" height="#{n(h)}" #{paint(:fill, bg, nil)}/>)
      end,
      Enum.map(ops, &op/1),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Writes `scenes` (`[{name, w, h, ops}]`) to one sheet, a caption over each:
  `<out>.png` and the `<out>.svg` it was drawn from. Returns the PNG path.
  Options: `background:` (ARGB, default the app background), `columns:`
  (default 3), `scale:` (default 2).
  """
  def render(scenes, out, opts \\ []) do
    bg = Keyword.get(opts, :background, 0xFF14121A)
    columns = Keyword.get(opts, :columns, 3)
    rows = Enum.chunk_every(scenes, columns)

    col_widths =
      scenes
      |> Enum.with_index()
      |> Enum.group_by(fn {_scene, i} -> rem(i, columns) end, fn {{name, w, h, _}, _} ->
        max(w, String.length(caption(name, w, h)) * 6.7)
      end)
      |> Enum.sort()
      |> Enum.map(fn {_col, widths} -> Enum.max(widths) end)

    col_x = Enum.scan([@gap | col_widths], fn w, x -> x + w + @gap end)

    {cells, height} =
      Enum.reduce(rows, {[], @gap}, fn row, {acc, y} ->
        row_h = Enum.max(Enum.map(row, &elem(&1, 2))) + @caption_h

        cells =
          row
          |> Enum.with_index()
          |> Enum.map(fn {{name, w, h, ops}, i} ->
            x = Enum.at(col_x, i)

            ~s(<text x="#{n(x)}" y="#{n(y + 12)}" font-family="Menlo, monospace" font-size="11" fill="#A9A3B8">) <>
              escape(caption(name, w, h)) <>
              "</text>" <> svg(ops, w, h, x: x, y: y + @caption_h, background: bg)
          end)

        {[acc | cells], y + row_h + @gap}
      end)

    width = Enum.sum(col_widths) + @gap * (length(col_widths) + 1)

    sheet =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{n(width)}" height="#{n(height)}">) <>
        ~s(<rect width="100%" height="100%" fill="#0B0A0F"/>#{cells}</svg>)

    base = Path.rootname(out)
    File.mkdir_p!(Path.dirname(base))
    File.write!(base <> ".svg", sheet)
    rasterise(sheet, base <> ".png", Keyword.get(opts, :scale, 2))
  end

  @doc """
  One scene as a PNG exactly `w × h` px, nothing outside the ops (what isn't
  drawn stays transparent). For assets such as the app icon.
  """
  def png(ops, w, h, out) do
    File.mkdir_p!(Path.dirname(out))
    rasterise(svg(ops, w, h), out, 1)
  end

  defp rasterise(svg, png, scale) do
    svg |> Image.from_svg!(scale: scale) |> Image.write!(png)
    png
  end

  defp caption(name, w, h), do: "#{name} · #{w}×#{h}"

  # ── Ops ─────────────────────────────────────────────────────────────────

  defp op(%{op: :line} = o) do
    ~s(<line x1="#{n(o.x1)}" y1="#{n(o.y1)}" x2="#{n(o.x2)}" y2="#{n(o.y2)}" #{stroke(o)}/>)
  end

  defp op(%{op: :circle} = o) do
    ~s(<circle cx="#{n(o.x)}" cy="#{n(o.y)}" r="#{n(o.r)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :ellipse} = o) do
    ~s(<ellipse cx="#{n(o.x)}" cy="#{n(o.y)}" rx="#{n(o.rx)}" ry="#{n(o.ry)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :arc} = o) do
    a0 = o.start_deg * :math.pi() / 180
    a1 = o.end_deg * :math.pi() / 180
    {x0, y0} = {o.x + o.r * :math.cos(a0), o.y + o.r * :math.sin(a0)}
    {x1, y1} = {o.x + o.r * :math.cos(a1), o.y + o.r * :math.sin(a1)}
    large = if abs(o.end_deg - o.start_deg) > 180, do: 1, else: 0
    sweep = if o.end_deg >= o.start_deg, do: 1, else: 0
    d = "M#{n(x0)} #{n(y0)} A#{n(o.r)} #{n(o.r)} 0 #{large} #{sweep} #{n(x1)} #{n(y1)}"
    ~s(<path d="#{d}" fill="none" #{stroke(o)}/>)
  end

  defp op(%{op: :rect} = o) do
    r = Map.get(o, :radius, 0)

    ~s(<rect x="#{n(o.x)}" y="#{n(o.y)}" width="#{n(o.w)}" height="#{n(o.h)}" rx="#{n(r)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :path, points: []}), do: ""

  defp op(%{op: :path} = o) do
    pts = Enum.map_join(o.points, " ", fn [x, y] -> "#{n(x)},#{n(y)}" end)
    fill = Map.get(o, :fill, false)
    tag = if fill or Map.get(o, :closed, false), do: "polygon", else: "polyline"
    ~s(<#{tag} points="#{pts}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :text} = o) do
    anchor =
      case Map.get(o, :anchor, :start) do
        :center -> "middle"
        :end -> "end"
        _ -> "start"
      end

    weight = if Map.get(o, :weight) in [:medium, :semibold, :bold], do: "bold", else: "normal"

    ~s(<text x="#{n(o.x)}" y="#{n(o.y + o.size * @ascent)}" font-size="#{n(o.size)}" ) <>
      ~s(font-weight="#{weight}" text-anchor="#{anchor}" font-family="#{@sans}" #{paint(:fill, o.color, Map.get(o, :opacity))}>) <>
      escape(o.text) <> "</text>"
  end

  defp op(%{op: :image}), do: ""

  defp shape_paint(o) do
    if Map.get(o, :fill, false),
      do: paint(:fill, o.color, Map.get(o, :opacity)) <> ~s( stroke="none"),
      else: ~s(fill="none" ) <> stroke(o)
  end

  defp stroke(o) do
    cap = Map.get(o, :cap, :butt)
    join = Map.get(o, :join, :miter)

    dash =
      case Map.get(o, :dash) do
        [_ | _] = d -> ~s( stroke-dasharray="#{Enum.map_join(d, ",", &n/1)}")
        _ -> ""
      end

    paint(:stroke, o.color, Map.get(o, :opacity)) <>
      ~s( stroke-width="#{n(Map.get(o, :width, 1))}" stroke-linecap="#{cap}" stroke-linejoin="#{join}") <>
      dash
  end

  defp paint(kind, color, opacity) do
    {hex, a} = color(color)
    ~s(#{kind}="#{hex}" #{kind}-opacity="#{n(a * (opacity || 1))}")
  end

  defp color(argb) when is_integer(argb) do
    a = (argb >>> 24 &&& 0xFF) / 255
    rgb = argb &&& 0xFFFFFF
    {"#" <> String.pad_leading(Integer.to_string(rgb, 16), 6, "0"), a}
  end

  defp color("#" <> _ = hex), do: {hex, 1.0}
  defp color(other), do: raise(ArgumentError, "unsupported colour #{inspect(other)}")

  defp n(v) when is_integer(v), do: Integer.to_string(v)
  defp n(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)

  defp escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
end
