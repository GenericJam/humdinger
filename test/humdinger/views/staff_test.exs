defmodule Humdinger.Views.StaffTest do
  use ExUnit.Case, async: true

  alias Humdinger.Style
  alias Humdinger.Views.Staff

  @w 350

  # ── Builders ──────────────────────────────────────────────────────────────

  defp note(beat, type, pos, extra \\ %{}) do
    Map.merge(
      %{
        kind: :note,
        beat: beat,
        type: type,
        dots: 0,
        tuplet: nil,
        midi: 71 + pos,
        step: "B",
        octave: 4,
        alter: 0,
        accidental: nil,
        staff_pos: pos,
        tie_to_next: false,
        beam: nil,
        note_index: nil
      },
      extra
    )
  end

  defp rest(beat, type, extra \\ %{}) do
    Map.merge(
      %{kind: :rest, beat: beat, type: type, dots: 0, tuplet: nil, staff_pos: nil, beam: nil},
      extra
    )
  end

  defp data(measures, opts \\ []) do
    %{
      layout: %{
        clef: Keyword.get(opts, :clef, :treble),
        key_fifths: Keyword.get(opts, :fifths, 0),
        time: Keyword.get(opts, :time, {4, 4}),
        measures: Enum.with_index(measures, fn items, i -> %{index: i, items: items} end)
      },
      note_names: Keyword.get(opts, :names, false)
    }
  end

  defp quarters(pos), do: for(b <- 0..3, do: note(b * 1.0, :quarter, pos))

  defp render(d, w \\ @w), do: Staff.ops(d, w, Staff.height(d, w))

  defp top(d, w \\ @w), do: d |> Staff.systems(w) |> hd() |> Map.fetch!(:top)

  defp of(ops, kind), do: Enum.filter(ops, &(&1.op == kind))
  defp heads(ops), do: of(ops, :ellipse)
  defp ledgers(ops), do: ops |> of(:rect) |> Enum.filter(&(&1.w == 22))
  defp stems(ops), do: ops |> of(:rect) |> Enum.filter(&(&1.w == 1.6))
  defp beams(ops), do: ops |> of(:path) |> Enum.filter(&match?([_, _, _, _], &1.points))
  defp glyphs(ops), do: ops |> of(:path) |> Enum.filter(&match?([_, _, _, _, _ | _], &1.points))
  defp xs(%{points: pts}), do: Enum.map(pts, &hd/1)
  defp ys(%{points: pts}), do: Enum.map(pts, &List.last/1)
  # The clef is the only glyph starting right after the start barline (x 14).
  defp clefs(ops), do: ops |> glyphs() |> Enum.filter(&(Enum.min(xs(&1)) < 26))

  # ── Geometry ──────────────────────────────────────────────────────────────

  test "staff positions map to lines and spaces half a staff space apart" do
    assert Staff.staff_y(50, 0) == 74.0
    assert Staff.staff_y(50, 4) == 50.0
    assert Staff.staff_y(50, -4) == 98.0
    assert Staff.staff_y(50, 1) == 68.0
    assert Staff.staff_y(50, -7) == 116.0
  end

  test "the first staff sits 40 below the card's 10 padding, lines 12 apart" do
    d = data([quarters(0)])
    ops = render(d)
    lines = ops |> of(:rect) |> Enum.filter(&(&1.h == 1.2 and &1.w > 100))

    assert top(d) == 50
    assert Enum.map(lines, &(&1.y + 0.6)) == [50.0, 62.0, 74.0, 86.0, 98.0]
    assert Enum.all?(lines, &(&1.x == 14 and &1.x + &1.w == @w - 14))
  end

  test "noteheads land on their staff position" do
    d =
      data([
        [
          note(0.0, :quarter, -5),
          note(1.0, :quarter, 0),
          note(2.0, :quarter, 3),
          note(3.0, :half, 7)
        ]
      ])

    t = top(d)

    assert d |> render() |> heads() |> Enum.map(& &1.y) ==
             Enum.map([-5, 0, 3, 7], &Staff.staff_y(t, &1))
  end

  test "ledger lines: one per line beyond the staff, at those lines" do
    count = fn pos -> data([[note(0.0, :whole, pos)]]) |> render() |> ledgers() |> length() end

    assert Enum.map([5, 6, 7, 8, 9, 10], count) == [0, 1, 1, 2, 2, 3]
    assert Enum.map([-5, -6, -7, -8, -10], count) == [0, 1, 1, 2, 3]

    d = data([[note(0.0, :whole, -8)]])
    t = top(d)

    assert d |> render() |> ledgers() |> Enum.map(&(&1.y + 0.6)) == [
             Staff.staff_y(t, -6),
             Staff.staff_y(t, -8)
           ]
  end

  # ── Stems ─────────────────────────────────────────────────────────────────

  test "stems go up on the right below the middle line, down on the left from it" do
    for {pos, side} <- [{-3, :up}, {-1, :up}, {0, :down}, {2, :down}] do
      ops = render(data([[note(0.0, :whole, 0), note(4.0, :quarter, pos)]]))
      [_, head] = heads(ops)
      [stem] = stems(ops)

      case side do
        :up ->
          assert stem.x == Float.round(head.x + 5.4, 1)
          assert_in_delta stem.y + stem.h, head.y, 0.11
          assert stem.h >= 42

        :down ->
          assert stem.x == Float.round(head.x - 7, 1)
          assert stem.y == head.y
          assert stem.h >= 42
      end
    end
  end

  test "whole notes have no stem; stems on ledger notes reach the middle line" do
    assert data([[note(0.0, :whole, -3)]]) |> render() |> stems() == []

    d = data([[note(0.0, :quarter, -10)]])
    [stem] = d |> render() |> stems()
    assert stem.y <= Staff.staff_y(top(d), 0)
  end

  # ── Beams and flags ───────────────────────────────────────────────────────

  test "a beam group draws one beam from the first stem to the last" do
    group = [
      note(0.0, :eighth, -4, %{beam: :begin}),
      note(0.5, :eighth, -2, %{beam: :continue}),
      note(1.0, :eighth, -3, %{beam: :end})
    ]

    ops = render(data([group]))
    [beam] = beams(ops)
    hs = heads(ops)

    assert_in_delta Enum.min(xs(beam)), hd(hs).x + 5.4, 0.11
    assert_in_delta Enum.max(xs(beam)), List.last(hs).x + 7, 0.11

    # Every stem runs from its head to the beam, at least 32 long.
    for {stem, head} <- Enum.zip(stems(ops), hs) do
      assert_in_delta stem.y + stem.h, head.y, 0.11
      assert stem.y >= Enum.min(ys(beam)) - 0.2 and stem.y <= Enum.max(ys(beam))
      assert stem.h >= 32
    end

    # Beamed eighths carry no flags.
    assert glyphs(ops) |> length() == 1
  end

  test "a beam group above the middle line hangs its stems down on the left" do
    ops =
      render(
        data([[note(0.0, :eighth, 2, %{beam: :begin}), note(0.5, :eighth, 4, %{beam: :end})]])
      )

    [beam] = beams(ops)
    [h1, h2] = heads(ops)

    assert_in_delta Enum.min(xs(beam)), h1.x - 7, 0.11
    assert_in_delta Enum.max(xs(beam)), h2.x - 5.4, 0.11
    assert Enum.min(ys(beam)) > h2.y
  end

  test "sixteenths get a second beam" do
    run = [
      note(0.0, :sixteenth, -3, %{beam: :begin}),
      note(0.25, :sixteenth, -2, %{beam: :continue}),
      note(0.5, :sixteenth, -1, %{beam: :continue}),
      note(0.75, :sixteenth, -2, %{beam: :end})
    ]

    assert [run] |> data() |> render() |> beams() |> length() == 2

    # An eighth + two sixteenths: the second beam spans only the sixteenths.
    mixed = [
      note(0.0, :eighth, -3, %{beam: :begin}),
      note(0.5, :sixteenth, -2, %{beam: :continue}),
      note(0.75, :sixteenth, -1, %{beam: :end})
    ]

    ops = render(data([mixed]))
    [primary, secondary] = beams(ops)
    [h1, h2, h3] = heads(ops)
    assert_in_delta Enum.min(xs(primary)), h1.x + 5.4, 0.11
    assert_in_delta Enum.min(xs(secondary)), h2.x + 5.4, 0.11
    assert_in_delta Enum.max(xs(secondary)), h3.x + 7, 0.11
  end

  test "unbeamed eighths and sixteenths get flags; a lone :begin falls back to a flag" do
    flags = fn items -> [items] |> data() |> render() |> glyphs() |> length() |> Kernel.-(1) end

    assert flags.([note(0.0, :eighth, -2)]) == 1
    assert flags.([note(0.0, :sixteenth, 3)]) == 2
    assert flags.([note(0.0, :quarter, -2)]) == 0
    assert flags.([note(0.0, :eighth, -2, %{beam: :begin}), note(0.5, :quarter, -2)]) == 1
  end

  # ── Accidentals, dots, ties, tuplets ──────────────────────────────────────

  test "an accidental is drawn left of the head only when one is printed" do
    for kind <- [:sharp, :flat, :natural] do
      ops = render(data([[note(0.0, :whole, -2, %{accidental: kind, alter: 1})]]))
      [head] = heads(ops)
      [_clef, acc] = glyphs(ops)

      assert Enum.max(xs(acc)) < head.x - 7
      assert Enum.min(ys(acc)) < head.y and Enum.max(ys(acc)) > head.y
    end

    # In the key signature already: altered, but no accidental printed.
    ops = render(data([[note(0.0, :whole, -2, %{accidental: nil, alter: 1})]], fifths: 2))
    assert length(glyphs(ops)) == 1 + 2
  end

  test "a dotted note has a dot to its right, lifted into the space when on a line" do
    d =
      data([
        [note(0.0, :half, 0, %{dots: 1}), note(3.0, :quarter, -1, %{dots: 0})],
        [note(0.0, :half, -1, %{dots: 1})]
      ])

    t = top(d)
    ops = render(d)
    dots = Enum.filter(of(ops, :circle), &(&1.r == 2.2))
    [h1, _, h3] = heads(ops)

    assert [d1, d2] = dots
    assert {d1.x, d1.y} == {Float.round(h1.x + 12, 1), Staff.staff_y(t, 1)}
    assert {d2.x, d2.y} == {Float.round(h3.x + 12, 1), Staff.staff_y(t, -1)}
  end

  test "a tie curves from one head to the next, split across a system break" do
    tied = data([[note(0.0, :half, -2, %{tie_to_next: true}), note(2.0, :half, -2)]])
    ops = render(tied)
    [h1, h2] = heads(ops)
    [_clef, tie] = glyphs(ops)

    assert Enum.min(xs(tie)) > h1.x and Enum.max(xs(tie)) < h2.x
    # Stems up, so the tie goes below the heads.
    assert Enum.min(ys(tie)) > h1.y

    # Many measures at a narrow width: the tie at a system end is drawn twice.
    split =
      data(
        List.duplicate(quarters(-2), 2) ++
          [[note(0.0, :whole, -2, %{tie_to_next: true})], [note(0.0, :whole, -2)]]
      )

    ops = render(split, 200)
    assert [_, _ | _] = Staff.systems(split, 200)
    assert glyphs(ops) |> Enum.reject(&(&1 in clefs(ops))) |> length() == 2
  end

  test "triplets get a bracket with a 3" do
    trip =
      for {b, p} <- [{0.0, -2}, {1 / 3, -1}, {2 / 3, 0}],
          do: note(b, :eighth, p, %{tuplet: {3, 2}})

    ops = render(data([trip ++ [rest(1.0, :quarter), rest(2.0, :half)]]))

    assert [%{text: "3"}] = Enum.filter(of(ops, :text), &(&1.text == "3"))
    assert [_, _, _, _] = of(ops, :line)

    plain =
      render(
        data([
          [note(0.0, :eighth, -2), rest(0.5, :eighth), rest(1.0, :quarter), rest(2.0, :half)]
        ])
      )

    assert of(plain, :line) == []
  end

  # ── Rests ─────────────────────────────────────────────────────────────────

  test "every rest kind renders at its standard place" do
    d = data([[rest(0.0, :half), rest(2.0, :quarter), rest(3.0, :eighth), rest(3.5, :sixteenth)]])
    t = top(d)
    ops = render(d)

    # A half rest sits on the middle line …
    assert [half] = ops |> of(:rect) |> Enum.filter(&(&1.w == 12))
    assert_in_delta half.y + half.h, Staff.staff_y(t, 0), 0.01

    [_clef, quarter, eighth, sixteenth] = glyphs(ops)
    height = fn g -> Enum.max(ys(g)) - Enum.min(ys(g)) end
    assert height.(quarter) > height.(sixteenth)
    assert height.(sixteenth) > height.(eighth)

    for g <- [quarter, eighth, sixteenth] do
      assert Enum.min(ys(g)) >= Staff.staff_y(t, 4) and Enum.max(ys(g)) <= Staff.staff_y(t, -4)
    end

    # … a whole rest hangs from the 4th line.
    whole = data([[rest(0.0, :whole)]])
    assert [block] = whole |> render() |> of(:rect) |> Enum.filter(&(&1.w == 12))
    assert block.y == Staff.staff_y(top(whole), 2)
  end

  test "a measure holding only a whole rest centres it" do
    d = data([quarters(-2), [rest(0.0, :whole)]])
    [sys] = Staff.systems(d, 500)
    ops = render(d, 500)
    [block] = ops |> of(:rect) |> Enum.filter(&(&1.w == 12))

    [barline] =
      ops |> of(:rect) |> Enum.filter(&(&1.w == 1.4 and &1.x > 100 and &1.x < sys.right - 20))

    assert_in_delta block.x + 6, (barline.x + sys.right) / 2, 1
  end

  # ── Key and time signatures ───────────────────────────────────────────────

  # Whole-rest measures draw no paths, so the only glyphs are the clef and
  # the key signature on each system.
  defp rests_only(n, opts), do: data(List.duplicate([rest(0.0, :whole)], n), opts)

  test "the key signature has |key_fifths| glyphs on every system" do
    for fifths <- [-7, -3, 0, 1, 4, 7] do
      d = rests_only(9, fifths: fifths)
      systems = length(Staff.systems(d, 300))
      ops = render(d, 300)

      assert systems >= 2
      assert length(clefs(ops)) == systems
      assert length(glyphs(ops)) == systems * (1 + abs(fifths))
    end
  end

  test "key signature glyphs follow F C G D A E B and B E A D G C F per clef" do
    key_ys = fn fifths, clef ->
      ops = render(rests_only(1, fifths: fifths, clef: clef))

      (glyphs(ops) -- clefs(ops))
      |> Enum.sort_by(&Enum.min(xs(&1)))
      |> Enum.map(&Enum.min(ys(&1)))
    end

    rise = fn ys ->
      ys |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> round((a - b) / 6) end)
    end

    # Steps between successive sharps: F5 C5 G5 D5 A4 E5 B4.
    assert rise.(key_ys.(7, :treble)) == [-3, 4, -3, -3, 4, -3]
    # Flats: B4 E5 A4 D5 G4 C5 F4.
    assert rise.(key_ys.(-7, :treble)) == [3, -4, 3, -4, 3, -4]

    # Bass clef: the same pattern a third lower.
    for f <- [7, -7] do
      assert Enum.map(key_ys.(f, :bass), &Float.round(&1 - 12, 1)) == key_ys.(f, :treble)
    end
  end

  test "the time signature is on the first system only" do
    d = rests_only(9, [])
    ops = render(d, 300)

    assert [_, _ | _] = Staff.systems(d, 300)
    assert ops |> of(:text) |> Enum.map(& &1.text) == ["4", "4"]
    first_top = top(d, 300)
    assert Enum.all?(of(ops, :text), &(&1.y < first_top + 48))
  end

  # ── Wrapping ──────────────────────────────────────────────────────────────

  test "narrower canvases wrap into more systems and a taller height" do
    d =
      data(
        for(
          _ <- 1..8,
          do: ([note(0.0, :eighth, -3), note(0.5, :eighth, -2)] ++ quarters(-1)) |> Enum.take(4)
        )
      )

    narrow = Staff.systems(d, 300)
    wide = Staff.systems(d, 900)

    assert length(narrow) > length(wide)
    assert Staff.height(d, 300) > Staff.height(d, 900)

    # Every measure exactly once, in order; systems stacked downwards.
    for systems <- [narrow, wide] do
      assert Enum.flat_map(systems, & &1.measures) == Enum.to_list(0..7)
      tops = Enum.map(systems, & &1.top)
      assert tops == Enum.sort(tops)
      assert tops |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> b - a >= 150 end)
    end
  end

  test "the board's two bars at 350: a bar per system, 150 apart, card 316 tall" do
    d = board()
    assert [%{top: 50, measures: [0]}, %{top: 200, measures: [1]}] = Staff.systems(d, 350)
    assert Staff.height(d, 350) == 316
  end

  test "a short last system keeps its natural width; a nearly full one is stretched" do
    short = data([quarters(-2), quarters(-2), [note(0.0, :whole, -2)]])
    systems = Staff.systems(short, 300)
    assert [_, _ | _] = systems
    assert List.last(systems).right < 300 - 14
    assert Enum.all?(Enum.drop(systems, -1), &(&1.right == 300 - 14))

    full = data([quarters(-2)])
    assert [%{right: 336}] = Staff.systems(full, 350)
  end

  test "the final barline is thin + thick at the end of the last system" do
    d = data(List.duplicate(quarters(-2), 4))
    ops = render(d, 300)
    last = d |> Staff.systems(300) |> List.last()
    thick = ops |> of(:rect) |> Enum.filter(&(&1.w == 6))

    assert [bar] = thick
    assert_in_delta bar.x + bar.w, last.right, 0.01
    assert bar.y < last.top and bar.y + bar.h > last.top + 48

    thin =
      Enum.find(
        of(ops, :rect),
        &(&1.w == 1.4 and &1.x > bar.x - 12 and &1.x < bar.x and &1.y == bar.y)
      )

    assert thin
  end

  # ── Note names ────────────────────────────────────────────────────────────

  test "note names: a dot in the pitch colour 34 below the staff, with its letter" do
    d = board()
    ops = render(d)
    t = top(d)
    dots = Enum.filter(of(ops, :circle), &(&1.r == 9))
    first = Enum.take(dots, 4)

    assert Enum.count(dots) == 8
    assert Enum.map(first, & &1.color) == Enum.map([62, 64, 65, 69], &Style.pitch_color(&1, 58))
    assert Enum.all?(first, &(&1.y == t + 48 + 34))
    assert ops |> of(:text) |> Enum.map(& &1.text) |> Enum.drop(2) |> Enum.take(4) == ~w(D E F A)

    assert board()
           |> Map.put(:note_names, false)
           |> render()
           |> of(:circle)
           |> Enum.all?(&(&1.r != 9))
  end

  # ── Empty data ────────────────────────────────────────────────────────────

  test "no layout or no measures: the paper card with an empty staff" do
    for d <- [%{layout: nil}, %{}, data([]), data([[]])] do
      ops = render(d)
      [paper | _] = ops

      assert paper.color == Style.paper() and paper.radius == 16
      assert heads(ops) == []
      assert ops |> of(:rect) |> Enum.count(&(&1.h == 1.2 and &1.w > 100)) == 5
      assert [_] = clefs(ops)
      assert Staff.height(d, @w) >= 166
    end
  end

  defp board do
    data(
      [
        [
          note(0.0, :quarter, -5, %{midi: 62, step: "D"}),
          note(1.0, :eighth, -4, %{midi: 64, step: "E", beam: :begin}),
          note(1.5, :eighth, -3, %{midi: 65, step: "F", beam: :end}),
          note(2.0, :quarter, -1, %{midi: 69, step: "A", dots: 1}),
          rest(3.5, :eighth)
        ],
        [
          note(0.0, :quarter, -3, %{midi: 65, step: "F"}),
          note(1.0, :quarter, -4, %{midi: 64, step: "E"}),
          note(2.0, :quarter, -5, %{midi: 62, step: "D"}),
          note(3.0, :quarter, -6, %{midi: 60, step: "C"})
        ]
      ],
      names: true
    )
  end
end
