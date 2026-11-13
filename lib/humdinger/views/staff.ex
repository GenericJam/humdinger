defmodule Humdinger.Views.Staff do
  @moduledoc """
  Sheet music: a phrase engraved on a paper card, from the Notation layout
  (clef, key, time, measures of positioned notes and rests). Matches the
  sheet music board (`design/boards/10-sheet_music.html`,
  `design/shots/sheet_music.webp`): at 350 wide the card, staff and systems
  land where the board's do.

  ## Layout

  The canvas is the card: paper `Style.paper/0`, radius 16, ink
  `Style.paper_ink/0`, padding 6 at the sides, 10 on top and 6 below (the
  board's). Staff lines run from x 14 to `w - 14`, 1.2 thick, one staff
  space (G) = 12 apart; `staff_y/2` maps a staff position (diatonic steps
  from the middle line, + up) to y.

  Every system starts with a 1.4 barline, the clef and the key signature
  (sharps F C G D A E B, flats B E A D G C F at their standard places for
  each clef); the first one also carries the time signature. Measures are
  as wide as their content needs (space per item grows with its duration,
  slower than proportionally, as engravers do, plus room for accidentals,
  dots and flags); as many
  as fit go on a system, which is then stretched to the full width. The
  last system keeps its natural width unless it is at least 70 % full, and
  ends with a thin + thick final barline. Systems sit 150 apart (the
  board's), further when ledger notes, stems or note names need more room;
  `height/2` gives the canvas height the screen should use.

  Noteheads are ellipses rx 7, ry 5.2 (hollow for halves and wholes);
  stems 1.6 × 42, up on the right below the middle line, down on the left
  otherwise (a beam group follows the note furthest from the middle line;
  stems on ledger notes reach the middle line). Beams are 5 thick
  parallelograms from the first to the last stem of a `beam` :begin…:end
  run, sloped with the notes but at most one staff space; sixteenths get a
  second beam (or a stub). Unbeamed eighths and sixteenths get flags.
  Ledger lines (22 wide) for |staff_pos| ≥ 6, dots (r 2.2, x + 12, lifted
  to the space above when the note sits on a line), accidentals left of the
  head, ties curving away from the stems (split across a system break),
  and a bracket with a "3" over triplets.

  Android's canvas ignores `family:`, so clefs, accidentals, rests and flags
  are filled polygons from `Humdinger.Views.StaffGlyphs`, not font glyphs.

  With `note_names: true` every note gets a dot (r 9, its pitch colour at
  58 % lightness) 34 below the staff with its letter in ink, as on the
  board — the learning aid.

  Missing layout or no measures draws the card with an empty staff.
  """

  import Mob.Canvas

  alias Humdinger.Music
  alias Humdinger.Style
  alias Humdinger.Views.{Draw, StaffGlyphs}

  @typedoc """
  A note or rest. `beat` is its start within the measure in quarters;
  `staff_pos` is diatonic steps from the middle line (treble B4, bass D3).
  Pitch fields, `accidental` (the printed one), ties and beams are nil /
  false for rests.
  """
  @type item :: %{
          :kind => :note | :rest,
          :beat => number(),
          :type => :whole | :half | :quarter | :eighth | :sixteenth,
          :dots => 0 | 1,
          :tuplet => nil | {3, 2},
          optional(:midi) => integer() | nil,
          optional(:step) => String.t() | nil,
          optional(:octave) => integer() | nil,
          optional(:alter) => -1 | 0 | 1 | nil,
          optional(:accidental) => nil | :sharp | :flat | :natural,
          optional(:staff_pos) => integer() | nil,
          optional(:tie_to_next) => boolean(),
          optional(:beam) => nil | :begin | :continue | :end,
          optional(:note_index) => integer() | nil
        }

  @type measure :: %{index: non_neg_integer(), items: [item()]}

  @type layout :: %{
          clef: :treble | :bass,
          key_fifths: integer(),
          time: {pos_integer(), pos_integer()} | nil,
          measures: [measure()]
        }

  @type data :: %{optional(:layout) => layout() | nil, optional(:note_names) => boolean()}

  @typedoc """
  A wrapped line of music: staff top y, staff x extent (`left`..`right`)
  and the `index`es of the measures on it.
  """
  @type system :: %{top: number(), left: number(), right: number(), measures: [integer()]}

  @g 12
  @pad_top 10
  @pad_bottom 6
  @left 14
  @radius 16
  @line_w 1.2
  @bar_w 1.4
  @stem_w 1.6
  @stem_len 42
  @min_stem 32
  @beam_w 5
  @beam_gap 8
  @lead 20
  @min_gap 18
  # Room for the r 9 name dots under neighbouring notes.
  @named_gap 21
  @min_above 40
  @min_below 110
  @names_below 34
  @stretch_at 0.7

  @sharp_pos %{treble: [4, 1, 5, 2, -1, 3, 0], bass: [2, -1, 3, 0, -3, 1, -2]}
  @flat_pos %{treble: [0, 3, -1, 2, -2, 1, -3], bass: [-2, 1, -3, 0, -4, -1, -5]}

  @durations %{whole: 4.0, half: 2.0, quarter: 1.0, eighth: 0.5, sixteenth: 0.25}

  # ── Public ──────────────────────────────────────────────────────────────

  @doc "Draw ops for the paper card and its systems on a `w` × `h` canvas."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    [
      rect(0, 0, w, h, color: Style.paper(), fill: true, radius: @radius)
      | Enum.flat_map(build(data, w).systems, & &1.ops)
    ]
  end

  @doc "The canvas height the wrapped systems need at width `w`."
  @spec height(data(), number()) :: pos_integer()
  def height(data, w), do: build(data, w).height

  @doc "Where the systems fall at width `w` (see `t:system/0`)."
  @spec systems(data(), number()) :: [system()]
  def systems(data, w), do: Enum.map(build(data, w).systems, &Map.delete(&1, :ops))

  @doc """
  The y of staff position `pos` on a staff whose top line is at `top`:
  0 is the middle line, ±4 the outer lines, one step is half a space.
  """
  @spec staff_y(number(), number()) :: float()
  def staff_y(top, pos), do: top + 2 * @g - pos * @g / 2

  # ── Build ───────────────────────────────────────────────────────────────

  defp build(data, w) do
    s = normalize(data)
    right = w - @left

    rows =
      s.measures
      |> Enum.map(&measure_metrics(&1, if(s.names?, do: @named_gap, else: @min_gap)))
      |> wrap(s, right)
      |> Enum.map(&with_stems/1)
      |> link_ties()

    stack(rows, s)
  end

  defp normalize(data) when is_map(data) do
    layout = Map.get(data, :layout) || %{}

    %{
      clef: if(Map.get(layout, :clef) == :bass, do: :bass, else: :treble),
      fifths: (Map.get(layout, :key_fifths) || 0) |> round() |> Draw.clamp(-7, 7),
      time: Map.get(layout, :time),
      names?: Map.get(data, :note_names) == true,
      measures:
        layout
        |> Map.get(:measures)
        |> Kernel.||([])
        |> Enum.with_index()
        |> Enum.map(fn {m, i} ->
          %{
            index: Map.get(m, :index) || i,
            items:
              m |> Map.get(:items) |> Kernel.||([]) |> Enum.sort_by(&(Map.get(&1, :beat) || 0))
          }
        end)
    }
  end

  defp normalize(_), do: normalize(%{})

  # ── Horizontal layout ───────────────────────────────────────────────────

  # Natural spacing after an item: 20 for a sixteenth, +14 per doubling
  # (eighth 34, quarter 48, half 62, whole 76; the board uses 32 and 52) —
  # engravers grow space with duration, but far less than proportionally.
  defp spacing(quarters), do: max(20 + 14 * :math.log2(max(quarters, 1.0e-3) * 4), 14.0)

  defp duration(item) do
    base = Map.get(@durations, item[:type], 1.0)
    dotted = if (item[:dots] || 0) > 0, do: base * 1.5, else: base
    if item[:tuplet], do: dotted * 2 / 3, else: dotted
  end

  defp note?(item), do: item[:kind] == :note

  defp pre_room(item), do: if(note?(item) and item[:accidental] != nil, do: 12, else: 0)

  defp post_room(item) do
    dot = if (item[:dots] || 0) > 0, do: 8, else: 0

    flag =
      if note?(item) and item[:type] in [:eighth, :sixteenth] and item[:beam] == nil,
        do: 6,
        else: 0

    dot + flag
  end

  # A measure's lead (its start → the first head) and the gap after each
  # item (the last one to the barline), each as {natural, minimum}: the
  # minimum keeps heads, dots, flags, accidentals and name dots apart when
  # a system has to be squeezed.
  defp measure_metrics(%{items: []} = m, _min_gap),
    do: %{measure: m, lead: 0.0, gaps: [{60.0, 30.0}], width: 60.0}

  defp measure_metrics(%{items: [first | _] = items} = m, min_gap) do
    lead = @lead + pre_room(first) * 1.0
    nexts = tl(items) ++ [nil]

    gaps =
      Enum.zip_with(items, nexts, fn
        item, nil ->
          min = 14.0 + post_room(item)
          {max(spacing(duration(item)), min), min}

        item, next ->
          min = (min_gap + post_room(item) + pre_room(next)) * 1.0
          {max(spacing(duration(item)), min), min}
      end)

    %{
      measure: m,
      lead: lead,
      gaps: gaps,
      width: lead + (gaps |> Enum.map(&elem(&1, 0)) |> Enum.sum())
    }
  end

  defp key_step(fifths), do: if(fifths > 0, do: 10, else: 9)

  defp key_end(%{fifths: 0}), do: @left + 36
  defp key_end(%{fifths: n}), do: @left + 40 + abs(n) * key_step(n)

  defp time_x(s), do: key_end(s) + 12

  defp time_digits(%{time: {n, d}}), do: max(String.length("#{n}"), String.length("#{d}"))

  defp header_end(%{time: {_, _}} = s, 0), do: time_x(s) + 12 + (time_digits(s) - 1) * 7
  defp header_end(s, _), do: key_end(s)

  defp wrap([], s, right) do
    [%{index: 0, start: header_end(s, 0), right: right, measures: [], last?: true}]
  end

  defp wrap(metrics, s, right), do: wrap(metrics, s, right, 0, [])

  defp wrap([], _s, _right, _i, acc), do: Enum.reverse(acc)

  defp wrap(metrics, s, right, i, acc) do
    start = header_end(s, i)
    {take, rest} = fit(metrics, right - start)
    row = place_row(take, start, right, rest == [], i)
    wrap(rest, s, right, i + 1, [row | acc])
  end

  defp fit([first | rest], avail) do
    {more, left} =
      Enum.reduce_while(rest, {[], first.width}, fn m, {acc, used} ->
        if used + m.width <= avail,
          do: {:cont, {[m | acc], used + m.width}},
          else: {:halt, {acc, used}}
      end)
      |> then(fn {acc, _} -> {Enum.reverse(acc), Enum.drop(rest, length(acc))} end)

    {[first | more], left}
  end

  defp place_row(metrics, start, right, last?, index) do
    avail = right - start
    natural = metrics |> Enum.map(& &1.width) |> Enum.sum()
    leads = metrics |> Enum.map(& &1.lead) |> Enum.sum()
    stretch? = not last? or natural >= @stretch_at * avail

    fit =
      fitter(
        Enum.flat_map(metrics, & &1.gaps),
        if(stretch?, do: avail - leads, else: natural - leads)
      )

    {placed, row_end} =
      metrics
      |> Enum.with_index()
      |> Enum.map_reduce(start, fn {mm, mi}, x ->
        {heads, x_end} =
          Enum.map_reduce(mm.gaps, x + mm.lead, fn gap, hx -> {hx, hx + fit.(gap)} end)

        heads = if whole_rest?(mm.measure), do: [(x + x_end) / 2], else: heads

        items =
          mm.measure.items
          |> Enum.zip(heads)
          |> Enum.map(fn {item, ix} -> %{item: item, x: ix, mi: mi} end)

        {%{index: mm.measure.index, start: x, end: x_end, items: items}, x_end}
      end)

    %{
      index: index,
      start: start,
      right: if(stretch?, do: right, else: row_end),
      measures: placed,
      last?: last?
    }
  end

  # How each {natural, minimum} gap becomes its width so that all of them
  # add up to `target`: stretched in proportion; squeezed first out of the
  # room above each minimum, then (overfull) the minimums scale down too.
  defp fitter(gaps, target) do
    total = gaps |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    mins = gaps |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    slack = total - mins

    cond do
      target >= total -> fn {gap, _} -> gap * target / total end
      total - target <= slack -> fn {gap, min} -> gap - (gap - min) * (total - target) / slack end
      true -> fn {_, min} -> min * max(target, 0.3 * mins) / mins end
    end
  end

  defp whole_rest?(%{items: [%{kind: :rest, type: :whole}]}), do: true
  defp whole_rest?(_), do: false

  # ── Stems, beams, ties (positions only) ─────────────────────────────────

  defp row_items(row), do: Enum.flat_map(row.measures, & &1.items)

  defp pos(p), do: p.item[:staff_pos] || 0

  defp beam_mark(p) do
    if note?(p.item) and p.item[:type] in [:eighth, :sixteenth], do: p.item[:beam]
  end

  # Beam groups: runs :begin (:continue)* :end inside one measure. Broken
  # runs of two or more still beam; a lone note falls back to a flag.
  defp beam_groups(items) do
    {groups, open} =
      Enum.reduce(items, {[], nil}, fn p, {gs, open} ->
        {gs, open} = if open && hd(open).mi != p.mi, do: {close(gs, open), nil}, else: {gs, open}

        case {beam_mark(p), open} do
          {:begin, _} -> {close(gs, open), [p]}
          {:continue, [_ | _]} -> {gs, [p | open]}
          {:end, [_ | _]} -> {close(gs, [p | open]), nil}
          _ -> {close(gs, open), nil}
        end
      end)

    groups |> close(open) |> Enum.reverse()
  end

  defp close(gs, [_, _ | _] = open), do: [Enum.reverse(open) | gs]
  defp close(gs, _), do: gs

  # The note furthest from the middle line decides (ties go down).
  defp stem_dir(notes) do
    ps = Enum.map(notes, &pos/1)
    if -Enum.min(ps) > Enum.max(ps), do: :up, else: :down
  end

  defp with_stems(row) do
    items = row_items(row)
    groups = beam_groups(items)

    groups =
      Enum.map(groups, fn g ->
        dir = stem_dir(g)
        Enum.map(g, &Map.merge(&1, %{dir: dir, beamed?: true}))
      end)

    in_group = groups |> List.flatten() |> Map.new(&{{&1.mi, &1.x}, &1.dir})

    measures =
      Enum.map(row.measures, fn m -> %{m | items: Enum.map(m.items, &with_dir(&1, in_group))} end)

    Map.put(%{row | measures: measures}, :groups, groups)
  end

  defp with_dir(p, in_group) do
    case Map.fetch(in_group, {p.mi, p.x}) do
      {:ok, dir} -> Map.merge(p, %{dir: dir, beamed?: true})
      :error -> Map.merge(p, %{dir: stem_dir([p]), beamed?: false})
    end
  end

  # Ties go to the next note; one crossing a system break is split into an
  # outgoing half (to the end of the staff) and an incoming half.
  defp link_ties(rows) do
    flat =
      for {row, ri} <- Enum.with_index(rows), p <- row_items(row), do: {ri, p}

    links =
      flat
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{ra, a}, {rb, b}] ->
        cond do
          not (note?(a.item) and a.item[:tie_to_next] == true and note?(b.item)) -> []
          ra == rb -> [{{ra, a.mi, a.x}, {:to, b.x}}]
          true -> [{{ra, a.mi, a.x}, :to_end}, {{rb, b.mi, b.x}, :from_start}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, ri} ->
      measures =
        Enum.map(row.measures, fn m ->
          %{
            m
            | items: Enum.map(m.items, &Map.put(&1, :ties, Map.get(links, {ri, &1.mi, &1.x}, [])))
          }
        end)

      %{row | measures: measures}
    end)
  end

  # ── Vertical stacking ───────────────────────────────────────────────────

  defp stack(rows, s) do
    drawn =
      Enum.map(rows, fn row ->
        content = row_ops(row, s)
        {_, low} = extents(content)
        names = if s.names?, do: name_ops(row, max(4 * @g + @names_below, low + 14)), else: []
        all = content ++ names
        {high, low} = extents(all)
        {row, all, max(@min_above, 8 - high), max(@min_below, low + 19)}
      end)

    {systems, bottom} =
      Enum.map_reduce(drawn, {@pad_top, 0}, fn {row, ops, above, below}, {y, prev_below} ->
        top = ceil(y + prev_below + above)

        system = %{
          top: top,
          left: @left,
          right: row.right,
          measures: Enum.map(row.measures, & &1.index),
          ops: Enum.map(ops, &shift(&1, top))
        }

        {system, {top, below}}
      end)
      |> then(fn {systems, {top, below}} -> {systems, top + below} end)

    %{systems: systems, height: ceil(bottom + @pad_bottom)}
  end

  defp extents(ops) do
    ops
    |> Enum.flat_map(&op_ys/1)
    |> Enum.min_max(fn -> {0, 0} end)
  end

  defp op_ys(%{op: :line, y1: a, y2: b}), do: [a, b]
  defp op_ys(%{op: :rect, y: y, h: h}), do: [y, y + h]
  defp op_ys(%{op: :ellipse, y: y, ry: r}), do: [y - r, y + r]
  defp op_ys(%{op: :circle, y: y, r: r}), do: [y - r, y + r]
  defp op_ys(%{op: :text, y: y, size: s}), do: [y, y + s]
  defp op_ys(%{op: :path, points: pts}), do: Enum.map(pts, fn [_, y] -> y end)

  defp shift(%{op: :line} = o, dy), do: %{o | y1: Draw.r1(o.y1 + dy), y2: Draw.r1(o.y2 + dy)}

  defp shift(%{op: :path} = o, dy),
    do: %{o | points: Enum.map(o.points, fn [x, y] -> [x, Draw.r1(y + dy)] end)}

  defp shift(o, dy), do: %{o | y: Draw.r1(o.y + dy)}

  # ── Drawing (staff top at y = 0) ────────────────────────────────────────

  defp ink, do: Style.paper_ink()

  defp row_ops(row, s) do
    items = row_items(row)
    {beam_ops, stem_ends} = beams(row.groups)

    staff(row) ++
      barlines(row) ++
      header(row, s) ++
      Enum.flat_map(items, &item_ops(&1, row, stem_ends)) ++
      beam_ops ++ tuplets(items, stem_ends)
  end

  defp staff(row) do
    for k <- 0..4 do
      rect(@left, Draw.r1(k * @g - @line_w / 2), Draw.r1(row.right - @left), @line_w,
        color: ink(),
        fill: true
      )
    end
  end

  defp bar(x, w),
    do: rect(Draw.r1(x), -@line_w / 2, w, 4 * @g + @line_w, color: ink(), fill: true)

  defp barlines(%{measures: []}), do: [bar(@left, @bar_w)]

  defp barlines(row) do
    inner = row.measures |> Enum.drop(-1) |> Enum.map(&bar(&1.end - @bar_w / 2, @bar_w))

    ending =
      if row.last?,
        do: [bar(row.right - 6 - 3.2 - @bar_w, @bar_w), bar(row.right - 6, 6)],
        else: [bar(row.right - @bar_w, @bar_w)]

    [bar(@left, @bar_w) | inner] ++ ending
  end

  defp header(row, s) do
    clef =
      case s.clef do
        :treble -> StaffGlyphs.treble_clef(@left, 0, ink())
        :bass -> StaffGlyphs.bass_clef(@left, 0, ink())
      end

    [clef | key_signature(s)] ++ if(row.index == 0, do: time_signature(s), else: [])
  end

  defp key_signature(%{fifths: 0}), do: []

  defp key_signature(%{fifths: n, clef: clef}) do
    {kind, places} = if n > 0, do: {:sharp, @sharp_pos[clef]}, else: {:flat, @flat_pos[clef]}

    places
    |> Enum.take(abs(n))
    |> Enum.with_index()
    |> Enum.map(fn {p, i} ->
      StaffGlyphs.accidental(kind, @left + 45 + i * key_step(n), staff_y(0, p), ink())
    end)
  end

  defp time_signature(%{time: {n, d}} = s) do
    x = time_x(s)
    # Digits centred on the 2nd and 4th lines; text y is the top, and a
    # digit's middle sits ~0.575 em below it (ascent 0.93, cap 0.71).
    for {v, line} <- [{n, 1}, {d, 3}] do
      text(x, Draw.r1(line * @g - 0.575 * 24), "#{v}",
        color: ink(),
        size: 24,
        weight: :bold,
        anchor: :center,
        family: Style.font_family(:bold)
      )
    end
  end

  defp time_signature(_), do: []

  # ── Items ───────────────────────────────────────────────────────────────

  defp item_ops(%{item: %{kind: :note}} = p, row, stem_ends) do
    pos = pos(p)
    x = p.x
    y = staff_y(0, pos)

    ledgers(x, pos) ++
      accidental(p.item[:accidental], x, y) ++
      [head(p.item[:type], x, y)] ++
      stem(p, y, stem_ends) ++
      dot(p.item, x + 12, pos) ++
      Enum.map(p.ties, &tie(&1, p, y, row))
  end

  defp item_ops(%{item: %{kind: :rest}} = p, _row, _stem_ends) do
    rest(p.item[:type], p.x) ++ dot(p.item, p.x + 10, 0)
  end

  defp item_ops(_, _, _), do: []

  defp ledgers(x, pos) when abs(pos) >= 6 do
    sign = if pos > 0, do: 1, else: -1

    for l <- (6 * sign)..pos//(2 * sign) do
      rect(Draw.r1(x - 11), Draw.r1(staff_y(0, l) - @line_w / 2), 22, @line_w,
        color: ink(),
        fill: true
      )
    end
  end

  defp ledgers(_, _), do: []

  defp accidental(kind, x, y) when kind in [:sharp, :flat, :natural],
    do: [StaffGlyphs.accidental(kind, x - 16, y, ink())]

  defp accidental(_, _, _), do: []

  defp head(:whole, x, y), do: ellipse(Draw.r1(x), Draw.r1(y), 7.4, 4.6, color: ink(), width: 2.2)

  defp head(:half, x, y),
    do: ellipse(Draw.r1(x), Draw.r1(y), 6.2, 4.4, color: ink(), width: @stem_w)

  defp head(_, x, y), do: ellipse(Draw.r1(x), Draw.r1(y), 7.0, 5.2, color: ink(), fill: true)

  defp stem_x(x, :up), do: x + 5.4
  defp stem_x(x, :down), do: x - 7

  defp stem(%{item: %{type: :whole}}, _y, _ends), do: []

  defp stem(p, y, stem_ends) do
    x = stem_x(p.x, p.dir)

    case Map.fetch(stem_ends, {p.mi, p.x}) do
      {:ok, end_y} ->
        [stem_rect(x, y, end_y)]

      :error ->
        len = if p.item[:type] == :sixteenth, do: @stem_len + 6, else: @stem_len
        mid = staff_y(0, 0)
        end_y = if p.dir == :up, do: min(y - len, mid), else: max(y + len, mid)
        [stem_rect(x, y, end_y) | flags(p.item[:type], x + @stem_w / 2, end_y, p.dir)]
    end
  end

  # Unbeamed eighths get a flag; sixteenths two short ones, 9 apart.
  defp flags(:eighth, x, y, dir), do: [StaffGlyphs.flag(x, y, dir, ink())]

  defp flags(:sixteenth, x, y, dir) do
    sign = if dir == :up, do: 1, else: -1
    for dy <- [0, 9], do: StaffGlyphs.flag(x, y + sign * dy, dir, ink(), :short)
  end

  defp flags(_, _, _, _), do: []

  defp stem_rect(x, y1, y2) do
    top = min(y1, y2)
    rect(Draw.r1(x), Draw.r1(top), @stem_w, Draw.r1(abs(y2 - y1)), color: ink(), fill: true)
  end

  defp dot(%{dots: d}, x, pos) when is_integer(d) and d > 0 do
    # On a line the dot moves up into the space above.
    dot_pos = if rem(pos, 2) == 0, do: pos + 1, else: pos
    [circle(Draw.r1(x), Draw.r1(staff_y(0, dot_pos)), 2.2, color: ink(), fill: true)]
  end

  defp dot(_, _, _), do: []

  defp rest(:whole, x),
    do: [rect(Draw.r1(x - 6), staff_y(0, 2), 12, 5.5, color: ink(), fill: true)]

  defp rest(:half, x),
    do: [rect(Draw.r1(x - 6), staff_y(0, 0) - 5.5, 12, 5.5, color: ink(), fill: true)]

  defp rest(type, x) when type in [:quarter, :eighth, :sixteenth],
    do: [StaffGlyphs.rest(type, x, staff_y(0, 0), ink())]

  defp rest(_, x), do: rest(:quarter, x)

  # Ties curve away from the stem: below the heads when stems go up.
  defp tie(link, p, y, row) do
    side = if p.dir == :up, do: :below, else: :above
    ty = if side == :below, do: y + 6, else: y - 6

    {x1, x2} =
      case link do
        {:to, x2} -> {p.x + 5, x2 - 5}
        :to_end -> {p.x + 5, row.right - 4}
        :from_start -> {row.start - 8, p.x - 5}
      end

    StaffGlyphs.tie(Draw.r1(x1), Draw.r1(x2), Draw.r1(ty), side, ink())
  end

  # ── Beams ───────────────────────────────────────────────────────────────

  # Each group: a straight beam from the first to the last stem, following
  # the notes' slope (at most one space), moved away from the heads until
  # every stem is at least @min_stem long. Returns the ops and each note's
  # stem end, keyed like the placed items.
  defp beams(groups) do
    Enum.reduce(groups, {[], %{}}, fn group, {ops, ends} ->
      {group_ops, group_ends} = beam_group(group)
      {ops ++ group_ops, Map.merge(ends, group_ends)}
    end)
  end

  defp beam_group([first | _] = group) do
    dir = first.dir
    sign = if dir == :up, do: -1, else: 1
    last = List.last(group)
    ys = Enum.map(group, &staff_y(0, pos(&1)))
    bx1 = stem_x(first.x, dir)
    bx2 = stem_x(last.x, dir) + @stem_w
    e1 = hd(ys) + sign * @stem_len
    slope_rise = Draw.clamp(List.last(ys) - hd(ys), -@g, @g)
    span = max(bx2 - bx1, 1.0)
    line = fn x -> e1 + (x - bx1) / span * slope_rise end

    # Shortest stem so far vs the minimum; shift the whole beam outwards.
    shift =
      group
      |> Enum.zip(ys)
      |> Enum.map(fn {p, y} -> sign * (line.(stem_x(p.x, dir) + @stem_w / 2) - y) - @min_stem end)
      |> Enum.min()
      |> min(0)

    outer = fn x -> line.(x) - sign * shift end

    ends =
      Map.new(group, fn p -> {{p.mi, p.x}, outer.(stem_x(p.x, dir) + @stem_w / 2)} end)

    primary = beam_poly(bx1, bx2, outer, 0, sign)

    secondary =
      group
      |> Enum.with_index()
      |> Enum.chunk_by(fn {p, _} -> p.item[:type] == :sixteenth end)
      |> Enum.filter(fn [{p, _} | _] -> p.item[:type] == :sixteenth end)
      |> Enum.map(fn run -> secondary_beam(run, length(group), dir, outer, sign) end)

    {[primary | secondary], ends}
  end

  defp secondary_beam([{p, i}], count, dir, outer, sign) do
    sx = stem_x(p.x, dir)

    {a, b} =
      if i == count - 1, do: {sx - 9, sx + @stem_w}, else: {sx, sx + @stem_w + 9}

    beam_poly(a, b, outer, @beam_gap, sign)
  end

  defp secondary_beam(run, _count, dir, outer, sign) do
    {first, _} = hd(run)
    {last, _} = List.last(run)
    beam_poly(stem_x(first.x, dir), stem_x(last.x, dir) + @stem_w, outer, @beam_gap, sign)
  end

  # A beam's outer edge follows `outer`; `inset` moves it towards the heads.
  defp beam_poly(x1, x2, outer, inset, sign) do
    o1 = outer.(x1) - sign * inset
    o2 = outer.(x2) - sign * inset
    i1 = o1 - sign * @beam_w
    i2 = o2 - sign * @beam_w

    path(
      Enum.map([{x1, o1}, {x2, o2}, {x2, i2}, {x1, i1}], fn {x, y} -> {Draw.r1(x), Draw.r1(y)} end),
      color: ink(),
      fill: true
    )
  end

  # ── Tuplets ─────────────────────────────────────────────────────────────

  # Consecutive tuplet items in one measure, closed once their written
  # values add up to three of the shortest.
  defp tuplet_groups(items) do
    {groups, open} = Enum.reduce(items, {[], []}, &tuplet_step/2)
    groups |> flush(open) |> Enum.reverse()
  end

  defp tuplet_step(p, {gs, [prev | _] = open}) when prev.mi != p.mi,
    do: tuplet_step(p, {flush(gs, open), []})

  defp tuplet_step(%{item: %{tuplet: t}} = p, {gs, open}) when t != nil do
    open = [p | open]
    written = Enum.map(open, &written/1)

    if Enum.sum(written) >= 3 * Enum.min(written) - 1.0e-6,
      do: {flush(gs, open), []},
      else: {gs, open}
  end

  defp tuplet_step(_p, {gs, open}), do: {flush(gs, open), []}

  defp flush(gs, []), do: gs
  defp flush(gs, open), do: [Enum.reverse(open) | gs]

  defp written(p), do: duration(Map.delete(p.item, :tuplet))

  defp tuplets(items, stem_ends) do
    items
    |> tuplet_groups()
    |> Enum.flat_map(&bracket(&1, stem_ends))
  end

  defp bracket(group, stem_ends) do
    notes = Enum.filter(group, &note?(&1.item))
    up? = notes == [] or Enum.count(notes, &(&1.dir == :up)) * 2 >= length(notes)
    ys = Enum.flat_map(group, &reach(&1, stem_ends))
    x1 = Draw.r1(hd(group).x - 7)
    x2 = Draw.r1(List.last(group).x + 7)
    mx = Draw.r1((x1 + x2) / 2)

    {y, hook} =
      if up?, do: {Enum.min([-4 | ys]) - 9, 5}, else: {Enum.max([4 * @g + 4 | ys]) + 9, -5}

    y = Draw.r1(y)
    opts = [color: ink(), width: 1.0]

    [
      line(x1, y + hook, x1, y, opts),
      line(x1, y, mx - 7, y, opts),
      line(mx + 7, y, x2, y, opts),
      line(x2, y, x2, y + hook, opts),
      text(mx, Draw.r1(y - 0.575 * 11), "3",
        color: ink(),
        size: 11,
        weight: :bold,
        anchor: :center,
        family: Style.font_family(:bold)
      )
    ]
  end

  # Vertical reach of an item: head and stem end for notes, the glyph for rests.
  defp reach(%{item: %{kind: :note}} = p, stem_ends) do
    y = staff_y(0, pos(p))

    stem_end =
      Map.get_lazy(stem_ends, {p.mi, p.x}, fn ->
        if p.dir == :up, do: min(y - @stem_len, 2 * @g), else: max(y + @stem_len, 2 * @g)
      end)

    [y - 6, y + 6, stem_end]
  end

  defp reach(_, _), do: [2 * @g - 18, 2 * @g + 18]

  # ── Note names ──────────────────────────────────────────────────────────

  defp name_ops(row, y) do
    row
    |> row_items()
    |> Enum.filter(&(note?(&1.item) and is_integer(&1.item[:midi])))
    |> Enum.flat_map(fn p ->
      x = Draw.r1(p.x)

      [
        circle(x, y, 9, color: Style.pitch_color(p.item.midi, 58), fill: true),
        text(x, Draw.r1(y - 0.575 * 10), letter(p.item),
          color: ink(),
          size: 10,
          weight: :bold,
          anchor: :center,
          family: Style.font_family(:bold)
        )
      ]
    end)
  end

  defp letter(%{step: step} = item) when is_binary(step) do
    step <>
      case item[:alter] do
        1 -> "♯"
        -1 -> "♭"
        _ -> ""
      end
  end

  defp letter(%{midi: midi}), do: Music.pitch_class_name(midi)
end
