defmodule Humdinger.MimiTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Mimi, Style}

  @white 0xFFFFFFFF
  @pupil 0xFF17141F
  @mark 0xFFF3EFF8

  # At size 64 one board unit is one dp; centred on (32, 28) the box is the
  # board's own coordinates.
  defp mimi(state), do: Mimi.ops(32, 28, 64, state)

  defp eye_whites(ops), do: Enum.filter(ops, &(&1.op == :ellipse and &1.color == @white))
  defp pupils(ops), do: Enum.filter(ops, &(&1.op == :ellipse and &1.color == @pupil))
  defp shut_eyes(ops), do: Enum.filter(ops, &(&1.op == :path and &1.color == @pupil))
  defp body(ops), do: ops |> Enum.filter(&(&1.op == :ellipse)) |> Enum.max_by(& &1.rx)
  defp texts(ops), do: ops |> Enum.filter(&(&1.op == :text)) |> Enum.map(& &1.text)

  defp note_heads(ops), do: Enum.filter(ops, &(&1.op == :ellipse and &1.color == @mark))

  defp lower_beak_tip_y(ops) do
    [_upper, lower] = Enum.filter(ops, &(&1.op == :path and &1.color == 0xFF2A2636 and &1[:fill]))
    lower.points |> Enum.at(1) |> Enum.at(1)
  end

  test "places the board's shapes in its 64 × 56 box, scaled and centred" do
    ops = Mimi.ops(100, 200, 128, %{mood: :idle})
    b = body(ops)
    # Box origin (100 − 64, 200 − 56); body at (24, 30) × 2, radii × 2.
    assert {b.x, b.y, b.rx, b.ry} == {36 + 48.0, 144 + 60.0, 40.0, 39.0}
  end

  test "feathers follow the sung note; no note is A4's teal" do
    assert body(mimi(%{mood: :singing, note: 40})).color == Style.pitch_color(40)
    assert body(mimi(%{mood: :singing, note: 81})).color == Style.pitch_color(81)
    assert body(mimi(%{mood: :idle, note: nil})).color == Style.pitch_color(69)
    assert body(mimi(%{})).color == Style.pitch_color(69)
  end

  test "asleep and without a mic she is grey whatever the note" do
    for mood <- [:paused, :no_mic] do
      assert body(mimi(%{mood: mood, note: 40})).color == 0xFF6B6580
    end
  end

  test "open eyes have whites and pupils; aria, paused and no mic shut them" do
    open = mimi(%{mood: :idle})
    assert [_, _] = eye_whites(open)
    assert [_, _] = pupils(open)
    assert shut_eyes(open) == []

    for mood <- [:aria, :paused, :no_mic] do
      ops = mimi(%{mood: mood})
      assert eye_whites(ops) == [] and pupils(ops) == []
      assert [_, _] = shut_eyes(ops)
    end
  end

  test "aria shuts the eyes in an arc, paused and no mic in a bar" do
    [arc | _] = shut_eyes(mimi(%{mood: :aria}))
    [bar | _] = shut_eyes(mimi(%{mood: :no_mic}))
    # The arc rises above its ends; the bar is two points on one line.
    [[_, y_end] | _] = arc.points
    assert Enum.any?(arc.points, fn [_, y] -> y < y_end - 1 end)
    assert [[_, y], [_, y]] = bar.points
  end

  test "pupils look down when flat and up when sharp, whatever look says" do
    [flat | _] = pupils(mimi(%{mood: :flat, look: {0, -1}}))
    [sharp | _] = pupils(mimi(%{mood: :sharp, look: {0, 1}}))
    [centre | _] = pupils(mimi(%{mood: :idle}))
    assert centre.y == 22.0
    assert flat.y > 22 and sharp.y < 22
  end

  test "look moves the pupils and is clamped to the eye" do
    [left | _] = pupils(mimi(%{mood: :idle, look: {-1, 0}}))
    [far | _] = pupils(mimi(%{mood: :idle, look: {-5, 0}}))
    assert left.x == 21 - 2.4
    assert far.x == left.x
  end

  test "flat draws a down arrow beside her, sharp an up arrow" do
    arrow = fn ops -> Enum.filter(ops, &(&1.op == :path and &1.color == @mark)) end
    [flat_shaft, _] = arrow.(mimi(%{mood: :flat}))
    [sharp_shaft, _] = arrow.(mimi(%{mood: :sharp}))
    [[_, flat_from], [_, flat_to]] = flat_shaft.points
    [[_, sharp_from], [_, sharp_to]] = sharp_shaft.points
    assert flat_to > flat_from
    assert sharp_to < sharp_from
    assert arrow.(mimi(%{mood: :idle})) == []
  end

  test "singing shows one note beside the head, aria two, idle none" do
    assert [_] = note_heads(mimi(%{mood: :singing}))
    assert [_, _] = note_heads(mimi(%{mood: :aria}))
    assert note_heads(mimi(%{mood: :idle})) == []
  end

  test "zZ only while paused" do
    assert texts(mimi(%{mood: :paused})) == ["z", "Z"]
    assert texts(mimi(%{mood: :no_mic})) == []
    assert texts(mimi(%{mood: :idle})) == []
  end

  test "headphones only in the headphones mood" do
    cups = &Enum.filter(&1, fn op -> op.op == :rect and op.h == 12.0 end)
    assert [_, _] = cups.(mimi(%{mood: :headphones}))
    assert cups.(mimi(%{mood: :idle})) == []
  end

  test "the beak opens with loudness, beak_open overrides, asleep keeps it shut" do
    shut = lower_beak_tip_y(mimi(%{mood: :idle}))
    loud = lower_beak_tip_y(mimi(%{mood: :singing, loudness: 1}))
    soft = lower_beak_tip_y(mimi(%{mood: :singing, loudness: 0}))
    assert shut < soft and soft < loud
    assert lower_beak_tip_y(mimi(%{mood: :singing, loudness: 1, beak_open: 0})) == shut
    assert lower_beak_tip_y(mimi(%{mood: :paused, loudness: 1})) == shut
  end

  test "blinking squashes the eyes and closes them near the end" do
    [half | _] = eye_whites(mimi(%{mood: :idle, blink: 0.5}))
    assert half.ry == Float.round(5.6 * 0.5, 1)
    closed = mimi(%{mood: :idle, blink: 1})
    assert eye_whites(closed) == []
    assert [_, _] = shut_eyes(closed)
  end

  test "every mood draws inside its box" do
    for mood <- Mimi.moods(), op <- mimi(%{mood: mood, loudness: 1}) do
      for {x, y} <- points(op) do
        assert x >= -1 and x <= 65 and y >= -1 and y <= 57, "#{mood} #{inspect(op)}"
      end
    end
  end

  describe "icon_ops/2" do
    test "a rounded surface tile, Mimi singing A4, an eight-band pitch stripe" do
      ops = Mimi.icon_ops(140)
      [tile | _] = ops

      assert tile == %{
               op: :rect,
               x: 0,
               y: 0,
               w: 140,
               h: 140,
               color: Style.surface(),
               fill: true,
               radius: 31.0
             }

      assert body(ops).color == Style.pitch_color(69)

      bands =
        Enum.filter(ops, &(&1.op == :path and Enum.all?(&1.points, fn [_, y] -> y >= 130 end)))

      assert Enum.map(bands, & &1.color) ==
               Enum.map([33, 45, 52, 57, 64, 69, 81, 93], &Style.pitch_color/1)
    end

    test "the stripe stays inside the rounded corners" do
      r = 31

      bands =
        Mimi.icon_ops(140)
        |> Enum.filter(&(&1.op == :path and Enum.all?(&1.points, fn [_, y] -> y >= 130 end)))

      for band <- bands, [x, y] <- band.points, x < r do
        # Inside the bottom-left corner circle (centre (r, 140 − r)).
        assert :math.sqrt((x - r) ** 2 + (y - (140 - r)) ** 2) <= r + 0.2
      end
    end

    test "square master for OS masking" do
      [tile | _] = Mimi.icon_ops(1024, rounded: false)
      assert tile.radius == 0.0
    end
  end

  defp points(%{op: :path, points: pts}), do: Enum.map(pts, fn [x, y] -> {x, y} end)
  defp points(%{op: :ellipse} = o), do: [{o.x - o.rx, o.y - o.ry}, {o.x + o.rx, o.y + o.ry}]
  defp points(%{op: :rect} = o), do: [{o.x, o.y}, {o.x + o.w, o.y + o.h}]
  defp points(%{op: :text} = o), do: [{o.x, o.y}]
end
