defmodule Humdinger.Views.PhraseThumb do
  @moduledoc """
  The small melody preview on a Phrases list card
  (`design/boards/07-saved.html`, the 326×56 strips in
  `design/shots/saved.webp`): a rounded well (r10, `Style.bg/0`) with each
  note as a 6 dp pill (r3) in its pitch colour.

  Time runs from the first note's start at x = 6 to the last note's end at
  x = w − 6; a note is `max(4, dur·unit − 3)` wide so neighbours stay
  apart. Pitch runs from `lo` at y = h − 10 (46 at h 56) up to `hi` at
  y = 8, where `lo`/`hi` are the notes' lowest/highest MIDI 3 semitones
  out, widened symmetrically to at least 14 semitones so a narrow melody
  doesn't fill the strip (the board's examples span 14–16). No notes: just
  the well.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @pad_x 6
  @note_h 6
  @min_span 14

  @typedoc "A phrase note."
  @type note :: %{start_ms: number(), dur_ms: number(), midi: integer()}
  @type data :: %{notes: [note()]}

  @doc "Canvas ops for the preview at `w`×`h`."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    [
      rect(0, 0, w, h, color: Style.bg(), fill: true, radius: 10)
      | notes(Map.get(data, :notes) || [], w, h)
    ]
  end

  defp notes([], _w, _h), do: []

  defp notes(notes, w, h) do
    t0 = notes |> Enum.map(& &1.start_ms) |> Enum.min()
    t1 = notes |> Enum.map(&(&1.start_ms + &1.dur_ms)) |> Enum.max()
    unit = (w - 2 * @pad_x) / max(t1 - t0, 1)
    {lo, hi} = pitch_range(notes)
    base = h - 10
    rise = h - 18

    for %{start_ms: s, dur_ms: d, midi: m} <- notes do
      y = base - (m - lo) / (hi - lo) * rise

      rect(Draw.r1(@pad_x + (s - t0) * unit), Draw.r1(y), Draw.r1(max(4, d * unit - 3)), @note_h,
        color: Style.pitch_color(m),
        fill: true,
        radius: 3
      )
    end
  end

  defp pitch_range(notes) do
    {lo, hi} = notes |> Enum.map(& &1.midi) |> Enum.min_max()
    {lo, hi} = {lo - 3, hi + 3}
    widen = max(@min_span - (hi - lo), 0) / 2
    {lo - widen, hi + widen}
  end
end
