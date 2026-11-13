defmodule Humdinger.Views.RollRowsClipTest do
  use ExUnit.Case, async: true

  alias Humdinger.Scale
  alias Humdinger.Views.{PitchRoll, RollRows}

  test "a run is cut at the edges, never pinned to them" do
    # In, out over the top, back in.
    run = [{0, 50}, {100, 50}, {150, -400}, {200, 50}, {300, 60}]
    pieces = RollRows.clip_run(run, 350, 256)
    assert [[{0, 50}, {100, 50}, {x1, +0.0}], [{x2, +0.0}, {200, 50}, {300, 60}]] = pieces
    assert x1 > 100 and x1 < 150
    assert x2 > 150 and x2 < 200

    for piece <- pieces, {x, y} <- piece do
      assert x >= 0 and x <= 350 and y >= 0 and y <= 256
    end

    assert RollRows.clip_run([{10, -5}, {20, -50}], 350, 256) == []
    assert RollRows.clip_run([{10, 300}], 350, 256) == []
  end

  test "a pitch roll centred far below the voice draws nothing outside the box" do
    # The bug from the moto g 2024: rows F3–D#4 while E4 and above were sung.
    data = %{
      now_ms: 4_000,
      trace: for(t <- 0..4_000//100, do: {t, 76.0 + rem(t, 3)}),
      notes: [%{start_ms: 0, end_ms: nil, midi: 76}],
      scale: Scale.new("D", :dorian),
      center_midi: 58
    }

    ops = PitchRoll.ops(data, 350, 256)

    for op <- ops, op.op in [:path, :circle], {x, y} <- points(op) do
      assert y >= 0 and y <= 256, inspect(op)
      assert x >= 0 and x <= 350, inspect(op)
    end

    for op <- ops, op.op == :rect do
      assert op.y >= 0 and op.y + op.h <= 256.01, inspect(op)
    end
  end

  test "a note block crossing the top edge is cut there" do
    data = %{
      now_ms: 4_000,
      trace: [],
      notes: [%{start_ms: 1_000, end_ms: nil, midi: 64}],
      scale: nil,
      center_midi: 58.2
    }

    block = PitchRoll.ops(data, 350, 256) |> Enum.filter(&(&1.op == :rect and &1[:radius] != nil))
    assert [%{y: +0.0, h: h}] = Enum.filter(block, &(&1.color == Humdinger.Style.pitch_color(64)))
    assert h < 16
  end

  defp points(%{op: :path, points: pts}), do: Enum.map(pts, fn [x, y] -> {x, y} end)
  defp points(%{op: :circle, x: x, y: y}), do: [{x, y}]
end
