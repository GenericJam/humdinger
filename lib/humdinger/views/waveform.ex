defmodule Humdinger.Views.Waveform do
  @moduledoc """
  The Import screen's file waveform with the part to use selected (board
  `12-import_audio`, top card: a 330 × 54 strip).

  ## Layout

  The selection box reaches 4 above and below the bars and its handles
  straddle its edges, so the canvas carries that overhang: bars fill
  x #{7}..w − #{7}, y 4..h − 4, and the board's 330 × 54 strip is a
  344 × 62 canvas.

    * Bars: one per 3 dp of strip (2 dp bar, 1 dp gap; 110 on the board),
      each the loudest of its peaks, as a share of the file's loudest peak
      (at least 4 %) of the strip height, centred vertically. Bars whose
      middle falls inside the selection are lime (`Style.fm/0`), the rest
      #4A4560.
    * Selection box: from 2 left of the selection start to 2 right of its
      end, the full canvas height, a 2 dp inset `Style.text/0` stroke with
      radius 6.
    * Handles: 10 × 28 (at most the strip height), radius 4, white,
      vertically centred, centred on the box's left and right edges.

  ## Data

  `peaks` is `Humdinger.Audio`'s analysis waveform (one peak byte per
  50 ms, a binary or a list of 0..255), `duration_ms` the file's length,
  `selection` `{from_ms, to_ms}` or `nil` (no box, all bars outside).

  ## Touch

  `hit/5` answers what a touch at canvas (x, y) grabs: a handle (a zone
  #{24} dp wide centred on each box edge; the nearer one when they
  overlap), the selection (to move it) or the strip outside it, with the
  time under the finger. `drag/5` applies a time delta to the grabbed
  part, keeping the selection inside the file and at least `min_ms` long;
  `ms_per_dp/2` turns finger travel into that delta.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @type selection :: {non_neg_integer(), non_neg_integer()}
  @type data :: %{
          peaks: binary() | [0..255],
          duration_ms: non_neg_integer(),
          selection: selection() | nil
        }
  @type hit ::
          {:handle, :start | :end}
          | {:range, non_neg_integer()}
          | {:outside, non_neg_integer()}
          | :none
  @type target :: :start | :end | :range

  @mx 7
  @my 4
  @pitch 3
  @handle_zone 24
  @outside_color 0xFF4A4560

  @doc "Ops for the waveform in a `w` × `h` canvas (board: 344 × 62)."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    selection = Map.get(data, :selection)
    duration = Map.get(data, :duration_ms) || 0

    List.flatten([
      bar_ops(peak_list(Map.get(data, :peaks)), duration, selection, w, h),
      selection_ops(selection, duration, w, h)
    ])
  end

  @doc """
  What a touch at canvas (`x`, `y`) grabs. Times are clamped to the file;
  `:none` when the touch is outside the canvas.
  """
  @spec hit(data(), number(), number(), number(), number()) :: hit()
  def hit(_data, w, h, x, y) when x < 0 or y < 0 or x > w or y > h, do: :none

  def hit(data, w, _h, x, _y) do
    duration = Map.get(data, :duration_ms) || 0
    ms = ms_at(x, duration, w)

    case Map.get(data, :selection) do
      {from, to} ->
        left = x_of(from, duration, w) - 2
        right = x_of(to, duration, w) + 2
        dl = abs(x - left)
        dr = abs(x - right)

        cond do
          min(dl, dr) <= @handle_zone / 2 -> {:handle, if(dl < dr, do: :start, else: :end)}
          ms >= from and ms <= to -> {:range, ms}
          true -> {:outside, ms}
        end

      _ ->
        {:outside, ms}
    end
  end

  @doc "File milliseconds per dp of finger travel along a `w`-wide canvas."
  @spec ms_per_dp(non_neg_integer(), number()) :: float()
  def ms_per_dp(duration_ms, w), do: duration_ms / max(w - 2 * @mx, 1)

  @doc """
  Move the grabbed part of `selection` by `dx_ms`: `:start` or `:end` moves
  that edge, `:range` shifts both. The result stays within
  `0..duration_ms` and at least `min_ms` long (capped at the file length);
  a moved edge stops at the other edge less `min_ms`, a shifted range stops
  at the file's ends.
  """
  @spec drag(selection(), target(), integer(), non_neg_integer(), non_neg_integer()) ::
          selection()
  def drag({from, to}, target, dx_ms, duration_ms, min_ms) do
    min_ms = min(min_ms, duration_ms)

    case target do
      :start ->
        {Draw.clamp(from + dx_ms, 0, max(to - min_ms, 0)), to}

      :end ->
        {from, Draw.clamp(to + dx_ms, min(from + min_ms, duration_ms), duration_ms)}

      :range ->
        len = to - from
        from = Draw.clamp(from + dx_ms, 0, max(duration_ms - len, 0))
        {from, min(from + len, duration_ms)}
    end
  end

  # ── Drawing ─────────────────────────────────────────────────────────────

  defp peak_list(peaks) when is_binary(peaks), do: :binary.bin_to_list(peaks)
  defp peak_list(peaks) when is_list(peaks), do: peaks
  defp peak_list(_), do: []

  defp bar_ops([], _duration, _selection, _w, _h), do: []

  defp bar_ops(peaks, duration, selection, w, h) do
    strip = w - 2 * @mx
    n = max(div(trunc(strip) + 1, @pitch), 1)
    bw = (strip - (n - 1)) / n
    bh = h - 2 * @my
    p = length(peaks)
    tuple = List.to_tuple(peaks)
    loudest = max(Enum.max(peaks), 1)

    for i <- 0..(n - 1) do
      first = div(i * p, n)
      last = max(first, div((i + 1) * p, n) - 1)
      peak = Enum.reduce(first..last, 0, fn j, acc -> max(acc, elem(tuple, j)) end)
      bar_h = max(peak / loudest, 0.04) * bh
      mid_ms = (i + 0.5) / n * duration

      color =
        case selection do
          {from, to} when mid_ms >= from and mid_ms < to -> Style.fm()
          _ -> @outside_color
        end

      rect(Draw.r1(@mx + i * (bw + 1)), Draw.r1(h / 2 - bar_h / 2), Draw.r1(bw), Draw.r1(bar_h),
        color: color,
        fill: true
      )
    end
  end

  defp selection_ops({from, to}, duration, w, h) do
    left = x_of(from, duration, w) - 2
    right = x_of(to, duration, w) + 2
    hh = min(28, h - 2 * @my)
    hy = Draw.r1(h / 2 - hh / 2)

    [
      rect(Draw.r1(left + 1), 1, Draw.r1(right - left - 2), h - 2,
        color: Style.text(),
        width: 2,
        radius: 5
      ),
      rect(Draw.r1(left - 5), hy, 10, hh, color: Style.text(), fill: true, radius: 4),
      rect(Draw.r1(right - 5), hy, 10, hh, color: Style.text(), fill: true, radius: 4)
    ]
  end

  defp selection_ops(_selection, _duration, _w, _h), do: []

  defp x_of(_ms, 0, _w), do: @mx
  defp x_of(ms, duration, w), do: @mx + ms / duration * (w - 2 * @mx)

  defp ms_at(x, duration, w) do
    round(Draw.clamp((x - @mx) / max(w - 2 * @mx, 1), 0, 1) * duration)
  end
end
