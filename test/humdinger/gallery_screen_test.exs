defmodule Humdinger.GalleryScreenTest do
  use Mob.ScreenCase, async: true

  alias Humdinger.GalleryScreen

  test "renders every scene as a canvas the native side can draw" do
    view = mount_screen(GalleryScreen)
    assert_renderable(view)
    assert Enum.count(find_all(view, :canvas)) == Enum.count(GalleryScreen.scenes())
  end

  test "every scene's ops are plain JSON-encodable draw ops with numeric geometry" do
    for {name, _w, _h, ops} <- GalleryScreen.scenes() do
      assert [_ | _] = ops, name
      # The renderer serialises ops with :json; tuples or pids would crash it on a device.
      assert is_binary(IO.iodata_to_binary(:json.encode(ops))), name

      for op <- ops,
          key <- [:x, :y, :w, :h, :r, :rx, :ry, :x1, :y1, :x2, :y2],
          Map.has_key?(op, key) do
        assert is_number(op[key]), "#{name}: #{inspect(op)}"
      end
    end
  end
end
