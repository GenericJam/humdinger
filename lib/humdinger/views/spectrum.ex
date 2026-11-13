defmodule Humdinger.Views.Spectrum do
  @moduledoc """
  The Live screen's spectrum heat-map (board `09-spectrum`, box 350 × 470,
  radius 16, `Style.surface/0`): time runs left → right with now at the
  right edge, frequency runs up on a log axis from 80 Hz (bottom) to
  2400 Hz (top), the band where a singing voice's note and first harmonics
  live.

  ## Data

  `t:data/0`: the engine's spectrum columns (`Humdinger.Audio`, ~30/s,
  oldest first), the pitch trace, the current time and the heard pitch
  (MIDI, fractional). Optional `window_ms` (default 4000) is the visible
  time span; optional `bins_hz` maps a bin index to its centre frequency
  (a list or a 1-arity function, default `Humdinger.Audio.bin_hz/1`).

  ## Drawing

    * Columns sit at their time `t`; a column is as wide as the gap to the
      next one, the newest as wide as the median gap.
    * Bin `i` is the row between the log-space midpoints to its
      neighbours, so rows tile the axis without gaps. Bins whose centre is
      outside 80..2400 Hz are dropped.
    * Each level byte is quantised by `shade/1` to the legend's violet
      ramp or to nothing (the box colour shows through).
    * To keep op counts low (frames re-render up to 30/s), silent cells
      draw nothing, vertically adjacent cells of one shade in a column
      become one rect, and a rect that continues unchanged in the next
      column is widened instead of repeated. A steady sung note therefore
      draws a handful of long bars. 120 columns of a synthetic voice (the
      board's harmonic model: three notes with glides and vibrato) draw
      ≈ 600 ops; with ±20 random jitter on every level byte ≈ 1500
      (host: ~1–2 ms per frame).
    * The box can't clip, so its rounded corners are restored by painting
      the area outside each corner arc in `Style.bg/0`, the screen
      background the board puts the box on.
    * On top: axis labels 100 / 200 / 400 / 800 / 1.6k (mono 10, muted, at
      x 6, y(f) − 5), the pitch trace (3 wide, round, in the current
      pitch's colour, broken where nothing was heard), and harmonic chips
      "note", "×2", "×3" right-aligned 8 from the right edge at
      y(k · f0) − 8. Chips that would leave the box or overlap the chip
      below are dropped.
  """

  import Mob.Canvas

  alias Humdinger.{Audio, Music, Style}
  alias Humdinger.Views.Draw

  @typedoc "One engine spectrum column: 128 level bytes (−90 dBFS → 0 … −10 dBFS → 255)."
  @type column :: %{t: non_neg_integer(), bins: binary()}

  @typedoc """
  `pitch` and trace pitches are MIDI note numbers (fractional), `nil` when
  nothing pitched was heard. Times are ms on the engine's clock.
  """
  @type data :: %{
          required(:columns) => [column()],
          required(:trace) => [{number(), number() | nil}],
          required(:now_ms) => number(),
          required(:pitch) => number() | nil,
          optional(:window_ms) => pos_integer(),
          optional(:bins_hz) => [number()] | (non_neg_integer() -> number())
        }

  @f_lo 80
  @f_hi 2400
  @radius 16
  @default_window 4000

  # Ramp, quiet → loud (the board's legend), and the lowest level byte that
  # takes each shade. Bytes are (dBFS + 90) · 255 / 80, so the thresholds
  # are −62, −54, −46, −38 and −30 dBFS: 8 dB per step. A hummed or sung
  # note close to the phone peaks around −25…−35 dBFS at the fundamental
  # with harmonics falling off from there, which spreads a voice over the
  # whole ramp as on the board (white note, bright ×2, darker upper
  # harmonics); room noise below −62 dBFS draws nothing.
  @ramp [0xFF2A2240, 0xFF3E2F7A, 0xFF6A52C9, 0xFFB9A2FF, 0xFFF3EFF8]
  @thresholds [89, 115, 140, 166, 191]

  @axis [{100, "100"}, {200, "200"}, {400, "400"}, {800, "800"}, {1600, "1.6k"}]
  @chips [{1, "note"}, {2, "×2"}, {3, "×3"}]
  @chip_h 14

  @doc """
  The ramp colour for a level byte (0..255), or `nil` for levels too quiet
  to draw. Louder levels never map to a darker shade; 255 is the brightest.
  """
  @spec shade(0..255) :: non_neg_integer() | nil
  def shade(level) do
    @thresholds
    |> Enum.zip(@ramp)
    |> Enum.reduce(nil, fn {min, color}, acc -> if level >= min, do: color, else: acc end)
  end

  @doc "The legend's five ramp colours, quiet → loud."
  @spec ramp() :: [non_neg_integer()]
  def ramp, do: @ramp

  @doc "Canvas y of frequency `hz` in a box `h` tall (80 Hz at the bottom, 2400 Hz at the top)."
  @spec y_of_hz(number(), number()) :: float()
  def y_of_hz(hz, h) do
    l0 = :math.log(@f_lo)
    h - (:math.log(hz) - l0) / (:math.log(@f_hi) - l0) * h
  end

  @doc """
  Ops for the heat-map in a `w` × `h` box (board: 350 × 470). See the
  moduledoc for layout.
  """
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    columns = Map.get(data, :columns) || []
    trace = Map.get(data, :trace) || []
    now = Map.get(data, :now_ms) || 0
    window = Map.get(data, :window_ms) || @default_window
    pitch = Map.get(data, :pitch)
    x_of = fn t -> w - (now - t) / window * w end

    List.flatten([
      rect(0, 0, w, h, color: Style.surface(), fill: true, radius: @radius),
      cell_ops(columns, rows(Map.get(data, :bins_hz), h), x_of, w),
      corner_masks(w, h),
      axis_ops(h),
      trace_ops(trace, trace_color(pitch, trace), x_of, w, h),
      chip_ops(pitch, w, h)
    ])
  end

  @doc """
  The legend under the box: five 18 × 10 squares, 2 apart, quiet → loud,
  vertically centred at x 0 (the "quiet → loud" text stays native). Needs
  a canvas at least 98 × 10.
  """
  @spec legend_ops(number(), number()) :: [map()]
  def legend_ops(_w, h) do
    y = Draw.r1((h - 10) / 2)

    @ramp
    |> Enum.with_index()
    |> Enum.map(fn {color, i} -> rect(i * 20, y, 18, 10, color: color, fill: true) end)
  end

  # ── Cells ───────────────────────────────────────────────────────────────

  # In-range bins as {index, top_y, bottom_y}, lowest frequency first.
  defp rows(bins_hz, h) do
    hz = bin_hz_fun(bins_hz)
    n = Audio.spectrum_bins()
    centres = for i <- 0..(n - 1), do: hz.(i)

    edges =
      centres
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> :math.sqrt(a * b) end)

    [c0, c1 | _] = centres
    [cl, cm | _] = Enum.reverse(centres)
    lower = [c0 * c0 / :math.sqrt(c0 * c1) | edges]
    upper = edges ++ [cl * cl / :math.sqrt(cl * cm)]

    [centres, lower, upper]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.filter(fn {{c, _, _}, _} -> c >= @f_lo and c <= @f_hi end)
    |> Enum.map(fn {{_c, lo, hi}, i} ->
      {i, Draw.clamp(y_of_hz(hi, h), 0, h), Draw.clamp(y_of_hz(lo, h), 0, h)}
    end)
  end

  defp bin_hz_fun(nil), do: &Audio.bin_hz/1
  defp bin_hz_fun(f) when is_function(f, 1), do: f

  defp bin_hz_fun(list) when is_list(list) do
    t = List.to_tuple(list)
    last = tuple_size(t) - 1
    fn i -> if i <= last, do: elem(t, i), else: elem(t, last) * :math.pow(2, (i - last) / 20) end
  end

  # Columns → rects. Runs are {top_row, bottom_row, shade}; a run equal to
  # one in the previous column whose rect ends where this column starts is
  # extended instead of drawn again.
  defp cell_ops([], _rows, _x_of, _w), do: []

  defp cell_ops(columns, rows, x_of, w) do
    period = median_period(columns)
    ends = Enum.map(Enum.drop(columns, 1), & &1.t) ++ [List.last(columns).t + period]

    {open, done} =
      columns
      |> Enum.zip(ends)
      |> Enum.reduce({%{}, []}, fn {col, t_end}, {open, done} ->
        x0 = max(x_of.(col.t), 0)
        x1 = min(x_of.(t_end), w)

        if x1 <= x0 do
          {open, done}
        else
          runs = column_runs(col.bins, rows)
          extend(runs, x0, x1, open, done)
        end
      end)

    Enum.map(Map.to_list(open) ++ done, &cell_rect(&1, w))
  end

  defp extend(runs, x0, x1, open, done) do
    next =
      Map.new(runs, fn run ->
        case open do
          %{^run => {ox0, ox1}} when abs(ox1 - x0) < 0.01 -> {run, {ox0, x1}}
          _ -> {run, {x0, x1}}
        end
      end)

    closed = for {run, span} <- open, Map.get(next, run) |> closed?(span), do: {run, span}
    {next, closed ++ done}
  end

  defp closed?(nil, _span), do: true
  defp closed?({nx0, _}, {ox0, _}), do: nx0 != ox0

  defp cell_rect({{top, bottom, color}, {x0, x1}}, w) do
    rect(
      Draw.r1(x0),
      Draw.r1(top),
      Draw.r1(min(x1 - x0 + 0.5, w - x0)),
      Draw.r1(bottom - top + 0.5),
      color: color,
      fill: true
    )
  end

  # Runs of equal shade over adjacent bins, as {top_y, bottom_y, colour}.
  defp column_runs(bins, rows) when is_binary(bins) do
    size = byte_size(bins)

    rows
    |> Enum.reduce([], fn {i, top, bottom}, acc ->
      color = if i < size, do: shade(:binary.at(bins, i))

      case {color, acc} do
        {nil, _} -> [:gap | acc]
        {c, [{_t, b, c} | rest]} -> [{top, b, c} | rest]
        {c, _} -> [{top, bottom, c} | acc]
      end
    end)
    |> Enum.reject(&(&1 == :gap))
  end

  defp column_runs(_bins, _rows), do: []

  defp median_period([_]), do: 33

  defp median_period(columns) do
    gaps =
      columns
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b.t - a.t end)
      |> Enum.sort()

    max(Enum.at(gaps, div(length(gaps), 2)), 1)
  end

  # Paint the screen background outside the box's corner arcs.
  defp corner_masks(w, h) do
    r = @radius
    arc = for i <- 0..6, do: :math.pi() / 2 * i / 6

    [
      {0, 0, r, r, -1, -1},
      {w, 0, w - r, r, 1, -1},
      {w, h, w - r, h - r, 1, 1},
      {0, h, r, h - r, -1, 1}
    ]
    |> Enum.map(fn {cx, cy, ax, ay, sx, sy} ->
      points =
        Enum.map(arc, fn a ->
          {Draw.r1(ax + sx * r * :math.cos(a)), Draw.r1(ay + sy * r * :math.sin(a))}
        end)

      path([{cx, cy} | points], color: Style.bg(), fill: true)
    end)
  end

  # ── Overlays ────────────────────────────────────────────────────────────

  defp axis_ops(h) do
    for {f, label} <- @axis, y = Float.round(y_of_hz(f, h) - 5), y >= 0, y + 10 <= h do
      text(6, y, label,
        color: Style.muted(),
        size: 10,
        weight: :semibold,
        family: Style.font_family(:mono_semibold)
      )
    end
  end

  defp trace_color(pitch, _trace) when is_number(pitch), do: Style.pitch_color(round(pitch))

  defp trace_color(nil, trace) do
    case trace |> Enum.reverse() |> Enum.find(fn {_t, p} -> is_number(p) end) do
      {_t, p} -> Style.pitch_color(round(p))
      nil -> Style.muted()
    end
  end

  # Trace points inside the window and the axis, split where nothing was
  # heard; points closer than 1.5 dp in x to the last kept one are skipped.
  defp trace_ops(trace, color, x_of, w, h) do
    trace
    |> Enum.map(fn {t, p} -> {x_of.(t), if(is_number(p), do: Music.midi_to_hz(p))} end)
    |> Enum.reject(fn {x, _hz} -> x < 0 or x > w end)
    |> Enum.reduce([[]], &trace_step(&1, &2, h))
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
    |> Enum.map(fn
      [{x, y}] -> circle(x, y, 1.5, color: color, fill: true)
      seg -> path(Enum.reverse(seg), color: color, width: 3, cap: :round, join: :round)
    end)
  end

  defp trace_step({_x, hz}, [seg | _] = segs, _h) when hz == nil or hz < @f_lo or hz > @f_hi,
    do: if(seg == [], do: segs, else: [[] | segs])

  defp trace_step({x, _hz}, [[{lx, _} | _] | _] = segs, _h) when x - lx < 1.5, do: segs

  defp trace_step({x, hz}, [seg | rest], h),
    do: [[{Draw.r1(x), Draw.r1(y_of_hz(hz, h))} | seg] | rest]

  defp chip_ops(pitch, w, h) when is_number(pitch) do
    f0 = Music.midi_to_hz(pitch)

    @chips
    |> Enum.map(fn {k, label} -> {label, Float.round(y_of_hz(k * f0, h) - 8), k} end)
    |> Enum.reduce({[], nil}, fn {label, y, k}, {acc, last_top} ->
      fits = y >= 0 and y + @chip_h <= h and (last_top == nil or y + @chip_h <= last_top)
      if fits, do: {[chip(label, k, y, w) | acc], y}, else: {acc, last_top}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp chip_ops(_pitch, _w, _h), do: []

  defp chip(label, k, y, w) do
    cw = Draw.r1(Draw.text_width(label, 10) + 10)
    color = if k == 1, do: Style.text(), else: Style.text_2()

    [
      rect(Draw.r1(w - 8 - cw), y, cw, @chip_h, color: Style.bg(), fill: true, radius: 5),
      text(w - 13, y + 2, label,
        color: color,
        size: 10,
        anchor: :end,
        weight: :semibold,
        family: Style.font_family(:mono_semibold)
      )
    ]
  end
end
