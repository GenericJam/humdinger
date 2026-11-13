defmodule Humdinger.Views.RangeBar do
  @moduledoc """
  The first-run 88-key rainbow (board `05-first_run`, 342 × 40): every key
  of the piano as a sliver `w / 88` wide in its pitch colour, keys outside
  the singer's chosen range dimmed, a white marker at the pitch being sung
  and A0 / C8 labels under the ends.

  ## Layout (canvas-local)

  The board's marker starts 6 above the keys, so everything is shifted down
  6: blacks from y 6 (12 high, lightness 45), whites from y 12 (16 high,
  lightness 62), the marker 3 × 34 (#F3EFF8, r2) from y 0, the labels (mono
  10, #6B6580) at y 36, A0 left-aligned at 0 and C8 right-aligned at `w`.
  Natural height: `height/0` (46).

  ## Dimming

  Keys below `low` and above `high` are drawn at opacity 0.35, the rest
  at 1. While choosing, only the known bound dims: with just `low` (the
  board's "Sing your lowest" step) the keys below it dim; with neither
  nothing does. The marker sits on the left edge of the key being sung
  (as the board's `(m − 21) · w/88`), moving continuously with fractional
  pitch, clamped to the strip; nil pitch draws no marker.
  """

  import Mob.Canvas

  alias Humdinger.{Music, Style}
  alias Humdinger.Views.Draw

  @typedoc """
  `pitch`: the sung pitch as fractional MIDI, or nil when silent. `low` /
  `high`: the chosen range bounds (MIDI), nil until chosen.
  """
  @type data :: %{
          optional(:pitch) => float() | nil,
          optional(:low) => integer() | nil,
          optional(:high) => integer() | nil
        }

  @shift 6
  @marker_w 3
  @dim 0.35

  @doc "The natural canvas height: the board's 40 plus the marker's 6 above."
  @spec height() :: pos_integer()
  def height, do: 46

  @doc "Canvas ops for the bar at `w` × `h` (`h` is not used: the layout is fixed-height)."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, _h) do
    mw = w / 88
    low = Map.get(data, :low)
    high = Map.get(data, :high)

    keys =
      for m <- 21..108 do
        {top, kh, l} = if Music.white_key?(m), do: {6, 16, 62}, else: {0, 12, 45}
        opts = [color: Style.pitch_color(m, l), fill: true]
        opts = if dimmed?(m, low, high), do: [{:opacity, @dim} | opts], else: opts
        rect(Draw.r1((m - 21) * mw), @shift + top, Draw.r1(mw + 0.4), kh, opts)
      end

    label_opts = [
      color: Style.faint(),
      size: 10,
      weight: :semibold,
      family: Style.font_family(:mono_semibold)
    ]

    keys ++
      marker(Map.get(data, :pitch), w) ++
      [
        text(0, @shift + 30, "A0", label_opts),
        text(Draw.r1(w), @shift + 30, "C8", [{:anchor, :end} | label_opts])
      ]
  end

  @doc "The marker's left edge for a (fractional MIDI) pitch at width `w`, clamped to the strip."
  @spec marker_x(number(), number()) :: float()
  def marker_x(pitch, w) do
    Draw.r1(Draw.clamp((pitch - 21) * w / 88, 0, w - @marker_w))
  end

  defp marker(nil, _w), do: []

  defp marker(pitch, w) do
    [rect(marker_x(pitch, w), 0, @marker_w, 34, color: Style.text(), fill: true, radius: 2)]
  end

  defp dimmed?(m, low, high), do: (low != nil and m < low) or (high != nil and m > high)
end
