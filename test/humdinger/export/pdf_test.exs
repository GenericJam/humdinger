defmodule Humdinger.Export.PdfTest do
  use ExUnit.Case, async: true

  alias Humdinger.Export.Pdf, as: Engraver
  alias Humdinger.{MusicGlyphs, Style}

  @steps ~w(C D E F G A B)
  @pitch_class %{"C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11}
  @meta %{title: "New phrase", subtitle: "8 notes · 2 bars at 96 · D Dorian", tempo_bpm: 96}

  # ── Hand-built layouts (the Notation contract) ────────────────────────

  defp note(name, beat, type, opts \\ []) do
    [_, step, acc, octave] = Regex.run(~r/^([A-G])([#b]?)(\d)$/, name)
    octave = String.to_integer(octave)
    alter = %{"#" => 1, "b" => -1, "" => 0}[acc]
    middle = if opts[:clef] == :bass, do: 3 * 7 + 1, else: 4 * 7 + 6

    %{
      kind: :note,
      beat: beat * 1.0,
      type: type,
      dots: Keyword.get(opts, :dots, 0),
      tuplet: opts[:tuplet],
      midi: (octave + 1) * 12 + @pitch_class[step] + alter,
      step: step,
      octave: octave,
      alter: alter,
      accidental: opts[:accidental],
      staff_pos: octave * 7 + Enum.find_index(@steps, &(&1 == step)) - middle,
      tie_to_next: Keyword.get(opts, :tie, false),
      beam: opts[:beam],
      note_index: 0
    }
  end

  defp rest(beat, type, opts \\ []) do
    %{
      kind: :rest,
      beat: beat * 1.0,
      type: type,
      dots: Keyword.get(opts, :dots, 0),
      tuplet: opts[:tuplet],
      midi: nil,
      step: nil,
      octave: nil,
      alter: nil,
      accidental: nil,
      staff_pos: nil,
      tie_to_next: false,
      beam: nil,
      note_index: nil
    }
  end

  defp layout(measures, opts \\ []) do
    %{
      clef: Keyword.get(opts, :clef, :treble),
      key_fifths: Keyword.get(opts, :key_fifths, 0),
      time: {4, 4},
      measures:
        measures |> Enum.with_index() |> Enum.map(fn {items, i} -> %{index: i, items: items} end)
    }
  end

  # The sheet board's phrase.
  defp board do
    layout([
      [
        note("D4", 0, :quarter),
        note("E4", 1, :eighth, beam: :begin),
        note("F4", 1.5, :eighth, beam: :end),
        note("A4", 2, :quarter, dots: 1),
        rest(3.5, :eighth)
      ],
      [
        note("F4", 0, :quarter),
        note("E4", 1, :quarter),
        note("D4", 2, :quarter),
        note("C4", 3, :quarter)
      ]
    ])
  end

  # Four beamed groups of sixteenths: a measure too wide to share a system.
  defp sixteenths_measure(opts \\ []) do
    for beat <- 0..3, i <- 0..3 do
      name = Enum.at(~w(C5 D5 E5 F5), i)
      beam = Enum.at([:begin, :continue, :continue, :end], i)
      tie = opts[:tie_last] == true and beat == 3 and i == 3
      note(name, beat + i / 4, :sixteenth, beam: beam, tie: tie)
    end
  end

  # ── Reading the drawing back ──────────────────────────────────────────
  #
  # Each page's content stream, interpreted into painted shapes: what was
  # filled, in which colour, inside which system frame (systems are drawn
  # in a translated frame), plus the text shown.

  defp pages(pdf) do
    ~r/<< \/Length (\d+) \/Filter \/FlateDecode >>\nstream\n/
    |> Regex.scan(pdf, return: :index)
    |> Enum.map(fn [{at, len}, {l_at, l_len}] ->
      length = String.to_integer(binary_part(pdf, l_at, l_len))
      pdf |> binary_part(at + len, length) |> :zlib.uncompress() |> interpret()
    end)
  end

  defp interpret(content) do
    init = %{paints: [], texts: [], color: nil, frame: nil, frames: 0, shapes: [], path: []}

    state =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce(init, fn line, st -> step(String.split(line, " "), line, st) end)

    %{paints: Enum.reverse(state.paints), texts: Enum.reverse(state.texts)}
  end

  defp step(["BT" | _], line, st) do
    [_, text] = Regex.run(~r/\((.*)\) Tj ET$/, line)
    %{st | texts: [{text, st.frame} | st.texts]}
  end

  defp step(args, _line, st) do
    {op, nums} = List.pop_at(args, -1)
    nums = Enum.map(nums, &parse_num/1)
    op(op, nums, st)
  end

  defp op("rg", rgb, st), do: %{st | color: rgb}
  defp op("RG", _rgb, st), do: st
  defp op("q", [], st), do: st
  defp op("cm", _m, st), do: %{st | frame: st.frames, frames: st.frames + 1}
  defp op("Q", [], st), do: %{st | frame: nil}
  defp op("re", [x, y, w, h], st), do: %{st | shapes: [{:rect, x, y, w, h} | st.shapes]}
  defp op("m", [x, y], st), do: %{st | path: [{:m, x, y}]}
  defp op("l", [x, y], st), do: %{st | path: [{:l, x, y} | st.path]}
  defp op("c", [_, _, _, _, x, y] = c, st), do: %{st | path: [{:c, x, y, c} | st.path]}
  defp op("h", [], st), do: %{st | shapes: [subpath(Enum.reverse(st.path)) | st.shapes], path: []}

  defp op(fill, [], st) when fill in ["f", "f*"] do
    paint = %{rule: fill, color: st.color, frame: st.frame, shapes: Enum.reverse(st.shapes)}
    %{st | paints: [paint | st.paints], shapes: []}
  end

  defp subpath([{:m, _, _} | rest] = path) do
    kinds = Enum.map(rest, &elem(&1, 0))

    case kinds do
      [:c, :c, :c, :c] -> {:ellipse, size(path)}
      [:l, :l, :l] -> {:beam, size(path)}
      [:c, :c] -> {:tie, size(path)}
      _ -> {:glyph, size(path)}
    end
  end

  defp size(path) do
    points =
      Enum.flat_map(path, fn
        {:c, _, _, [x1, y1, x2, y2, x, y]} -> [{x1, y1}, {x2, y2}, {x, y}]
        {_, x, y} -> [{x, y}]
      end)

    {x0, x1} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    {y0, y1} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    {x1 - x0, y1 - y0, y0, y1}
  end

  defp parse_num(s) do
    case Float.parse(s) do
      {n, ""} -> n
      _ -> s
    end
  end

  defp ink, do: rgb(Style.paper_ink())

  defp rgb(argb) do
    import Bitwise

    Enum.map(
      [argb >>> 16 &&& 0xFF, argb >>> 8 &&& 0xFF, argb &&& 0xFF],
      &Float.round(&1 / 255, 3)
    )
  end

  # Staves: a fill of exactly five long, equally thick rectangles.
  defp staves(page) do
    for %{shapes: [{:rect, _, _, w, h} | _] = shapes} = paint <- page.paints,
        Enum.count(shapes) == 5,
        w > 100,
        Enum.all?(shapes, &match?({:rect, _, _, ^w, ^h}, &1)),
        do: paint
  end

  defp staff_space(page) do
    {low, high} =
      page |> staves() |> hd() |> Map.fetch!(:shapes) |> Enum.map(&elem(&1, 2)) |> Enum.min_max()

    (high - low) / 4
  end

  defp in_systems(page), do: Enum.filter(page.paints, &(&1.frame != nil))
  defp shapes(paints), do: Enum.flat_map(paints, & &1.shapes)

  defp noteheads(page) do
    sp = staff_space(page)

    for %{color: color, shapes: [{:ellipse, {w, _, _, _}} | _]} = paint <- in_systems(page),
        color == ink(),
        w >= sp,
        do: paint
  end

  defp dots(page) do
    sp = staff_space(page)
    for {:ellipse, {w, _, _, _}} <- shapes(in_systems(page)), w < 0.6 * sp, do: w
  end

  defp discs(page) do
    for %{color: color, shapes: [{:ellipse, _}]} = paint <- in_systems(page),
        color != ink(),
        do: paint
  end

  defp ledger_lines(page) do
    sp = staff_space(page)

    for {:rect, _, _, w, h} <- shapes(in_systems(page)),
        w > 1.5 * sp and w < 3 * sp,
        h < 0.3 * sp,
        do: w
  end

  defp barlines(page) do
    sp = staff_space(page)
    for {:rect, _, _, _, h} <- shapes(in_systems(page)), abs(h - 4 * sp) < 0.01, do: h
  end

  defp stems(page) do
    sp = staff_space(page)
    for {:rect, _, _, w, h} <- shapes(in_systems(page)), w < 0.15 * sp, h > 2 * sp, do: h
  end

  # A tuplet bracket: two hooks and the line either side of the number.
  defp brackets(page) do
    for %{shapes: [_, _, _, _] = shapes} = paint <- in_systems(page),
        Enum.all?(shapes, &match?({:rect, _, _, _, _}, &1)),
        do: paint
  end

  defp count(page, kind), do: Enum.count(shapes(in_systems(page)), &match?({^kind, _}, &1))
  defp texts(page), do: Enum.map(page.texts, &elem(&1, 0))

  # ── Engraving ─────────────────────────────────────────────────────────

  describe "engrave/3 on the sheet board's phrase" do
    setup do
      [page] = board() |> Engraver.engrave(@meta) |> pages()
      %{page: page}
    end

    test "fits on one page, in one system of five staff lines", %{page: page} do
      assert [%{shapes: lines}] = staves(page)
      assert Enum.count(lines) == 5
    end

    test "draws every note: heads, stems, the beam, the dot and C4's ledger line", %{page: page} do
      assert Enum.count(noteheads(page)) == 8
      assert Enum.count(stems(page)) == 8
      assert count(page, :beam) == 1
      assert Enum.count(dots(page)) == 1
      assert Enum.count(ledger_lines(page)) == 1
      assert count(page, :tie) == 0
    end

    test "draws the clef and the eighth rest as glyphs", %{page: page} do
      glyphs = Enum.filter(in_systems(page), &match?(%{shapes: [{:glyph, _} | _]}, &1))
      assert Enum.count(glyphs) == 2
    end

    test "has a barline, then a final double barline", %{page: page} do
      assert Enum.count(barlines(page)) == 3
    end

    test "prints the title, the summary, the tempo and 4/4", %{page: page} do
      texts = texts(page)
      assert "New phrase" in texts
      assert "8 notes \\267 2 bars at 96 \\267 D Dorian" in texts
      assert "= 96" in texts
      assert Enum.count(page.texts, &(&1 == {"4", 0})) == 2
    end

    test "has no note names unless asked", %{page: page} do
      assert discs(page) == []
    end
  end

  test "note names put a disc in the note's pitch colour, with its letter, under each note" do
    [page] = board() |> Engraver.engrave(@meta, note_names: true) |> pages()
    discs = discs(page)

    assert Enum.count(discs) == 8
    assert hd(discs).color == rgb(Style.pitch_color(62))

    assert Enum.map(
             Enum.filter(page.texts, &(elem(&1, 1) == 0 and elem(&1, 0) =~ ~r/^[A-G]/)),
             &elem(&1, 0)
           ) ==
             ~w(D E F A F E D C)
  end

  test "names a sharp or flat note with its accidental" do
    measures = [
      [note("F#4", 0, :half, accidental: :sharp), note("Bb4", 2, :half, accidental: :flat)]
    ]

    [page] = measures |> layout() |> Engraver.engrave(@meta, note_names: true) |> pages()

    assert "F#" in texts(page)
    assert "Bb" in texts(page)
  end

  test "half notes have hollow heads, whole notes no stem" do
    [page] =
      [[note("A4", 0, :half), note("B4", 2, :half)], [note("C5", 0, :whole)]]
      |> layout()
      |> Engraver.engrave(@meta)
      |> pages()

    heads = noteheads(page)
    assert Enum.count(heads) == 3
    assert Enum.all?(heads, &(&1.rule == "f*" and Enum.count(&1.shapes) == 2))
    assert Enum.count(stems(page)) == 2
  end

  test "a key signature draws one accidental per sharp, only once per system" do
    [page] = board() |> Map.put(:key_fifths, 3) |> Engraver.engrave(@meta) |> pages()
    glyphs = Enum.filter(in_systems(page), &match?(%{shapes: [{:glyph, _} | _]}, &1))
    # clef, three sharps, the eighth rest
    assert Enum.count(glyphs) == 5
  end

  test "sixteenths take two beams, a lone one a stub" do
    measures = [
      [
        note("A4", 0, :eighth, dots: 1, beam: :begin),
        note("G4", 0.75, :sixteenth, beam: :end),
        note("C5", 1, :sixteenth, beam: :begin),
        note("B4", 1.25, :sixteenth, beam: :continue),
        note("A4", 1.5, :eighth, beam: :end),
        rest(2, :half)
      ]
    ]

    [page] = measures |> layout() |> Engraver.engrave(@meta) |> pages()
    # two groups: primary + stub, primary + shared second beam
    assert count(page, :beam) == 4
  end

  test "unbeamed eighths and sixteenths get flags" do
    measures = [
      [
        note("G4", 0, :eighth),
        rest(0.5, :eighth),
        note("D5", 1, :sixteenth),
        rest(1.25, :sixteenth),
        rest(1.5, :eighth),
        rest(2, :half)
      ]
    ]

    [page] = measures |> layout() |> Engraver.engrave(@meta) |> pages()

    assert count(page, :beam) == 0
    # clef, two flags, four rests
    assert Enum.count(in_systems(page), &match?(%{shapes: [{:glyph, _} | _]}, &1)) == 7
  end

  describe "triplets" do
    defp triplets(beamed?) do
      t = {3, 2}
      beam = fn b -> if beamed?, do: b end

      layout([
        [
          note("D5", 0, :eighth, tuplet: t, beam: beam.(:begin)),
          note("E5", 1 / 3, :eighth, tuplet: t, beam: beam.(:continue)),
          note("F5", 2 / 3, :eighth, tuplet: t, beam: beam.(:end)),
          rest(1, :quarter),
          rest(2, :half)
        ]
      ])
    end

    test "a beamed triplet shows just the 3" do
      [page] = true |> triplets() |> Engraver.engrave(@meta) |> pages()
      assert Enum.count(texts(page), &(&1 == "3")) == 1
      assert brackets(page) == []
    end

    test "an unbeamed triplet gets a bracket with the 3" do
      [page] = false |> triplets() |> Engraver.engrave(@meta) |> pages()
      assert Enum.count(texts(page), &(&1 == "3")) == 1
      assert Enum.count(brackets(page)) == 1
    end

    test "a bracket clears the accidentals of high notes" do
      t = {3, 2}

      measure = [
        note("F#5", 0, :eighth, tuplet: t, accidental: :sharp),
        note("G#5", 1 / 3, :eighth, tuplet: t, accidental: :sharp),
        note("F5", 2 / 3, :eighth, tuplet: t, accidental: :natural),
        rest(1, :quarter),
        rest(2, :half)
      ]

      [page] = [measure] |> layout() |> Engraver.engrave(@meta) |> pages()
      sp = staff_space(page)
      [%{shapes: bracket}] = brackets(page)
      bracket_bottom = bracket |> Enum.map(fn {:rect, _, y, _, _} -> y end) |> Enum.min()

      # Every glyph but the clef (the only one taller than five spaces):
      # the accidentals, flags and rests.
      glyph_tops =
        for %{shapes: [{:glyph, _} | _] = shapes} <- in_systems(page),
            Enum.all?(shapes, fn {_, {_, h, _, _}} -> h < 5 * sp end),
            {:glyph, {_, _, _, top}} <- shapes,
            do: top

      assert Enum.count(glyph_tops) >= 3
      assert Enum.all?(glyph_tops, &(&1 < bracket_bottom))
    end

    test "each beat of triplets is its own group" do
      t = {3, 2}

      measure =
        for beat <- [0, 1], i <- 0..2 do
          note("G4", beat + i / 3, :eighth,
            tuplet: t,
            beam: Enum.at([:begin, :continue, :end], i)
          )
        end

      [page] = [measure ++ [rest(2, :half)]] |> layout() |> Engraver.engrave(@meta) |> pages()
      assert Enum.count(texts(page), &(&1 == "3")) == 2
    end
  end

  describe "ties" do
    test "within a system: one curve" do
      measures = [
        [note("G4", 0, :half), note("A4", 2, :half, tie: true)],
        [note("A4", 0, :whole)]
      ]

      [page] = measures |> layout() |> Engraver.engrave(@meta) |> pages()
      assert count(page, :tie) == 1
    end

    test "across a system break: half a curve on each side" do
      measures = [sixteenths_measure(tie_last: true), sixteenths_measure()]
      [page] = measures |> layout() |> Engraver.engrave(@meta) |> pages()

      assert Enum.count(staves(page)) == 2
      ties = page |> in_systems() |> Enum.filter(&match?(%{shapes: [{:tie, _}]}, &1))
      assert ties |> Enum.map(& &1.frame) |> Enum.sort() == [0, 1]
    end
  end

  describe "a long phrase" do
    setup do
      pages =
        List.duplicate(sixteenths_measure(), 24) |> layout() |> Engraver.engrave(@meta) |> pages()

      %{pages: pages}
    end

    test "flows onto several pages, numbered", %{pages: pages} do
      count = length(pages)
      assert count > 1

      for {page, n} <- Enum.with_index(pages, 1) do
        assert staves(page) != []
        assert "#{n} / #{count}" in texts(page)
      end
    end

    test "never splits a measure across systems", %{pages: pages} do
      heads_per_system =
        for page <- pages,
            {_frame, heads} <- Enum.frequencies_by(noteheads(page), & &1.frame),
            do: heads

      assert length(heads_per_system) == pages |> Enum.map(&length(staves(&1))) |> Enum.sum()
      assert Enum.all?(heads_per_system, &(&1 > 0 and rem(&1, 16) == 0))
      assert Enum.sum(heads_per_system) == 24 * 16
    end

    test "prints the title and the time signature only at the start", %{pages: [first | rest]} do
      assert "New phrase" in texts(first)
      assert Enum.count(texts(first), &(&1 == "4")) == 2

      for page <- rest do
        refute "New phrase" in texts(page)
        refute "4" in texts(page)
      end
    end
  end

  test "a phrase with no measures still prints an empty staff" do
    [page] = [] |> layout() |> Engraver.engrave(@meta) |> pages()
    assert Enum.count(staves(page)) == 1
    assert noteheads(page) == []
  end

  test "US Letter paper" do
    pdf = Engraver.engrave(board(), @meta, paper: :letter)
    assert pdf =~ "/MediaBox [0 0 612 792]"
  end

  # ── Glyphs ────────────────────────────────────────────────────────────

  describe "MusicGlyphs" do
    test "every glyph is closed contours within its bounding box" do
      for name <- MusicGlyphs.names() do
        %{ops: ops, bbox: {x0, y0, x1, y1}} = MusicGlyphs.glyph(name)

        assert [{:m, _, _} | _] = ops
        assert List.last(ops) == :z

        ops
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn
          [_, {:m, _, _}] = pair -> assert hd(pair) == :z, "#{name}: contour not closed"
          _ -> :ok
        end)

        for op <- ops, op != :z, {x, y} <- points(op) do
          assert x >= x0 and x <= x1 and y >= y0 and y <= y1,
                 "#{name}: #{inspect(op)} outside bbox"
        end
      end
    end

    test "bounding boxes are sane for a staff of four spaces" do
      space = MusicGlyphs.staff_space()

      for name <- MusicGlyphs.names() do
        {x0, y0, x1, y1} = MusicGlyphs.glyph(name).bbox
        assert x1 > x0 and y1 > y0
        assert x1 - x0 < 4 * space and y1 - y0 < 8 * space, "#{name} is too big"
        assert y0 > -3 * space and y1 < 7 * space, "#{name} is far off the staff"
      end

      {_, low, _, high} = MusicGlyphs.glyph(:treble_clef).bbox
      assert high - low > 6 * space
    end
  end

  defp points({:m, x, y}), do: [{x, y}]
  defp points({:l, x, y}), do: [{x, y}]
  defp points({:q, cx, cy, x, y}), do: [{cx, cy}, {x, y}]
end
