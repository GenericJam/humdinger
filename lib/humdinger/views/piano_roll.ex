defmodule Humdinger.Views.PianoRoll do
  @moduledoc """
  The phrase editor's piano roll: Review (`design/boards/06-record_review.html`,
  350×312 in `design/shots/record_review.webp`) and Import
  (`design/boards/12-import_audio.html`, the same editor at 350×210 in
  `design/shots/import_audio.webp`).

  Layout:

  - One row per note of the scale (all twelve with a chromatic or `nil`
    scale) over the phrase's range, plus any note outside the scale so every
    note has a row, plus padding rows: at least one each side, more until
    rows are at most 26 dp, filling the height (Review's 12 rows of 26); a
    third of them go above, the rest below, as on the board (2 above, 4
    below). Highest at the top, striped #221F2D / #1F1C29, labelled
    in JetBrains Mono #A9A3B8 (10 pt, or 9 pt when rows are under 23 dp as
    on Import). The label column is 36 dp wide (30 for short rows); time
    runs from there to 8 dp from the right edge, 0 to `duration_ms`.
  - Beat lines #34304A, 1 dp per beat and 2 dp per bar, from the tempo.
  - The sung pitch, white at opacity 0.35, 2 dp wide, broken where unvoiced;
    a pitch between two rows sits between them in proportion to semitones.
  - Note blocks row − 4 high (r6, r5 on short rows) in the pitch colour:
    x = x0 + start·scale + 1, width = dur·scale − 3. Unsure notes fade to
    opacity 0.4 and a "N unsure · faded" chip (warn on #14121A) sits
    bottom-right. The selected note gets a 2 dp white ring and two 6 dp
    white handles (row + 4 high, r3) centred on its ends.

  `layout/3` exposes this geometry and `hit/5` resolves a touch (canvas-local,
  from `on_drag`) to a note end, a note body, or an empty spot. Edge zones
  reach 6 dp outside a block and up to 12 dp inside (a third of the block
  for short ones), so each is at least 12 dp wide and covers its handle; the
  selected note wins where blocks overlap, then the topmost drawn.
  """

  import Mob.Canvas

  alias Humdinger.{Music, Scale, Style}
  alias Humdinger.Views.{Draw, RollRows}

  @radius 16
  @right_pad 8
  @max_row_h 26
  @faded 0.4
  @grid 0xFF34304A

  @typedoc "A phrase note; `unsure` (optional) marks a doubtful detection."
  @type note :: %{
          required(:start_ms) => number(),
          required(:dur_ms) => number(),
          required(:midi) => integer(),
          optional(:unsure) => boolean()
        }

  @typedoc """
  - `notes` — see `t:note/0`; `selected` indexes into it.
  - `trace` — `{t_ms, pitch | nil}` samples of what was sung (fractional MIDI).
  - `scale` — the phrase's scale; `nil` means chromatic.
  - `tempo_bpm`, `beats_per_bar` (default 4) — for the beat grid.
  - `duration_ms` — optional; default the last note's end.
  """
  @type data :: %{
          required(:notes) => [note()],
          optional(:trace) => [{number(), number() | nil}],
          optional(:scale) => Scale.t() | nil,
          optional(:tempo_bpm) => number() | nil,
          optional(:beats_per_bar) => pos_integer(),
          optional(:selected) => non_neg_integer() | nil,
          optional(:duration_ms) => number()
        }

  @typedoc "A row: its note and its top edge."
  @type row :: %{midi: integer(), y: float()}

  @typedoc "A note block's rectangle; `index` is the note's position in `notes`."
  @type block :: %{
          index: non_neg_integer(),
          x: float(),
          y: float(),
          w: float(),
          h: float(),
          midi: integer(),
          unsure: boolean()
        }

  @typedoc """
  The roll's geometry. `rows` run top to bottom, each `row_h` high from
  y = 0. Time maps to x as `x0 + ms · px_per_ms`.
  """
  @type layout :: %{
          w: number(),
          h: number(),
          x0: number(),
          row_h: float(),
          rows: [row()],
          px_per_ms: float(),
          duration_ms: number(),
          beat_ms: float() | nil,
          beats_per_bar: pos_integer(),
          blocks: [block()],
          selected: non_neg_integer() | nil
        }

  @type hit ::
          {:note, non_neg_integer(), :start | :end | :body}
          | {:empty, %{ms: float(), midi: integer()}}
          | :none

  # ── Layout ──────────────────────────────────────────────────────────────

  @doc "The roll's geometry at `w`×`h`; see `t:layout/0`."
  @spec layout(data(), number(), number()) :: layout()
  def layout(data, w, h) do
    notes = Map.get(data, :notes) || []
    trace = Map.get(data, :trace) || []
    scale = Map.get(data, :scale) || Scale.chromatic()

    midis = row_midis(notes, trace, scale, h)
    row_h = h / length(midis)
    short? = row_h < 23
    x0 = if short?, do: 30, else: 36
    duration = duration(data, notes, trace)
    px_per_ms = (w - x0 - @right_pad) / duration
    rows = midis |> Enum.with_index() |> Enum.map(fn {m, i} -> %{midi: m, y: i * row_h} end)
    bpm = Map.get(data, :tempo_bpm)

    layout = %{
      w: w,
      h: h,
      x0: x0,
      row_h: row_h,
      rows: rows,
      px_per_ms: px_per_ms,
      duration_ms: duration,
      beat_ms: if(is_number(bpm) and bpm > 0, do: 60_000 / bpm),
      beats_per_bar: Map.get(data, :beats_per_bar) || 4,
      blocks: [],
      selected: valid_index(Map.get(data, :selected), notes)
    }

    %{layout | blocks: blocks(layout, notes)}
  end

  @doc "The x of a time (ms from the phrase start)."
  @spec x_of(layout(), number()) :: float()
  def x_of(%{x0: x0, px_per_ms: s}, ms), do: x0 + ms * s

  @doc "The time (ms from the phrase start) at an x."
  @spec ms_at(layout(), number()) :: float()
  def ms_at(%{x0: x0, px_per_ms: s}, x), do: (x - x0) / s

  @doc """
  The y of a (fractional) pitch: a row's centre for its note, in proportion
  between rows otherwise, extrapolated beyond the first and last rows.
  """
  @spec y_of(layout(), number()) :: float()
  def y_of(%{rows: rows, row_h: rh}, pitch) do
    pairs =
      rows
      |> Enum.map(fn %{midi: m, y: y} -> {m, y + rh / 2} end)
      |> Enum.chunk_every(2, 1, :discard)

    [{m_hi, y_hi}, {m_lo, y_lo}] =
      Enum.find(pairs, List.last(pairs), fn [_hi, {m_lo, _}] -> pitch >= m_lo end)

    y_hi + (m_hi - pitch) / (m_hi - m_lo) * (y_lo - y_hi)
  end

  @doc "The note of the row at `y`, or `nil` above or below the rows."
  @spec midi_at(layout(), number()) :: integer() | nil
  def midi_at(%{rows: rows, row_h: rh}, y) do
    i = floor(y / rh)
    if y >= 0 and i < length(rows), do: Enum.at(rows, i).midi
  end

  # Row notes, highest first: the scale (plus the notes themselves) over the
  # notes' range, then padding rows: a third above (at least one), the
  # rest below.
  defp row_midis(notes, trace, scale, h) do
    {lo, hi} = range(notes, trace)
    note_set = MapSet.new(notes, & &1.midi)
    range_rows = for m <- hi..lo//-1, Scale.contains?(scale, m) or m in note_set, do: m
    pad = max(2, ceil(h / @max_row_h) - length(range_rows))
    above = max(1, div(pad, 3))

    Enum.reverse(scale_notes(scale, hi + 1, 1, above)) ++
      range_rows ++ scale_notes(scale, lo - 1, -1, pad - above)
  end

  defp range([_ | _] = notes, _trace), do: Enum.min_max(Enum.map(notes, & &1.midi))

  defp range([], trace) do
    case for({_t, p} <- trace, is_number(p), do: p) do
      [] -> {60, 72}
      pitches -> {floor(Enum.min(pitches)), ceil(Enum.max(pitches))}
    end
  end

  defp scale_notes(_scale, _from, _step, 0), do: []

  defp scale_notes(scale, from, step, n) do
    from
    |> Stream.iterate(&(&1 + step))
    |> Stream.filter(&Scale.contains?(scale, &1))
    |> Enum.take(n)
  end

  defp duration(data, notes, trace) do
    note_end = notes |> Enum.map(&(&1.start_ms + &1.dur_ms)) |> Enum.max(fn -> 0 end)
    trace_end = trace |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)
    bpm = Map.get(data, :tempo_bpm)

    cond do
      is_number(data[:duration_ms]) and data[:duration_ms] > 0 -> data[:duration_ms]
      note_end > 0 -> note_end
      trace_end > 0 -> trace_end
      is_number(bpm) and bpm > 0 -> 2 * (Map.get(data, :beats_per_bar) || 4) * 60_000 / bpm
      true -> 4000
    end
  end

  defp valid_index(i, notes) when is_integer(i) and i >= 0 and i < length(notes), do: i
  defp valid_index(_i, _notes), do: nil

  defp blocks(%{row_h: rh, px_per_ms: s} = layout, notes) do
    row_y = Map.new(layout.rows, &{&1.midi, &1.y})
    bh = max(rh - 4, rh * 0.7)

    notes
    |> Enum.with_index()
    |> Enum.map(fn {%{start_ms: start, dur_ms: dur, midi: m} = note, i} ->
      %{
        index: i,
        x: x_of(layout, start) + 1,
        y: Map.fetch!(row_y, m) + (rh - bh) / 2,
        w: max(dur * s - 3, 2),
        h: bh,
        midi: m,
        unsure: Map.get(note, :unsure, false) == true
      }
    end)
  end

  # ── Hit-test ────────────────────────────────────────────────────────────

  @doc """
  What a touch at canvas-local (`x`, `y`) lands on, given the data or a
  `layout/3` of it at `w`×`h`:

  - `{:note, index, :start | :end | :body}` on a note block or its handles;
  - `{:empty, %{ms: ms, midi: midi}}` elsewhere in the roll, `midi` being
    the row under the finger (so a drag snaps to rows) and `ms` the time
    under it (not below 0);
  - `:none` in the label column or outside the canvas.
  """
  @spec hit(layout() | data(), number(), number(), number(), number()) :: hit()
  def hit(%{row_h: _, blocks: _} = layout, _w, _h, x, y), do: hit_layout(layout, x, y)
  def hit(data, w, h, x, y), do: data |> layout(w, h) |> hit_layout(x, y)

  defp hit_layout(%{w: w, h: h} = layout, x, y) do
    cond do
      x < 0 or x > w or y < 0 or y > h -> :none
      block = hit_block(layout, x, y) -> zone(block, x)
      x < layout.x0 -> :none
      midi = midi_at(layout, y) -> {:empty, %{ms: max(ms_at(layout, x), 0.0), midi: midi}}
      true -> :none
    end
  end

  # A block's touch area: its row (plus the handles' 2 dp overhang) high,
  # 6 dp beyond each end.
  defp hit_block(%{blocks: blocks, selected: sel, row_h: rh}, x, y) do
    reach = (rh + 4) / 2
    ordered = Enum.filter(blocks, &(&1.index == sel)) ++ Enum.reverse(blocks)

    Enum.find(ordered, fn b ->
      cy = b.y + b.h / 2
      x >= b.x - 6 and x <= b.x + b.w + 6 and abs(y - cy) <= reach
    end)
  end

  defp zone(b, x) do
    edge = b.w |> Kernel./(3) |> min(12) |> max(6)

    cond do
      x < b.x + edge -> {:note, b.index, :start}
      x > b.x + b.w - edge -> {:note, b.index, :end}
      true -> {:note, b.index, :body}
    end
  end

  # ── Drawing ─────────────────────────────────────────────────────────────

  @doc "Canvas ops for the roll at `w`×`h`."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    layout = layout(data, w, h)

    [RollRows.box(w, h, @radius)] ++
      rows(layout) ++
      grid(layout) ++
      trace(layout, Map.get(data, :trace) || []) ++
      Enum.map(layout.blocks, &block/1) ++
      selection(layout) ++
      chip(layout)
  end

  defp rows(%{rows: rows, row_h: rh, w: w, h: h}) do
    size = if rh < 23, do: 9, else: 10

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{midi: m, y: y}, i} ->
      band = RollRows.band(y, rh, w, h, @radius, RollRows.stripe(i))

      if rh >= 10,
        do:
          band ++
            [RollRows.label(6, y + (rh - size) / 2, Music.note_name(m), size, Style.muted())],
        else: band
    end)
  end

  defp grid(%{beat_ms: nil}), do: []

  # Every beat, or only bars when beats would be under 4 dp apart; nothing
  # when even bars would be.
  defp grid(%{beat_ms: beat, beats_per_bar: bpb, px_per_ms: s, duration_ms: d} = layout) do
    step = if beat * s >= 4, do: 1, else: bpb

    if beat * step * s < 4,
      do: [],
      else: Enum.map(0..floor(d / beat + 1.0e-6)//step, &beat_line(layout, &1))
  end

  defp beat_line(%{beat_ms: beat, beats_per_bar: bpb, h: h} = layout, k) do
    width = if rem(k, bpb) == 0, do: 2, else: 1
    rect(Draw.r1(x_of(layout, k * beat)), 0, width, h, color: @grid, fill: true)
  end

  defp trace(%{w: w, h: h, row_h: rh} = layout, samples) do
    samples
    |> RollRows.runs(&x_of(layout, &1), &y_of(layout, &1))
    |> RollRows.trace_ops(w, h, width: if(rh < 23, do: 1.6, else: 2), opacity: 0.35)
  end

  defp block_radius(%{h: bh}), do: min(if(bh < 19, do: 5, else: 6), bh / 2)

  defp block(b) do
    opts = [color: Style.pitch_color(b.midi), fill: true, radius: block_radius(b)]
    opts = if b.unsure, do: Keyword.put(opts, :opacity, @faded), else: opts
    rect(Draw.r1(b.x), Draw.r1(b.y), Draw.r1(b.w), Draw.r1(b.h), opts)
  end

  defp selection(%{selected: nil}), do: []

  defp selection(%{selected: i, blocks: blocks, row_h: rh}) do
    b = Enum.at(blocks, i)
    hy = b.y + b.h / 2 - (rh + 4) / 2

    handle =
      &rect(Draw.r1(&1 - 3), Draw.r1(hy), 6, Draw.r1(rh + 4),
        color: Style.text(),
        fill: true,
        radius: 3
      )

    [
      rect(Draw.r1(b.x + 1), Draw.r1(b.y + 1), Draw.r1(b.w - 2), Draw.r1(b.h - 2),
        color: Style.text(),
        width: 2,
        radius: block_radius(b) - 1
      ),
      handle.(b.x),
      handle.(b.x + b.w)
    ]
  end

  defp chip(%{blocks: blocks, w: w, h: h}) do
    case Enum.count(blocks, & &1.unsure) do
      0 ->
        []

      n ->
        label = "#{n} unsure · faded"
        cw = Draw.text_width(label, 10) + 16
        cx = w - 8 - cw
        cy = h - 8 - 20

        [
          rect(Draw.r1(cx), cy, Draw.r1(cw), 20, color: Style.bg(), fill: true, radius: 8),
          text(Draw.r1(cx + 8), cy + 5, label,
            color: Style.warn(),
            size: 10,
            weight: :semibold,
            family: Style.font_family(:mono_semibold)
          )
        ]
    end
  end
end
