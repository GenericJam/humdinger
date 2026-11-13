# Renders the app icon from Mimi's geometry and installs it:
#
#     mise exec -- mix run --no-start scripts/render_icon.exs [--assets-only]
#
# 1. assets/icon/humdinger-icon-1024.png: the master, `Mimi.icon_ops(1024,
#    rounded: false)` ("Dark + pitch stripe" on the identity board, square:
#    the stores and iOS round the corners themselves).
# 2. assets/icon/humdinger-icon-foreground-1024.png: the Android adaptive
#    foreground, `Mimi.icon_foreground_ops(1024)`, Mimi alone on transparent.
# 3. Unless --assets-only: `mix mob.icon --source <master> --adaptive
#    --adaptive-bg "#1C1925"` (legacy Android, iOS, the adaptive XML and
#    background colour), then each mipmap-*/ic_launcher_foreground.png
#    redrawn from the foreground ops at its own size (mob.icon would reuse
#    the whole master, stripe and all, which the launcher mask crops).
#
# Rasterised with headless Chrome through scripts/canvas_svg.exs.

Code.require_file("canvas_svg.exs", __DIR__)

alias Humdinger.{Mimi, Style}

background =
  "#" <>
    String.pad_leading(Integer.to_string(Bitwise.band(Style.surface(), 0xFFFFFF), 16), 6, "0")

master = "assets/icon/humdinger-icon-1024.png"
foreground = "assets/icon/humdinger-icon-foreground-1024.png"

IO.puts(CanvasSvg.png(Mimi.icon_ops(1024, rounded: false), 1024, 1024, master))
IO.puts(CanvasSvg.png(Mimi.icon_foreground_ops(1024), 1024, 1024, foreground))

unless "--assets-only" in System.argv() do
  Mix.Task.run("mob.icon", ["--source", master, "--adaptive", "--adaptive-bg", background])

  for {bucket, px} <- MobDev.IconGenerator.adaptive_sizes() do
    path = "android/app/src/main/res/#{bucket}/ic_launcher_foreground.png"
    IO.puts(CanvasSvg.png(Mimi.icon_foreground_ops(px), px, px, path))
  end
end
