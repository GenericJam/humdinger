defmodule Humdinger.Views.TuningMeter do
  @moduledoc """
  The flat/sharp slider under the big note name on Live (board `02-live`,
  213 × 22 beside Mimi): a 4 px track (#2E2A3B, r2) at y 9, the in-tune
  zone as a lime band (opacity 0.35, 8 high, r4) at y 7, a centre tick
  (2 × 20, #6B6580) at y 1, and the offset marker (4 × 16, #F3EFF8, r2) at
  y 3.

  Half the width is 50 ¢, so the band spans ±`tolerance` around the centre
  and the marker moves `cents / 50 · w/2` from it, clamped inside the
  canvas. Nil cents (silence) draws no marker.

  The note name, `velocity_label/1` and `caption/2` are native text beside
  and under the meter (their fonts aren't available to Android canvas
  text); the helpers here keep their wording in one place.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @typedoc "`cents`: offset from the nearest note (nil: silent). `tolerance`: in-tune half-width in cents (default 10)."
  @type data :: %{optional(:cents) => number() | nil, optional(:tolerance) => number()}

  @full_scale 50
  @default_tolerance 10
  @marker_w 4

  @doc "The natural canvas height."
  @spec height() :: pos_integer()
  def height, do: 22

  @doc "Canvas ops for the meter at `w` × `h` (`h` is not used: the layout is fixed-height)."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, _h) do
    tol = Map.get(data, :tolerance) || @default_tolerance
    half = w / 2
    band = Draw.clamp(tol / @full_scale * half, 0, half)

    [
      rect(0, 9, Draw.r1(w), 4, color: Style.line_soft(), fill: true, radius: 2),
      rect(Draw.r1(half - band), 7, Draw.r1(band * 2), 8,
        color: Style.fm(),
        fill: true,
        radius: 4,
        opacity: 0.35
      ),
      rect(Draw.r1(half - 1), 1, 2, 20, color: Style.faint(), fill: true)
    ] ++ marker(Map.get(data, :cents), w)
  end

  @doc "The marker's centre x for `cents` at width `w`: ±50 ¢ = ±w/2, clamped so the marker stays inside."
  @spec marker_x(number(), number()) :: float()
  def marker_x(cents, w) do
    x = w / 2 + cents / @full_scale * (w / 2)
    Draw.r1(Draw.clamp(x, @marker_w / 2, w - @marker_w / 2))
  end

  @doc """
  The caption under the meter, e.g. `"−12¢ · a little flat"` (U+2212
  minus): "in tune" within `tolerance`, "a little flat/sharp" up to 25 ¢,
  "flat"/"sharp" beyond. Nil cents → `""`.
  """
  @spec caption(number() | nil, number()) :: String.t()
  def caption(cents, tolerance \\ @default_tolerance)
  def caption(nil, _tolerance), do: ""

  def caption(cents, tolerance) do
    n = round(cents)
    sign = if n < 0, do: "−", else: if(n > 0, do: "+", else: "")
    "#{sign}#{abs(n)}¢ · #{verdict(cents, tolerance)}"
  end

  defp verdict(c, tol) when abs(c) <= tol, do: "in tune"
  defp verdict(c, _tol) when c < 0 and c >= -25, do: "a little flat"
  defp verdict(c, _tol) when c > 0 and c <= 25, do: "a little sharp"
  defp verdict(c, _tol) when c < 0, do: "flat"
  defp verdict(_c, _tol), do: "sharp"

  @doc ~s(The velocity beside the note name: `"vel 92"`; nil → `""`.)
  @spec velocity_label(integer() | nil) :: String.t()
  def velocity_label(nil), do: ""
  def velocity_label(velocity), do: "vel #{round(velocity)}"

  defp marker(nil, _w), do: []

  defp marker(cents, w) do
    x = marker_x(cents, w)

    [
      rect(Draw.r1(x - @marker_w / 2), 3, @marker_w, 16,
        color: Style.text(),
        fill: true,
        radius: 2
      )
    ]
  end
end
