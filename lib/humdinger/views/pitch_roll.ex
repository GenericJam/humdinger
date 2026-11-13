defmodule Humdinger.Views.PitchRoll do
  @moduledoc """
  Live's trace area (`design/boards/02-live.html`, the 350×256 box in the
  middle of `design/shots/live.webp`): the last few seconds of singing
  scrolling right to left past a fixed playhead.

  Layout:

  - A rounded box (r16, `Style.surface/0`) filled with one 22 dp row per
    semitone, highest at the top. Rows are fixed height and centred on
    `center_midi` (fractional is fine: the screen eases it toward the
    voice), so as many rows show as fit the height; rows cut by the edges
    are drawn partially, inside the box's rounded corners.
  - In-scale rows stripe #221F2D / #1F1C29 (even / odd MIDI, so a row keeps
    its colour as the view scrolls) with a #A9A3B8 label; out-of-scale rows
    are #17151E with a #4F4A60 label. With no scale (Live's "Open + bend")
    the naturals count as in-scale. Labels are JetBrains Mono 600 10 at
    (8, row top + 6).
  - Time runs from `now_ms − window_ms` at x = 0 to `now_ms` at the
    playhead, x = w − 44, a 2 dp line at opacity 0.4.
  - Sent notes are 16 dp blocks (r5) centred on their row in the note's
    pitch colour, from start to end (to the playhead while sounding):
    opacity 1 while sounding (`end_ms: nil`), 0.55 once ended.
  - The sung pitch is a #F3EFF8 line 2.5 wide with round caps and joins,
    broken wherever the pitch is `nil`.
  - A 20 dp white dot sits on the playhead at the latest pitch (none when
    the latest sample is unvoiced).

  Ops entirely outside the canvas are dropped (a long session's notes and
  trace are mostly off the left edge).
  """

  import Mob.Canvas

  alias Humdinger.{Music, Scale, Style}
  alias Humdinger.Views.{Draw, RollRows}

  @row_h 22
  @radius 16
  @block_h 16
  @playhead_from_right 44
  @label_in 0xFFA9A3B8
  @label_out 0xFF4F4A60

  @typedoc "A note Humdinger sent; `end_ms: nil` while it is still sounding."
  @type note :: %{start_ms: number(), end_ms: number() | nil, midi: integer()}

  @typedoc """
  - `now_ms` — the time at the playhead.
  - `trace` — `{t_ms, pitch}` samples in time order; pitch is a fractional
    MIDI number or `nil` (unvoiced).
  - `notes` — the notes sent, see `t:note/0`.
  - `scale` — Live's scale, or `nil` in "Open + bend".
  - `center_midi` — the pitch at the vertical centre.
  - `window_ms` — optional, the time span shown left of the playhead
    (default 4000).
  """
  @type data :: %{
          required(:now_ms) => number(),
          required(:trace) => [{number(), number() | nil}],
          required(:notes) => [note()],
          required(:scale) => Scale.t() | nil,
          required(:center_midi) => number(),
          optional(:window_ms) => pos_integer()
        }

  @doc "Canvas ops for the trace area at `w`×`h`."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    geo = geometry(data, w, h)

    [RollRows.box(w, h, @radius)] ++
      rows(geo, Map.get(data, :scale)) ++
      blocks(geo, Map.get(data, :notes, [])) ++
      trace(geo, Map.get(data, :trace, [])) ++
      playhead(geo) ++
      dot(geo, Map.get(data, :trace, []))
  end

  defp geometry(data, w, h) do
    now = Map.get(data, :now_ms, 0)
    window = Map.get(data, :window_ms, 4000)
    center = Map.get(data, :center_midi, 60)
    px = w - @playhead_from_right

    %{
      w: w,
      h: h,
      now: now,
      px: px,
      center: center,
      x_of: fn t -> px - (now - t) / window * px end,
      y_of: fn p -> h / 2 - (p - center) * @row_h end
    }
  end

  defp rows(%{w: w, h: h, center: center, y_of: y_of}, scale) do
    half = h / 2 / @row_h + 1
    top_midi = ceil(center + half)
    bottom_midi = floor(center - half)

    for m <- top_midi..bottom_midi//-1,
        top = y_of.(m) - @row_h / 2,
        top < h and top + @row_h > 0,
        op <- row(m, top, w, h, in_scale?(scale, m)) do
      op
    end
  end

  defp row(m, top, w, h, in?) do
    bg = if in?, do: RollRows.stripe(m), else: RollRows.out_of_scale()
    label_y = top + 6
    band = RollRows.band(top, @row_h, w, h, @radius, bg)

    if label_y >= 0 and label_y + 10 <= h do
      band ++ [RollRows.label(8, label_y, Music.note_name(m), 10, label_color(in?))]
    else
      band
    end
  end

  defp label_color(true), do: @label_in
  defp label_color(false), do: @label_out

  defp in_scale?(nil, m), do: Music.white_key?(m)
  defp in_scale?(%Scale{} = scale, m), do: Scale.contains?(scale, m)

  defp blocks(geo, notes), do: Enum.flat_map(notes, &block(geo, &1))

  defp block(%{w: w, h: h, px: px, x_of: x_of, y_of: y_of}, %{start_ms: s, midi: m} = note) do
    end_ms = Map.get(note, :end_ms)
    x1 = x_of.(s)
    x2 = if end_ms, do: x_of.(end_ms), else: px
    y = y_of.(m) - @block_h / 2

    if x2 > 0 and x1 < w and y < h and y + @block_h > 0 do
      # Keep a block scrolling off the left edge inside the rounded corners.
      corner = max(RollRows.inset(y, h, @radius), RollRows.inset(y + @block_h, h, @radius))
      left = max(x1, corner)

      # Cut at the top and bottom edges rather than drawing past them.
      top = max(y, 0)
      bottom = min(y + @block_h, h)

      [
        rect(
          Draw.r1(left),
          Draw.r1(top),
          Draw.r1(max(min(x2, w) - left, 2)),
          Draw.r1(bottom - top),
          color: Style.pitch_color(m),
          fill: true,
          radius: min(5, (bottom - top) / 2),
          opacity: if(end_ms, do: 0.55, else: 1.0)
        )
      ]
    else
      []
    end
  end

  defp trace(%{w: w, h: h, now: now, x_of: x_of, y_of: y_of}, samples) do
    samples
    |> visible_samples(now, x_of)
    |> RollRows.runs(x_of, y_of)
    |> RollRows.trace_ops(w, h, width: 2.5)
  end

  # Samples from just before the left edge up to now: the one before the
  # edge keeps the line reaching the edge instead of starting inside it.
  defp visible_samples(samples, now, x_of) do
    {before, inside} =
      samples
      |> Enum.reject(fn {t, _} -> t > now end)
      |> Enum.split_while(fn {t, _} -> x_of.(t) < 0 end)

    case List.last(before) do
      nil -> inside
      last -> [last | inside]
    end
  end

  defp playhead(%{h: h, px: px}) do
    [rect(Draw.r1(px), 0, 2, h, color: Style.text(), fill: true, opacity: 0.4)]
  end

  defp dot(%{h: h, px: px, y_of: y_of}, samples) do
    case List.last(samples) do
      {_t, pitch} when is_number(pitch) ->
        y = y_of.(pitch)

        if y + 10 > 0 and y - 10 < h,
          do: [circle(Draw.r1(px + 1), Draw.r1(y), 10, color: Style.text(), fill: true)],
          else: []

      _ ->
        []
    end
  end
end
