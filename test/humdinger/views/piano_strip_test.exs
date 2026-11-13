defmodule Humdinger.Views.PianoStripTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.PianoStrip

  @board %{low: 62, high: 76, active: 69, range: nil}
  @w 334
  @h 129

  defp key(data, midi), do: Enum.find(PianoStrip.keys(data, @w, @h), &(&1.midi == midi))

  defp filled_paths(ops, color), do: Enum.filter(ops, &(&1.op == :path and &1.color == color))

  describe "keys/3 (board case: low 62, high 76 at 334 × 129)" do
    test "whites sit every 44 from D4 at −29, clipped to the canvas" do
      whites = PianoStrip.keys(@board, @w, @h) |> Enum.reject(& &1.black)
      assert Enum.map(whites, & &1.midi) == [62, 64, 65, 67, 69, 71, 72, 74, 76]
      assert %{x: 0.0, w: 12.0, y: 25, h: 104.0} = key(@board, 62)
      assert %{x: 147.0, w: 41.0} = key(@board, 69)
      assert %{x: 323.0, w: 11.0} = key(@board, 76)
    end

    test "blacks are 26 wide, 14 left of the following white, 62 high" do
      assert %{x: 1.0, w: 26.0, h: 62.0, black: true} = key(@board, 63)
      assert %{x: 89.0, w: 26.0, black: true} = key(@board, 66)
      assert key(@board, 61) == nil
    end

    test "a wide window keeps white keys at least 36 wide" do
      whites = PianoStrip.keys(%{low: 36, high: 84}, @w, @h) |> Enum.reject(& &1.black)
      assert whites |> Enum.filter(&(&1.x > 0 and &1.x + &1.w < @w)) |> Enum.all?(&(&1.w >= 36))
    end

    test "empty data shows a default window without crashing" do
      assert [_ | _] = PianoStrip.keys(%{}, @w, @h)
      assert [_ | _] = PianoStrip.ops(%{}, @w, @h)
    end
  end

  describe "ops/3" do
    test "an active white key is filled in its pitch colour, its name in ink" do
      ops = PianoStrip.ops(@board, @w, @h)
      assert [%{points: [[147.0, 25.0] | _]}] = filled_paths(ops, Style.pitch_color(69))
      assert Enum.any?(ops, &(&1.op == :text and &1.text == "A4" and &1.color == Style.ink()))
      assert Enum.any?(ops, &(&1.op == :text and &1.text == "B4" and &1.color == Style.faint()))
    end

    test "an active black key is filled in its pitch colour" do
      ops = PianoStrip.ops(%{@board | active: 66}, @w, @h)
      assert [%{points: [[89.0, 25.0] | _]}] = filled_paths(ops, Style.pitch_color(66))

      refute Enum.any?(
               filled_paths(ops, Style.key_black()),
               &match?(%{points: [[89.0, _] | _]}, &1)
             )
    end

    test "overview keys outside the range are dimmed" do
      overview = PianoStrip.ops(%{@board | range: {40, 84}}, @w, @h) |> Enum.take(88)
      opacity = fn m -> overview |> Enum.at(m - 21) |> Map.get(:opacity, 1) end
      assert opacity.(39) == 0.35
      assert opacity.(40) == 1
      assert opacity.(84) == 1
      assert opacity.(85) == 0.35
      assert Enum.at(overview, 69 - 21).color == Style.pitch_color(69)
      assert Enum.at(overview, 70 - 21).color == Style.pitch_color(70, 45)
    end

    test "no range: nothing dimmed" do
      overview = PianoStrip.ops(@board, @w, @h) |> Enum.take(88)
      refute Enum.any?(overview, &Map.has_key?(&1, :opacity))
    end

    test "the window box spans low..high on the overview" do
      box = PianoStrip.ops(@board, @w, @h) |> Enum.find(&(&1.op == :rect and &1[:width] == 2))
      assert {box.x, box.w} == {157, 55}
    end
  end

  describe "hit/5" do
    test "the centre of a white key" do
      assert PianoStrip.hit(@board, @w, @h, 167.5, 115) == {:key, 69}
    end

    test "a black key wins over the white under it; below it the white answers" do
      assert PianoStrip.hit(@board, @w, @h, 14, 40) == {:key, 63}
      assert PianoStrip.hit(@board, @w, @h, 14, 110) == {:key, 62}
      assert PianoStrip.hit(@board, @w, @h, 16, 110) == {:key, 64}
    end

    test "the gap after a white belongs to it" do
      assert PianoStrip.hit(@board, @w, @h, 189.5, 110) == {:key, 69}
    end

    test "the overview answers the key under the finger" do
      mw = @w / 88
      assert PianoStrip.hit(@board, @w, @h, 48.5 * mw, 8) == {:window, 69}
      assert PianoStrip.hit(@board, @w, @h, 0, 2) == {:window, 21}
      assert PianoStrip.hit(@board, @w, @h, @w, 20) == {:window, 108}
    end

    test "outside the canvas or beyond the piano's end is :none" do
      assert PianoStrip.hit(@board, @w, @h, -1, 100) == :none
      assert PianoStrip.hit(@board, @w, @h, 100, @h + 1) == :none
      assert PianoStrip.hit(%{low: 21, high: 24}, @w, @h, 10, 110) == :none
    end
  end
end
