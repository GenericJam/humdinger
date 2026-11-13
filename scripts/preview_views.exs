# Renders every scene of Humdinger.GalleryScreen to one PNG sheet on the
# host (headless Chrome), to compare the views with design/shots/*:
#
#     mise exec -- mix run --no-start scripts/preview_views.exs [out.png] [--ios-fonts]
#
# Default output: /tmp/humdinger_views/gallery.png (and .html beside it).
# --ios-fonts draws canvas text in each op's `family:` (iOS); the default
# follows Android, whose canvas renderer ignores it.

Code.require_file("canvas_svg.exs", __DIR__)

{flags, args} = Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))
out = List.first(args, "/tmp/humdinger_views/gallery.png")
fonts = if "--ios-fonts" in flags, do: :ios, else: :android

IO.puts(CanvasSvg.render(Humdinger.GalleryScreen.scenes(), out, fonts: fonts))
