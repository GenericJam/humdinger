defmodule Humdinger.Views.PhraseThumbTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.PhraseThumb

  defp pills(data, w \\ 326, h \\ 56) do
    data |> PhraseThumb.ops(w, h) |> Enum.filter(&(&1[:radius] == 3))
  end

  test "notes run from x 6 to w − 6, pitch from bottom to top" do
    # 62..69 → lo/hi 59..72, widened to 14 semitones: 58.5..72.5.
    notes = [%{start_ms: 0, dur_ms: 500, midi: 62}, %{start_ms: 500, dur_ms: 500, midi: 69}]
    [a, b] = pills(%{notes: notes})

    assert {a.x, a.w, a.y, a.h} == {6.0, 154.0, 36.5, 6}
    assert {b.x, b.w, b.y} == {163.0, 154.0, 17.5}
    assert b.x + b.w + 3 == 320.0
    assert a.color == Style.pitch_color(62)
  end

  test "a wide range keeps 3 semitones of margin: the highest note near the top" do
    notes = [%{start_ms: 0, dur_ms: 500, midi: 50}, %{start_ms: 500, dur_ms: 500, midi: 74}]
    [low, high] = pills(%{notes: notes})

    # lo/hi 47..77: y = 46 − (m − 47)/30·38.
    assert low.y == 42.2
    assert high.y == 11.8
  end

  test "times are relative to the first note, gaps kept, short notes at least 4 wide" do
    notes = [%{start_ms: 1000, dur_ms: 10, midi: 60}, %{start_ms: 1500, dur_ms: 500, midi: 60}]
    [a, b] = pills(%{notes: notes})

    assert a.x == 6.0
    assert a.w == 4.0
    assert b.x == 163.0
  end

  test "empty notes draw only the well" do
    assert [%{op: :rect, radius: 10, color: color}] = PhraseThumb.ops(%{notes: []}, 326, 56)
    assert color == Style.bg()
  end
end
