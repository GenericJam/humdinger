# Renders every scene of Humdinger.GalleryScreen to one PNG sheet on the
# host, to compare the views with design/shots/*:
#
#     mise exec -- mix run --no-start scripts/preview_views.exs [out.png]
#
# Default output: /tmp/humdinger_views/gallery.png (and the .svg beside it).

Code.require_file("canvas_svg.exs", __DIR__)

out = List.first(System.argv(), "/tmp/humdinger_views/gallery.png")
IO.puts(CanvasSvg.render(Humdinger.GalleryScreen.scenes(), out))
