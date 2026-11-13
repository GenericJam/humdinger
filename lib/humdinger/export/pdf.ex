defmodule Humdinger.Export.Pdf do
  @moduledoc """
  Sheet music as a PDF, for the sheet board's "Share as PDF" and "Print".

  `engrave/3` draws a `Humdinger.Notation` layout on A4 or US Letter pages:
  the title and summary line, a tempo mark, then systems of one staff, as
  many measures to a system as fit. Measures are spaced by their notes'
  durations (longer notes get more room, but not proportionally more), every
  full system is stretched to the right margin, and the last one is too
  unless it would spread a short phrase across the page. Systems start with
  the clef and key signature, the first with the time signature too; the
  last measure ends with a final barline. A system or page break never
  splits a measure; a tie across one is drawn in two halves.

  Everything is drawn as filled paths: noteheads are tilted Bézier ellipses,
  stems and beams are polygons, ties are crescents; clefs, accidentals,
  rests and flags are Noto Music's outlines (`Humdinger.MusicGlyphs`). Text
  is Helvetica and Times-Bold (`Humdinger.Pdf`).

  Engraving follows the common conventions: stems up below the middle line
  and down from it, a beamed group's direction set by its note farthest
  from the middle line, beams slanted at most a staff space, dots in a
  space, ties on the side away from the stem, triplets bracketed unless
  they are one beamed group (then only the 3).

  With `note_names: true` each note gets a disc under the staff in its
  pitch colour (`Humdinger.Style.pitch_color/1`) with its letter, as on the
  sheet board.
  """

  alias Humdinger.{MusicGlyphs, Notation, Pdf, Phrase, Style}

  # Staff space in points: a 26 pt (9 mm) staff, a size for reading while
  # learning a tune.
  @sp 6.5
  @h @sp / 2
  @glyph_scale @sp / MusicGlyphs.staff_space()
  # Font units from a glyph's origin up to the bottom staff line, and to a
  # note in the first space (where accidentals are centred).
  @glyph_bottom MusicGlyphs.staff_bottom()
  @glyph_note MusicGlyphs.staff_bottom() + MusicGlyphs.staff_space() / 2

  @margin 54
  @staff_line 0.11 * @sp
  @stem 0.12 * @sp
  @ledger 0.18 * @sp
  @thin_bar 0.16 * @sp
  @thick_bar 0.5 * @sp
  @beam 0.5 * @sp
  @beam_step 0.75 * @sp
  @stem_length 3.5 * @sp
  @measure_pad 1.2 * @sp
  @name_radius 1.0 * @sp

  @base_quarters %{whole: 4, half: 2, quarter: 1, eighth: 0.5, sixteenth: 0.25}
  @treble_sharps [4, 1, 5, 2, -1, 3, 0]
  @treble_flats [0, 3, -1, 2, -2, 1, -3]

  @type meta :: %{title: String.t(), subtitle: String.t() | nil, tempo_bpm: number | nil}

  @doc """
  The PDF of `phrase` as sheet music. Options: `clef:` and `rhythm:` for
  `Humdinger.Notation.layout/2` (default `:auto`, `:as_sung`), and those of
  `engrave/3`.
  """
  @spec render(Phrase.t(), keyword) :: binary
  def render(%Phrase{} = phrase, opts \\ []) do
    layout =
      Notation.layout(phrase,
        clef: opts[:clef] || :auto,
        rhythm: opts[:rhythm] || :as_sung
      )

    meta = %{title: phrase.name, subtitle: Phrase.summary(phrase), tempo_bpm: phrase.tempo_bpm}
    engrave(layout, meta, opts)
  end

  @doc """
  The PDF of a `Humdinger.Notation` layout. `meta` gives the title, the
  line under it and the tempo (either may be nil). Options: `note_names:`
  (default false), `paper: :a4 | :letter` (default `:a4`).
  """
  @spec engrave(Notation.t(), meta, keyword) :: binary
  def engrave(layout, meta, opts \\ []) do
    {page_w, page_h} = Pdf.page_size(Keyword.get(opts, :paper, :a4))
    names? = Keyword.get(opts, :note_names, false)
    width = page_w - 2 * @margin

    systems =
      layout.measures
      |> Enum.map(&plan_measure/1)
      |> break_systems(layout, width)
      |> Enum.with_index()
      |> Enum.map(&place_system(&1, layout, width))
      |> add_ties()
      |> Enum.map(&Map.put(&1, :extent, extent(&1, names?)))

    pages = paginate(systems, page_h, meta)
    count = length(pages)

    pages
    |> Enum.with_index(1)
    |> Enum.map(fn {systems_on_page, n} ->
      content = [
        Pdf.fill_color(Style.paper_ink()),
        if(n == 1, do: title_block(meta, page_w, page_h, systems_on_page), else: []),
        Enum.map(systems_on_page, &draw_system(&1, layout, names?)),
        if(count > 1, do: footer(n, count, page_w), else: [])
      ]

      %{size: {page_w, page_h}, content: content}
    end)
    |> Pdf.document(title: meta[:title])
  end

  # ── Horizontal layout ─────────────────────────────────────────────────

  defp plan_measure(%{items: items} = measure) do
    {slots, width} =
      Enum.map_reduce(items, @measure_pad, fn item, offset ->
        dur = duration(item)
        lead = lead(item)
        {%{item: item, dur: dur, offset: offset, lead: lead}, offset + lead + spacing(dur)}
      end)

    whole_rest? = match?([%{kind: :rest, beat: beat}] when beat == 0, items)
    %{index: measure.index, slots: slots, width: width, whole_rest?: whole_rest?}
  end

  defp duration(item) do
    base = @base_quarters[item.type]
    base = if item.dots == 1, do: base * 1.5, else: base
    if item.tuplet, do: base * 2 / 3, else: base
  end

  # Room after a note: grows with the logarithm of its length, as engravers
  # space music (a half note gets about 1.3× a quarter's room, not 2×).
  defp spacing(dur), do: (1.5 + 1.5 * :math.log2(1 + 2 * dur)) * @sp

  defp lead(%{kind: :note, accidental: acc}) when acc != nil,
    do: glyph_width(acc) + 0.3 * @sp

  defp lead(_item), do: 0.0

  # Greedy: each system takes measures while they fit at their natural
  # width. A layout without measures gets one empty one.
  defp break_systems([], _layout, _width),
    do: [[%{index: 0, slots: [], width: 16 * @sp, whole_rest?: false}]]

  defp break_systems(plans, layout, width) do
    first = width - header_width(layout, true)
    rest = width - header_width(layout, false)

    plans
    |> Enum.reduce([], fn
      plan, [] -> [[plan]]
      plan, [current | done] -> fit(plan, current, done, if(done == [], do: first, else: rest))
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp fit(plan, current, done, avail) do
    if Enum.sum_by(current, & &1.width) + plan.width <= avail,
      do: [[plan | current] | done],
      else: [[plan], current | done]
  end

  defp header_width(layout, first?) do
    clef = glyph_width(clef_glyph(layout.clef))
    signature = key_signature(layout)
    key = Enum.sum_by(signature, fn {glyph, _pos} -> key_advance(glyph) end)
    gap = if signature == [], do: 0, else: 0.6 * @sp
    time = if first?, do: gap + time_width(layout.time) + 1.0 * @sp, else: 0
    0.6 * @sp + clef + 1.0 * @sp + key + time
  end

  defp place_system({plans, index}, layout, width) do
    first? = index == 0
    last? = List.last(plans).index == last_index(layout)
    music_x = @margin + header_width(layout, first?)
    natural = Enum.sum_by(plans, & &1.width)
    avail = @margin + width - music_x
    stretch = if not last? or natural >= 0.75 * avail, do: avail / natural, else: 1.0

    {measures, end_x} =
      Enum.map_reduce(plans, music_x, fn plan, x ->
        w = plan.width * stretch
        items = Enum.map(plan.slots, &place_item(&1, plan, x, w, stretch))
        {%{index: plan.index, x: x, end_x: x + w, items: items}, x + w}
      end)

    notes = measures |> Enum.flat_map(& &1.items) |> Enum.filter(&(&1.kind == :note))
    {notes, beams} = stems_and_beams(notes, measures)

    %{
      index: index,
      first?: first?,
      clef: layout.clef,
      y: nil,
      x: @margin,
      music_x: music_x,
      end_x: end_x,
      measures: Enum.map(measures, &%{&1 | items: merge_notes(&1.items, notes)}),
      notes: notes,
      beams: beams,
      tuplets: tuplets(measures, notes, beams),
      ties: []
    }
  end

  defp place_item(slot, plan, measure_x, measure_w, stretch) do
    item = slot.item
    hw = head_half_width(item.type)

    x =
      if plan.whole_rest?,
        do: measure_x + measure_w / 2,
        else: measure_x + slot.offset * stretch + slot.lead + hw

    y = if item.kind == :note, do: item.staff_pos * @h, else: nil

    %{
      kind: item.kind,
      item: item,
      x: x,
      y: y,
      hw: hw,
      key: {plan.index, item.beat},
      dir: nil,
      stem: nil,
      flags: 0,
      beam_id: nil
    }
  end

  defp merge_notes(items, notes) do
    by_key = Map.new(notes, &{&1.key, &1})
    Enum.map(items, &Map.get(by_key, &1.key, &1))
  end

  # ── Stems and beams ───────────────────────────────────────────────────

  defp stems_and_beams(notes, measures) do
    groups =
      measures
      |> Enum.flat_map(fn m -> beam_groups(Enum.filter(m.items, &(&1.kind == :note))) end)

    {beamed, beams} =
      groups
      |> Enum.filter(&match?([_, _ | _], &1))
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {group, id}, beams ->
        {group, beam} = beam_group(group, id)
        {group, [beam | beams]}
      end)

    beamed = beamed |> List.flatten() |> Map.new(&{&1.key, &1})

    notes =
      Enum.map(notes, fn note ->
        Map.get_lazy(beamed, note.key, fn -> single_stem(note) end)
      end)

    {notes, Enum.reverse(beams)}
  end

  defp beam_groups(notes) do
    {groups, current} =
      Enum.reduce(notes, {[], []}, fn note, {groups, current} ->
        case note.item.beam do
          :begin -> {flush(groups, current), [note]}
          :continue -> {groups, [note | current]}
          :end -> {flush(groups, [note | current]), []}
          nil -> {flush(groups, current), []}
        end
      end)

    groups |> flush(current) |> Enum.reverse()
  end

  defp flush(groups, []), do: groups
  defp flush(groups, current), do: [Enum.reverse(current) | groups]

  defp direction(pos) when pos < 0, do: :up
  defp direction(_pos), do: :down

  defp single_stem(%{item: %{type: :whole}} = note),
    do: %{note | dir: direction(note.item.staff_pos)}

  defp single_stem(note) do
    dir = direction(note.item.staff_pos)
    flags = flag_count(note.item.type)
    length = if flags == 2, do: @stem_length + 0.5 * @sp, else: @stem_length

    tip =
      case dir do
        :up -> max(note.y + length, 0.0)
        :down -> min(note.y - length, 0.0)
      end

    %{note | dir: dir, flags: flags, stem: stem(note, dir, tip)}
  end

  defp flag_count(:eighth), do: 1
  defp flag_count(:sixteenth), do: 2
  defp flag_count(_type), do: 0

  defp stem(note, dir, tip) do
    {left, from} =
      case dir do
        :up -> {note.x + note.hw - @stem, note.y + 0.2 * @sp}
        :down -> {note.x - note.hw, note.y - 0.2 * @sp}
      end

    %{left: left, right: left + @stem, from: from, tip: tip}
  end

  defp beam_group(group, id) do
    above = group |> Enum.map(& &1.item.staff_pos) |> Enum.max()
    below = group |> Enum.map(&(-&1.item.staff_pos)) |> Enum.max()
    dir = if below > above, do: :up, else: :down
    sign = if dir == :up, do: 1, else: -1
    levels = if Enum.any?(group, &(&1.item.type == :sixteenth)), do: 2, else: 1
    min_stem = @stem_length + (levels - 1) * 0.25 * @sp

    xs = Enum.map(group, &stem_center(&1, dir))
    [x0 | _] = xs
    x1 = List.last(xs)
    slope = beam_slope(group, dir) / (x1 - x0)

    offset =
      group
      |> Enum.zip(xs)
      |> Enum.map(fn {note, x} -> sign * (note.y + sign * min_stem - slope * (x - x0)) end)
      |> Enum.max()
      |> max(sign * -slope * ((x1 - x0) / 2))
      |> Kernel.*(sign)

    line = fn x -> offset + slope * (x - x0) end

    notes =
      Enum.map(group, fn note ->
        %{note | dir: dir, beam_id: id, stem: stem(note, dir, line.(stem_center(note, dir)))}
      end)

    {notes, %{id: id, dir: dir, line: line, notes: notes}}
  end

  defp stem_center(note, :up), do: note.x + note.hw - @stem / 2
  defp stem_center(note, :down), do: note.x - note.hw + @stem / 2

  # Rise of the beam from first to last stem: half the notes' rise, at most
  # a staff space, flat when an inner note reaches past both ends.
  defp beam_slope(group, dir) do
    first = hd(group).y
    last = List.last(group).y
    inner = group |> Enum.slice(1..-2//1) |> Enum.map(& &1.y)
    reach = if dir == :up, do: &Kernel.>/2, else: &Kernel.</2

    if Enum.any?(inner, &(reach.(&1, first) and reach.(&1, last))) do
      0.0
    else
      rise = (last - first) / 2
      rise |> max(-@sp) |> min(@sp)
    end
  end

  # ── Tuplets and ties ──────────────────────────────────────────────────

  defp tuplets(measures, notes, beams) do
    notes_by_key = Map.new(notes, &{&1.key, &1})
    beam_sizes = Map.new(beams, &{&1.id, length(&1.notes)})

    # Triplets come a beat at a time.
    for measure <- measures,
        group <-
          measure.items
          |> Enum.filter(& &1.item.tuplet)
          |> Enum.chunk_by(&trunc(&1.item.beat + 1.0e-6)) do
      items = Enum.map(group, &Map.get(notes_by_key, &1.key, &1))

      case Enum.uniq_by(items, & &1.beam_id) do
        [%{beam_id: id}] when id != nil and :erlang.map_get(id, beam_sizes) == length(items) ->
          {:number, Enum.find(beams, &(&1.id == id))}

        _ ->
          {:bracket, items}
      end
    end
  end

  defp add_ties(systems) do
    notes = Enum.flat_map(systems, fn s -> Enum.map(s.notes, &{s.index, &1}) end)

    ties =
      notes
      |> Enum.zip(Enum.drop(notes, 1))
      |> Enum.filter(fn {{_, a}, _} -> a.item.tie_to_next end)
      |> Enum.flat_map(fn {{sa, a}, {sb, b}} ->
        side = if a.dir == :up, do: -1, else: 1

        if sa == sb,
          do: [{sa, tie_start(a), tie_end(b), a.y, side}],
          else: [
            {sa, tie_start(a), Enum.at(systems, sa).end_x - 0.4 * @sp, a.y, side},
            {sb, Enum.at(systems, sb).music_x - 0.4 * @sp, tie_end(b), b.y, side}
          ]
      end)
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

    Enum.map(systems, &%{&1 | ties: Map.get(ties, &1.index, [])})
  end

  defp tie_start(note) do
    if note.item.dots > 0, do: dot_x(note) + 0.5 * @sp, else: note.x + note.hw * 0.8
  end

  defp tie_end(note), do: note.x - note.hw * 0.8 - lead_gap(note)

  defp lead_gap(%{item: %{accidental: acc}}) when acc != nil, do: glyph_width(acc) + 0.3 * @sp
  defp lead_gap(_note), do: 0.0

  # ── Vertical layout ───────────────────────────────────────────────────

  # How far a system's drawing reaches above and below its middle line.
  defp extent(system, names?) do
    clef = MusicGlyphs.glyph(clef_glyph(system.clef))
    {_, clef_lo, _, clef_hi} = clef.bbox
    clef_y = &(-2 * @sp + (&1 - @glyph_bottom) * @glyph_scale)

    ys =
      [clef_y.(clef_lo), clef_y.(clef_hi), 2.6 * @sp, -2.6 * @sp] ++
        Enum.flat_map(system.notes, fn n ->
          [n.y + 0.6 * @sp, n.y - 0.6 * @sp] ++ if(n.stem, do: [n.stem.tip], else: [])
        end) ++
        Enum.flat_map(system.beams, &beam_ends/1) ++
        Enum.flat_map(system.tuplets, &tuplet_reach/1) ++
        Enum.map(system.ties, fn {_, _, y, side} -> y + side * 1.6 * @sp end)

    {low, high} = Enum.min_max(ys)

    if names? and system.notes != [] do
      name_y = min(low - 1.6 * @sp, -4.4 * @sp)
      %{high: high, low: name_y - @name_radius, name_y: name_y}
    else
      %{high: high, low: low, name_y: nil}
    end
  end

  defp beam_ends(%{line: line, notes: notes}), do: [line.(hd(notes).x), line.(List.last(notes).x)]

  defp tuplet_reach({:number, beam}),
    do: [tuplet_number_y(beam) + 1.4 * @sp, tuplet_number_y(beam)]

  defp tuplet_reach({:bracket, items}), do: [bracket_y(items) + 1.6 * @sp]

  defp paginate(systems, page_h, meta) do
    top = page_h - @margin
    first_top = top - title_height(meta)
    bottom = @margin + 14

    {pages, current, _} =
      Enum.reduce(systems, {[], [], nil}, fn system, {pages, current, prev} ->
        case place_vertically(system, prev, first_top, top, bottom) do
          {:same_page, y} -> {pages, [%{system | y: y} | current], {y, system}}
          {:new_page, y} -> {[Enum.reverse(current) | pages], [%{system | y: y}], {y, system}}
        end
      end)

    Enum.reverse([Enum.reverse(current) | pages])
  end

  defp place_vertically(system, nil, first_top, _top, _bottom),
    do: {:same_page, first_top - system.extent.high}

  defp place_vertically(system, {prev_y, prev}, _first_top, top, bottom) do
    gap = max(2.4 * @sp + prev.extent.low * -1 + system.extent.high, 11 * @sp)
    y = prev_y - gap

    if y + system.extent.low < bottom,
      do: {:new_page, top - system.extent.high},
      else: {:same_page, y}
  end

  defp title_height(meta) do
    title = if meta[:title], do: 26, else: 0
    subtitle = if meta[:subtitle], do: 16, else: 0
    tempo = if meta[:tempo_bpm], do: 28, else: 6
    title + subtitle + tempo
  end

  # ── Drawing: page furniture ───────────────────────────────────────────

  defp title_block(meta, page_w, page_h, [first | _]) do
    top = page_h - @margin
    title_y = top - 18
    subtitle_y = if meta[:title], do: title_y - 18, else: top - 10

    [
      centered(meta[:title], :helvetica_bold, 18, page_w / 2, title_y),
      [
        Pdf.fill_color(Style.faint()),
        centered(meta[:subtitle], :helvetica, 10, page_w / 2, subtitle_y),
        Pdf.fill_color(Style.paper_ink())
      ],
      tempo_mark(meta[:tempo_bpm], first.y + first.extent.high + 6)
    ]
  end

  defp centered(nil, _font, _size, _x, _y), do: []

  defp centered(text, font, size, x, y) do
    Pdf.text(x - Pdf.text_width(text, font, size) / 2, y, font, size, text)
  end

  # "♩ = 96": a small quarter note, then the number.
  defp tempo_mark(nil, _baseline), do: []

  defp tempo_mark(bpm, baseline) do
    k = 0.8
    hw = head_half_width(:quarter) * k
    x = @margin + hw
    y = baseline + 0.45 * @sp * k
    label = "= #{round(bpm)}"

    [
      notehead(:quarter, x, y, k),
      Pdf.rect(x + hw - @stem, y + 0.2 * @sp * k, @stem, 3.2 * @sp * k),
      Pdf.fill(),
      Pdf.text(x + hw + 4, baseline, :helvetica_bold, 10, label)
    ]
  end

  defp footer(n, count, page_w) do
    [
      Pdf.fill_color(Style.faint()),
      centered("#{n} / #{count}", :helvetica, 9, page_w / 2, @margin / 2),
      Pdf.fill_color(Style.paper_ink())
    ]
  end

  # ── Drawing: one system ───────────────────────────────────────────────
  #
  # Drawn in a frame with y = 0 on the middle staff line (x stays the page's).

  defp draw_system(system, layout, names?) do
    last_index = last_index(layout)

    [
      Pdf.save(),
      Pdf.transform(1, 0, 0, 1, 0, system.y),
      staff(system),
      clef(layout.clef, system.x),
      key_signature_ops(layout, system.x),
      if(system.first?, do: time_signature(layout, system), else: []),
      Enum.map(system.measures, &barline(&1, &1.index == last_index)),
      Enum.map(system.measures, fn m -> Enum.map(m.items, &draw_item/1) end),
      Enum.map(system.notes, &draw_stem/1),
      Enum.map(system.beams, &draw_beam/1),
      Enum.map(system.tuplets, &draw_tuplet/1),
      Enum.map(system.ties, &draw_tie/1),
      if(names?, do: Enum.map(system.notes, &note_name(&1, system.extent.name_y)), else: []),
      Pdf.restore()
    ]
  end

  defp last_index(%{measures: []}), do: 0
  defp last_index(%{measures: measures}), do: List.last(measures).index

  defp staff(system) do
    lines =
      for k <- -2..2,
          do: Pdf.rect(system.x, k * @sp - @staff_line / 2, system.end_x - system.x, @staff_line)

    [lines, Pdf.fill()]
  end

  defp clef_glyph(:treble), do: :treble_clef
  defp clef_glyph(:bass), do: :bass_clef

  defp clef(clef, x) do
    glyph = clef_glyph(clef)
    {xmin, _, _, _} = MusicGlyphs.glyph(glyph).bbox
    draw_glyph(glyph, x + 0.6 * @sp - xmin * @glyph_scale, staff_origin_y())
  end

  defp staff_origin_y, do: -2 * @sp - @glyph_bottom * @glyph_scale

  defp key_signature(layout) do
    fifths = layout.key_fifths
    shift = if layout.clef == :bass, do: -2, else: 0

    cond do
      fifths > 0 -> @treble_sharps |> Enum.take(fifths) |> Enum.map(&{:sharp, &1 + shift})
      fifths < 0 -> @treble_flats |> Enum.take(-fifths) |> Enum.map(&{:flat, &1 + shift})
      true -> []
    end
  end

  defp key_advance(glyph), do: glyph_width(glyph) + 0.2 * @sp

  defp key_signature_ops(layout, system_x) do
    start = system_x + 0.6 * @sp + glyph_width(clef_glyph(layout.clef)) + 1.0 * @sp

    layout
    |> key_signature()
    |> Enum.map_reduce(start, fn {glyph, pos}, x ->
      {accidental(glyph, x + glyph_width(glyph), pos * @h), x + key_advance(glyph)}
    end)
    |> elem(0)
  end

  defp time_width({num, den}) do
    size = time_size()
    max(Pdf.text_width("#{num}", :times_bold, size), Pdf.text_width("#{den}", :times_bold, size))
  end

  # Times-Bold digits are 0.676 em tall; each fills half the staff.
  defp time_size, do: 2 * @sp / 0.676

  defp time_signature(layout, system) do
    {num, den} = layout.time
    w = time_width(layout.time)
    x = system.music_x - 1.0 * @sp - w / 2

    [
      centered("#{num}", :times_bold, time_size(), x, 0.0),
      centered("#{den}", :times_bold, time_size(), x, -2 * @sp)
    ]
  end

  defp barline(measure, false) do
    [Pdf.rect(measure.end_x - @thin_bar, -2 * @sp, @thin_bar, 4 * @sp), Pdf.fill()]
  end

  defp barline(measure, true) do
    x = measure.end_x

    [
      Pdf.rect(x - @thick_bar, -2 * @sp, @thick_bar, 4 * @sp),
      Pdf.rect(x - @thick_bar - 0.45 * @sp - @thin_bar, -2 * @sp, @thin_bar, 4 * @sp),
      Pdf.fill()
    ]
  end

  # ── Drawing: notes and rests ──────────────────────────────────────────

  defp draw_item(%{kind: :rest} = rest) do
    glyph = rest_glyph(rest.item.type)
    {xmin, _, xmax, _} = MusicGlyphs.glyph(glyph).bbox
    # Whole and half rests hang from the fourth line and sit on the middle
    # one; the font draws them a space lower.
    lift = if rest.item.type in [:whole, :half], do: @sp, else: 0.0
    x = rest.x - (xmin + xmax) / 2 * @glyph_scale

    [
      draw_glyph(glyph, x, staff_origin_y() + lift),
      if(rest.item.dots > 0,
        do: dot(rest.x + (xmax - xmin) / 2 * @glyph_scale + 0.5 * @sp, @h),
        else: []
      )
    ]
  end

  defp draw_item(%{kind: :note} = note) do
    %{item: item, x: x, y: y, hw: hw} = note

    [
      ledger_lines(item.staff_pos, x, hw),
      notehead(item.type, x, y, 1.0),
      if(item.accidental, do: accidental(item.accidental, x - hw - 0.25 * @sp, y), else: []),
      if(item.dots > 0, do: dot(dot_x(note), dot_y(item.staff_pos)), else: [])
    ]
  end

  defp rest_glyph(:whole), do: :whole_rest
  defp rest_glyph(:half), do: :half_rest
  defp rest_glyph(:quarter), do: :quarter_rest
  defp rest_glyph(:eighth), do: :eighth_rest
  defp rest_glyph(:sixteenth), do: :sixteenth_rest

  defp ledger_lines(pos, x, hw) when pos >= 6 or pos <= -6 do
    sign = if pos > 0, do: 1, else: -1
    reach = 0.4 * @sp

    lines =
      for p <- 6..abs(pos)//2,
          do: Pdf.rect(x - hw - reach, sign * p * @h - @ledger / 2, 2 * (hw + reach), @ledger)

    [lines, Pdf.fill()]
  end

  defp ledger_lines(_pos, _x, _hw), do: []

  # Noteheads: black and half heads tilted 20°, the half's hole a thinner
  # ellipse tilted further; a wider, upright whole note with a slanted hole.
  defp notehead(:whole, x, y, k) do
    [
      ellipse(x, y, 0.85 * @sp * k, 0.52 * @sp * k, 0),
      ellipse(x, y, 0.3 * @sp * k, 0.42 * @sp * k, 30),
      Pdf.fill_even_odd()
    ]
  end

  defp notehead(:half, x, y, k) do
    [
      ellipse(x, y, 0.66 * @sp * k, 0.47 * @sp * k, 20),
      ellipse(x, y, 0.55 * @sp * k, 0.2 * @sp * k, 30),
      Pdf.fill_even_odd()
    ]
  end

  defp notehead(_type, x, y, k),
    do: [ellipse(x, y, 0.66 * @sp * k, 0.47 * @sp * k, 20), Pdf.fill()]

  defp head_half_width(:whole), do: 0.85 * @sp

  defp head_half_width(_type) do
    a = 20 * :math.pi() / 180
    :math.sqrt(:math.pow(0.66 * @sp * :math.cos(a), 2) + :math.pow(0.47 * @sp * :math.sin(a), 2))
  end

  defp accidental(glyph, right, y) do
    {_, _, xmax, _} = MusicGlyphs.glyph(glyph).bbox
    draw_glyph(glyph, right - xmax * @glyph_scale, y - @glyph_note * @glyph_scale)
  end

  defp dot_x(%{dir: :up, flags: flags} = note) when flags > 0, do: note.x + note.hw + 1.6 * @sp
  defp dot_x(note), do: note.x + note.hw + 0.55 * @sp

  # A dot on a line moves up into the space.
  defp dot_y(pos) when rem(pos, 2) == 0, do: (pos + 1) * @h
  defp dot_y(pos), do: pos * @h

  defp dot(x, y), do: [ellipse(x, y, 0.2 * @sp, 0.2 * @sp, 0), Pdf.fill()]

  defp draw_stem(%{stem: nil}), do: []

  defp draw_stem(%{stem: stem} = note) do
    {y0, y1} = Enum.min_max([stem.from, stem.tip])

    [
      Pdf.rect(stem.left, y0, @stem, y1 - y0),
      Pdf.fill(),
      flag(note)
    ]
  end

  defp flag(%{flags: 0}), do: []

  defp flag(%{flags: flags, dir: dir, stem: stem}) do
    glyph = if flags == 1, do: :flag_eighth, else: :flag_sixteenth
    {_, _, _, top} = MusicGlyphs.glyph(glyph).bbox

    case dir do
      :up -> draw_glyph(glyph, stem.left, stem.tip - top * @glyph_scale)
      :down -> draw_glyph(glyph, stem.left, stem.tip + top * @glyph_scale, -1)
    end
  end

  defp draw_beam(%{dir: dir, line: line, notes: notes}) do
    sign = if dir == :up, do: -1, else: 1
    primary = beam_segment(line, stem_left(hd(notes)), stem_right(List.last(notes)), 0, sign)

    secondary =
      notes
      |> Enum.with_index()
      |> Enum.chunk_by(fn {note, _i} -> note.item.type == :sixteenth end)
      |> Enum.filter(fn [{note, _i} | _] -> note.item.type == :sixteenth end)
      |> Enum.map(&secondary_beam(&1, line, sign))

    [primary, secondary, Pdf.fill()]
  end

  defp stem_left(note), do: note.stem.left
  defp stem_right(note), do: note.stem.right

  # A run of sixteenths shares a second beam; a lone one gets a stub
  # pointing into the group.
  defp secondary_beam([{note, 0}], line, sign),
    do: beam_segment(line, stem_left(note), stem_right(note) + 1.1 * @sp, 1, sign)

  defp secondary_beam([{note, _i}], line, sign),
    do: beam_segment(line, stem_left(note) - 1.1 * @sp, stem_right(note), 1, sign)

  defp secondary_beam([{first, _} | _] = run, line, sign) do
    {last, _} = List.last(run)
    beam_segment(line, stem_left(first), stem_right(last), 1, sign)
  end

  # A beam as a parallelogram hanging from the beam line toward the notes.
  defp beam_segment(line, xa, xb, level, sign) do
    off = sign * level * @beam_step
    ya = line.(xa) + off
    yb = line.(xb) + off

    [
      Pdf.move_to(xa, ya),
      Pdf.line_to(xb, yb),
      Pdf.line_to(xb, yb + sign * @beam),
      Pdf.line_to(xa, ya + sign * @beam),
      Pdf.close_path()
    ]
  end

  defp tuplet_number_y(%{dir: :up, line: line, notes: notes}) do
    line.((hd(notes).x + List.last(notes).x) / 2) + 0.5 * @sp
  end

  defp tuplet_number_y(%{dir: :down, line: line, notes: notes}) do
    line.((hd(notes).x + List.last(notes).x) / 2) - 0.5 * @sp - tuplet_size() * 0.676
  end

  defp tuplet_size, do: 1.6 * @sp

  # Brackets go above the staff, clear of the group's heads, stems and
  # accidentals.
  defp bracket_y(items) do
    items
    |> Enum.flat_map(fn
      %{kind: :note} = note -> [note_top(note) + 0.6 * @sp]
      _rest -> [1.6 * @sp]
    end)
    |> Enum.max()
    |> max(3.0 * @sp)
  end

  defp note_top(%{y: y, stem: stem, item: item}) do
    tip = if stem, do: stem.tip, else: y
    acc = if item.accidental, do: y + accidental_top(item.accidental), else: y
    Enum.max([y, tip, acc])
  end

  defp accidental_top(glyph) do
    {_, _, _, ymax} = MusicGlyphs.glyph(glyph).bbox
    (ymax - @glyph_note) * @glyph_scale
  end

  defp draw_tuplet({:number, %{notes: notes} = beam}) do
    x = (stem_left(hd(notes)) + stem_right(List.last(notes))) / 2
    centered("3", :times_bold, tuplet_size(), x, tuplet_number_y(beam))
  end

  defp draw_tuplet({:bracket, items}) do
    first = hd(items)
    last = List.last(items)
    x0 = first.x - first.hw
    x1 = last.x + last.hw
    y = bracket_y(items) + 0.5 * @sp
    mid = (x0 + x1) / 2
    gap = 0.9 * @sp
    w = 0.12 * @sp
    hook = 0.6 * @sp

    [
      Pdf.rect(x0, y - hook, w, hook),
      Pdf.rect(x0, y - w, mid - gap - x0, w),
      Pdf.rect(mid + gap, y - w, x1 - mid - gap, w),
      Pdf.rect(x1 - w, y - hook, w, hook),
      Pdf.fill(),
      centered("3", :times_bold, tuplet_size(), mid, y - tuplet_size() * 0.676 / 2)
    ]
  end

  # A tie as a crescent: an outer and an inner curve between the same ends.
  defp draw_tie({x0, x1, y, side}) do
    y = y + side * 0.55 * @sp
    span = x1 - x0
    height = (0.12 * span) |> max(0.5 * @sp) |> min(1.2 * @sp)
    outer = side * height / 0.75
    inner = side * (height - 0.2 * @sp) / 0.75

    [
      Pdf.move_to(x0, y),
      Pdf.curve_to(x0 + span / 4, y + outer, x1 - span / 4, y + outer, x1, y),
      Pdf.curve_to(x1 - span / 4, y + inner, x0 + span / 4, y + inner, x0, y),
      Pdf.close_path(),
      Pdf.fill()
    ]
  end

  defp note_name(note, y) do
    item = note.item
    label = item.step <> accidental_text(item.alter)
    size = 1.15 * @sp

    [
      Pdf.fill_color(Style.pitch_color(item.midi)),
      ellipse(note.x, y, @name_radius, @name_radius, 0),
      Pdf.fill(),
      Pdf.fill_color(Style.paper_ink()),
      centered(label, :helvetica_bold, size, note.x, y - 0.718 * size / 2)
    ]
  end

  defp accidental_text(1), do: "#"
  defp accidental_text(-1), do: "b"
  defp accidental_text(_alter), do: ""

  # ── Geometry ──────────────────────────────────────────────────────────

  defp glyph_width(name) do
    {xmin, _, xmax, _} = MusicGlyphs.glyph(name).bbox
    (xmax - xmin) * @glyph_scale
  end

  # A glyph's outline with its font origin at (ox, oy), scaled to the staff
  # (mirrored vertically when `flip` is -1), filled.
  defp draw_glyph(name, ox, oy, flip \\ 1) do
    point = fn x, y -> {ox + x * @glyph_scale, oy + flip * y * @glyph_scale} end

    {ops, _} =
      Enum.map_reduce(MusicGlyphs.glyph(name).ops, nil, fn
        {:m, x, y}, _ ->
          {px, py} = point.(x, y)
          {Pdf.move_to(px, py), {px, py}}

        {:l, x, y}, _ ->
          {px, py} = point.(x, y)
          {Pdf.line_to(px, py), {px, py}}

        {:q, cx, cy, x, y}, {x0, y0} ->
          {qx, qy} = point.(cx, cy)
          {px, py} = point.(x, y)
          c1 = {x0 + 2 / 3 * (qx - x0), y0 + 2 / 3 * (qy - y0)}
          c2 = {px + 2 / 3 * (qx - px), py + 2 / 3 * (qy - py)}
          {Pdf.curve_to(elem(c1, 0), elem(c1, 1), elem(c2, 0), elem(c2, 1), px, py), {px, py}}

        :z, current ->
          {Pdf.close_path(), current}
      end)

    [ops, Pdf.fill()]
  end

  # An ellipse centred on (cx, cy), radii rx and ry, rotated by `degrees`
  # counterclockwise: four cubic arcs.
  defp ellipse(cx, cy, rx, ry, degrees) do
    k = 0.5523
    a = degrees * :math.pi() / 180
    {cos, sin} = {:math.cos(a), :math.sin(a)}
    pt = fn x, y -> {cx + x * cos - y * sin, cy + x * sin + y * cos} end

    arcs = [
      [{rx, k * ry}, {k * rx, ry}, {0, ry}],
      [{-k * rx, ry}, {-rx, k * ry}, {-rx, 0}],
      [{-rx, -k * ry}, {-k * rx, -ry}, {0, -ry}],
      [{k * rx, -ry}, {rx, -k * ry}, {rx, 0}]
    ]

    {sx, sy} = pt.(rx, 0)

    [
      Pdf.move_to(sx, sy),
      Enum.map(arcs, fn arc ->
        [{x1, y1}, {x2, y2}, {x3, y3}] = Enum.map(arc, fn {x, y} -> pt.(x, y) end)
        Pdf.curve_to(x1, y1, x2, y2, x3, y3)
      end),
      Pdf.close_path()
    ]
  end
end
