# Renders Mob.Canvas ops on the host: ops → SVG → PNG (headless Chrome), so
# views can be compared with design/shots/* without a phone. Load it from a
# script or IEx:
#
#     Code.require_file("scripts/canvas_svg.exs")
#     CanvasSvg.render([{"mimi", 220, 192, ops}], "/tmp/mimi.png")
#
# `render/3` lays the scenes out on one sheet (a caption over each) and
# screenshots it at 2x. Text follows Android's canvas renderer by default
# (`family:` ignored, the system sans-serif, bold for :medium and heavier);
# `fonts: :ios` draws each op's `family:` from priv/fonts instead.
# `scripts/preview_views.exs` renders every scene of Humdinger.GalleryScreen.

defmodule CanvasSvg do
  import Bitwise

  @chrome System.get_env("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  # Where the text's top sits above its baseline, as a fraction of its size.
  # Mob draws canvas text with y at the top (Android: baseline − ascent).
  @ascent 0.93

  @doc "One scene as an `<svg>` element."
  def svg(ops, w, h, opts \\ []) do
    fonts = Keyword.get(opts, :fonts, :android)

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}" style="overflow:hidden">),
      case Keyword.get(opts, :background) do
        nil -> ""
        bg -> ~s(<rect width="#{w}" height="#{h}" #{paint(:fill, bg, nil)}/>)
      end,
      Enum.map(ops, &op(&1, fonts)),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Writes `scenes` (`[{name, w, h, ops}]`) to one sheet: `<out>.html` and
  `<out>.png` (`out` may end in .png). Returns the PNG path.
  Options: `background:` (ARGB, default the app background), `fonts:`,
  `columns:` (default 3), `scale:` (default 2).
  """
  def render(scenes, out, opts \\ []) do
    base = Path.rootname(out)
    html_path = base <> ".html"
    png_path = base <> ".png"
    bg = Keyword.get(opts, :background, 0xFF14121A)
    columns = Keyword.get(opts, :columns, 3)
    scale = Keyword.get(opts, :scale, 2)
    gap = 24

    rows = Enum.chunk_every(scenes, columns)

    row_heights = Enum.map(rows, fn row -> Enum.max(Enum.map(row, &elem(&1, 2))) + 22 end)

    # CSS grid sizes each column to its widest cell (canvas or caption).
    width =
      scenes
      |> Enum.with_index()
      |> Enum.group_by(fn {_scene, i} -> rem(i, columns) end, fn {{name, w, h, _}, _} ->
        max(w, String.length("#{name} · #{w}×#{h}") * 6.7)
      end)
      |> Enum.map(fn {_col, widths} -> Enum.max(widths) end)
      |> Enum.sum()
      |> Kernel.+(gap * (min(columns, length(scenes)) + 1))
      |> ceil()

    height = Enum.sum(row_heights) + gap * (length(rows) + 1)

    cells =
      Enum.map(scenes, fn {name, w, h, ops} ->
        ~s(<figure><figcaption>#{escape(name)} · #{w}×#{h}</figcaption>) <>
          svg(ops, w, h, background: bg, fonts: Keyword.get(opts, :fonts, :android)) <>
          "</figure>"
      end)

    html = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    #{font_faces()}
    body{margin:0;background:#0B0A0F;color:#A9A3B8;font:11px 'JetBrainsMono-Medium',monospace}
    main{display:grid;grid-template-columns:repeat(#{columns},max-content);gap:#{gap}px;padding:#{gap}px;align-items:start}
    figure{margin:0}figcaption{height:18px}
    svg text{font-family:Roboto,'Helvetica Neue',Arial,sans-serif}
    </style></head><body><main>#{cells}</main></body></html>
    """

    File.mkdir_p!(Path.dirname(html_path))
    File.write!(html_path, html)
    screenshot(html_path, png_path, width, height, scale)
    png_path
  end

  defp screenshot(html_path, png_path, w, h, scale) do
    # A throwaway profile: sharing the default one with a running Chrome (or
    # another agent's render) can stall the headless run for minutes.
    profile =
      Path.join(System.tmp_dir!(), "canvas_svg_chrome_#{System.unique_integer([:positive])}")

    args = [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-first-run",
      "--no-default-browser-check",
      "--user-data-dir=#{profile}",
      "--force-device-scale-factor=#{scale}",
      "--window-size=#{w},#{h}",
      "--screenshot=#{Path.expand(png_path)}",
      "file://" <> Path.expand(html_path)
    ]

    File.rm(png_path)
    {out, code} = System.cmd(@chrome, args, stderr_to_stdout: true)
    File.rm_rf(profile)

    # Headless Chrome sometimes exits non-zero at teardown after writing the
    # screenshot; only a missing PNG is a failure.
    case File.stat(png_path) do
      {:ok, %{size: size}} when size > 0 -> :ok
      _ -> raise "Chrome wrote no screenshot (exit #{code}): #{out}"
    end
  end

  defp font_faces do
    "priv/fonts/*.ttf"
    |> Path.wildcard()
    |> Enum.map_join("\n", fn file ->
      name = Path.basename(file, ".ttf")
      "@font-face{font-family:'#{name}';src:url('file://#{Path.expand(file)}')}"
    end)
  end

  # ── Ops ─────────────────────────────────────────────────────────────────

  defp op(%{op: :line} = o, _fonts) do
    ~s(<line x1="#{n(o.x1)}" y1="#{n(o.y1)}" x2="#{n(o.x2)}" y2="#{n(o.y2)}" #{stroke(o)}/>)
  end

  defp op(%{op: :circle} = o, _fonts) do
    ~s(<circle cx="#{n(o.x)}" cy="#{n(o.y)}" r="#{n(o.r)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :ellipse} = o, _fonts) do
    ~s(<ellipse cx="#{n(o.x)}" cy="#{n(o.y)}" rx="#{n(o.rx)}" ry="#{n(o.ry)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :arc} = o, _fonts) do
    a0 = o.start_deg * :math.pi() / 180
    a1 = o.end_deg * :math.pi() / 180
    {x0, y0} = {o.x + o.r * :math.cos(a0), o.y + o.r * :math.sin(a0)}
    {x1, y1} = {o.x + o.r * :math.cos(a1), o.y + o.r * :math.sin(a1)}
    large = if abs(o.end_deg - o.start_deg) > 180, do: 1, else: 0
    sweep = if o.end_deg >= o.start_deg, do: 1, else: 0
    d = "M#{n(x0)} #{n(y0)} A#{n(o.r)} #{n(o.r)} 0 #{large} #{sweep} #{n(x1)} #{n(y1)}"
    ~s(<path d="#{d}" fill="none" #{stroke(o)}/>)
  end

  defp op(%{op: :rect} = o, _fonts) do
    r = Map.get(o, :radius, 0)

    ~s(<rect x="#{n(o.x)}" y="#{n(o.y)}" width="#{n(o.w)}" height="#{n(o.h)}" rx="#{n(r)}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :path, points: []}, _fonts), do: ""

  defp op(%{op: :path} = o, _fonts) do
    pts = Enum.map_join(o.points, " ", fn [x, y] -> "#{n(x)},#{n(y)}" end)
    fill = Map.get(o, :fill, false)
    tag = if fill or Map.get(o, :closed, false), do: "polygon", else: "polyline"
    ~s(<#{tag} points="#{pts}" #{shape_paint(o)}/>)
  end

  defp op(%{op: :text} = o, fonts) do
    anchor =
      case Map.get(o, :anchor, :start) do
        :center -> "middle"
        :end -> "end"
        _ -> "start"
      end

    weight = if Map.get(o, :weight) in [:medium, :semibold, :bold], do: "bold", else: "normal"

    family =
      case {fonts, Map.get(o, :family)} do
        {:ios, f} when is_binary(f) -> ~s( style="font-family:'#{f}'")
        _ -> ""
      end

    ~s(<text x="#{n(o.x)}" y="#{n(o.y + o.size * @ascent)}" font-size="#{n(o.size)}" ) <>
      ~s(font-weight="#{weight}" text-anchor="#{anchor}"#{family} #{paint(:fill, o.color, Map.get(o, :opacity))}>) <>
      escape(o.text) <> "</text>"
  end

  defp op(%{op: :image}, _fonts), do: ""

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
