defmodule Humdinger.Mimi do
  @moduledoc """
  Mimi, the round hummingbird, as `Mob.Canvas` ops. A port of
  `design/boards/mimi-component.html` (moods from `00-identity.html`): the
  same shapes in the board's 64 × 56 box, scaled to `size` dp wide and
  centred on `{cx, cy}`.

  Back to front: tail, crest curl, feet, body, belly, wing, beak (upper and
  lower mandible), eyes and pupils, headphones, the marks beside the head
  (sung notes, the ↓/↑ tuning arrow), and "zZ" while asleep.

  The feathers take the colour of the sung note: body `pitch_color(note)`
  (hue (note − 21) / 87 · 300°, 72 %, 62 %), belly at 80 % / 76 %, tail,
  wing, crest and feet at 55 % / 38 %. Asleep and without a microphone she
  is grey. No note: A4's teal.

  ## Moods

  | mood          | board        | shows                                        |
  |---------------|--------------|----------------------------------------------|
  | `:idle`       | idle         | waiting, beak shut                           |
  | `:listening`  | listen       | hears breath: looks up, beak ajar            |
  | `:singing`    | soft         | beak open, one note beside the head          |
  | `:aria`       | aria / loud  | taller body, wing up, eyes shut, two notes   |
  | `:flat`       | flat         | pupils down, ↓ beside her                    |
  | `:sharp`      | sharp        | pupils up, ↑ beside her                      |
  | `:headphones` | headphones   | wearing headphones (first run)               |
  | `:paused`     | sleep        | grey, eyes shut, "zZ"                        |
  | `:no_mic`     | nomic        | grey, eyes as bars                           |

  The beak opens with loudness: `beak_open` (0..1) sets it directly;
  without it the gap is the larger of the mood's own (the board's) and
  `loudness` × the aria's. `look` points the pupils (each axis −1..1);
  flat and sharp override it, as their pupils carry the meaning. `blink`
  (0..1) closes the eyes: the screen animates it.
  """

  import Mob.Canvas

  alias Humdinger.Style
  alias Humdinger.Views.Draw

  @type mood ::
          :idle
          | :listening
          | :singing
          | :aria
          | :flat
          | :sharp
          | :headphones
          | :paused
          | :no_mic

  @typedoc "Every key is optional."
  @type state :: %{
          optional(:mood) => mood(),
          optional(:note) => number() | nil,
          optional(:loudness) => number(),
          optional(:look) => {number(), number()},
          optional(:blink) => number(),
          optional(:beak_open) => number() | nil
        }

  @moods [:idle, :listening, :singing, :aria, :flat, :sharp, :headphones, :paused, :no_mic]

  # The board's box (viewBox 0 0 64 56).
  @box_w 64
  @box_h 56
  @default_note 69

  # Beak gap per mood, in box units (the board's OPEN table).
  @beak %{
    idle: 0,
    listening: 1,
    singing: 3,
    aria: 8,
    flat: 3,
    sharp: 3,
    headphones: 2,
    paused: 0,
    no_mic: 0
  }
  @beak_max 8

  @beak_ink 0xFF2A2636
  @eye_white 0xFFFFFFFF
  @pupil 0xFF17141F
  @mark 0xFFF3EFF8
  @grey_body 0xFF6B6580
  @grey_belly 0xFF8F89A3
  @grey_dark 0xFF4A4560

  @eye_r 5.6
  @pupil_r 2.6
  @eye_y 22
  @eyes_x [21, 33]

  @tail [{9, 44}, {1, 50}, {3, 53}, {10, 49}, {5, 55}, {9, 56}, {14, 49}]

  @doc "Every mood, in the identity board's order."
  @spec moods() :: [mood()]
  def moods, do: @moods

  @doc """
  Mimi `size` dp wide (the board's 64 × 56 box, so `size · 56 / 64` tall),
  centred on `{cx, cy}`. The marks beside the head and "zZ" stay inside the
  box.
  """
  @spec ops(number(), number(), number(), state()) :: [map()]
  def ops(cx, cy, size, state \\ %{}) do
    s = size / @box_w
    ox = cx - size / 2
    oy = cy - @box_h * s / 2
    mood = Map.get(state, :mood, :idle)
    palette = palette(mood, Map.get(state, :note))
    geo = geometry(mood)

    to = fn pts ->
      Enum.map(Draw.place(pts, ox, oy, s), fn {x, y} -> {Draw.r1(x), Draw.r1(y)} end)
    end

    at = fn {x, y} -> {Draw.r1(ox + x * s), Draw.r1(oy + y * s)} end
    len = fn v -> Draw.r1(v * s) end

    List.flatten([
      path(to.(@tail), color: palette.dark, fill: true),
      path(to.(crest(geo)), color: palette.dark, width: len.(1.7), cap: :round, join: :round),
      feet(at, len, palette.dark),
      oval(at, len, {24, geo.body_cy}, 20, geo.body_ry, palette.body),
      oval(at, len, {24, geo.body_cy + 7}, 12, 10, palette.belly),
      oval(at, len, {6, geo.wing_cy}, 4, geo.wing_ry, palette.dark),
      beak(to, beak_gap(mood, state)),
      eyes(mood, state, at, len, to),
      headphones(mood, at, len, to),
      marks(mood, at, len, to),
      zz(mood, at, len)
    ])
  end

  # Mimi on the app icon: singing A4, looking up (the identity board).
  @icon_mimi %{mood: :singing, note: 69, look: {0, -1}}
  # Her width on the adaptive foreground: her farthest point (the tail and
  # feet, ≈ 38.5 board units from the box centre) stays inside the 66/108
  # safe circle: 38.5 / 64 · 0.49 ≈ 0.295 < 0.306 of the size.
  @foreground_share 0.49

  @doc """
  The app icon, `size` dp square ("Dark + pitch stripe" on the identity
  board, shown there at 140): a `surface` (#1C1925) tile with corner radius
  31/140 of its size; Mimi singing A4 with her pupils up, 105.6/140 of the
  size wide (the board's size 1.65 × 64), centred; along the bottom edge a
  stripe 10/140 high in eight equal bands, the 62 % pitch colours of A1 E2
  E3 A3 E4 A4 A5 A6 (MIDI 33 45 52 57 64 69 81 93), clipped by the rounded
  corners.

  `rounded: false` draws the tile and stripe square: the full-bleed master
  the stores and iOS mask themselves (`assets/icon/humdinger-icon-1024.png`).
  """
  @spec icon_ops(number(), keyword()) :: [map()]
  def icon_ops(size, opts \\ []) do
    r = if Keyword.get(opts, :rounded, true), do: size * 31 / 140, else: 0
    stripe_h = size * 10 / 140
    notes = [33, 45, 52, 57, 64, 69, 81, 93]
    band = size / length(notes)

    stripe =
      notes
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        points = stripe_band(i * band, (i + 1) * band, size, stripe_h, r)
        path(points, color: Style.pitch_color(m), fill: true)
      end)

    List.flatten([
      rect(0, 0, size, size, color: Style.surface(), fill: true, radius: Draw.r1(r)),
      ops(size / 2, size / 2, size * 105.6 / 140, @icon_mimi),
      stripe
    ])
  end

  @doc """
  The Android adaptive icon's foreground layer, `size` dp square: Mimi as in
  `icon_ops/2` and nothing else (the layer is transparent; the background
  layer is the `surface` colour #1C1925). Launchers mask the 108 dp layer to
  any shape and only promise the centre 66 dp circle, so she is
  0.49 of the size wide, which keeps every part of
  her inside that circle.
  """
  @spec icon_foreground_ops(number()) :: [map()]
  def icon_foreground_ops(size),
    do: ops(size / 2, size / 2, size * @foreground_share, @icon_mimi)

  # ── Palette and geometry ────────────────────────────────────────────────

  defp palette(mood, _note) when mood in [:paused, :no_mic],
    do: %{body: @grey_body, belly: @grey_belly, dark: @grey_dark}

  defp palette(_mood, note) do
    midi = (note || @default_note) |> round() |> Draw.clamp(21, 108)
    hue = (midi - 21) / 87 * 300

    %{
      body: Style.pitch_color(midi),
      belly: Style.hsl(hue, 0.80, 0.76),
      dark: Style.hsl(hue, 0.55, 0.38)
    }
  end

  defp geometry(:aria), do: %{body_cy: 29, body_ry: 21, wing_cy: 22, wing_ry: 7}
  defp geometry(_mood), do: %{body_cy: 30, body_ry: 19.5, wing_cy: 28, wing_ry: 5}

  # The curl on top of the head: three cubic segments from the board.
  defp crest(%{body_cy: cy, body_ry: ry}) do
    top = cy - ry

    Draw.cubic({22, top + 1}, {22, top - 5}, {25, top - 8}, {27.5, top - 8}, 6) ++
      tl(Draw.cubic({27.5, top - 8}, {30, top - 8}, {30.2, top - 4.5}, {27.8, top - 4.4}, 6)) ++
      tl(Draw.cubic({27.8, top - 4.4}, {26.3, top - 4.3}, {26.3, top - 6}, {27.4, top - 6}, 4))
  end

  defp feet(at, len, color) do
    for x <- [17, 25] do
      {fx, fy} = at.({x, 48})
      rect(fx, fy, len.(4), len.(5), color: color, fill: true, radius: len.(1.5))
    end
  end

  defp oval(at, len, center, rx, ry, color) do
    {x, y} = at.(center)
    ellipse(x, y, len.(rx), len.(ry), color: color, fill: true)
  end

  defp beak_gap(mood, state) do
    case Map.get(state, :beak_open) do
      open when is_number(open) ->
        Draw.clamp(open, 0, 1) * @beak_max

      nil when mood in [:paused, :no_mic] ->
        0

      nil ->
        loud = state |> Map.get(:loudness, 0) |> Draw.clamp(0, 1)
        max(@beak[mood], loud * @beak_max)
    end
  end

  defp beak(to, o) do
    {bx, by} = {41, 30}

    upper = [{bx, by - 2.2}, {63, by - 0.6 - o * 0.35}, {63, by + 0.2 - o * 0.35}, {bx, by + 1}]

    lower = [
      {bx, by + 1},
      {60 - o * 0.6, by + 1.2 + o},
      {60 - o * 0.6, by + 2.4 + o},
      {bx, by + 3.4}
    ]

    [
      path(to.(upper), color: @beak_ink, fill: true),
      path(to.(lower), color: @beak_ink, fill: true)
    ]
  end

  # ── Eyes ────────────────────────────────────────────────────────────────

  defp eyes(mood, state, at, len, to) do
    blink = state |> Map.get(:blink, 0) |> Draw.clamp(0, 1)
    {lx, ly} = look(mood, Map.get(state, :look))

    Enum.map(@eyes_x, fn ex ->
      cond do
        mood == :aria -> shut_arc(ex, len, to)
        mood in [:paused, :no_mic] or blink >= 0.85 -> shut_bar(ex, len, to)
        true -> open_eye(ex, blink, {lx, ly}, at, len)
      end
    end)
  end

  defp open_eye(ex, blink, {lx, ly}, at, len) do
    {x, y} = at.({ex, @eye_y})
    {px, py} = at.({ex + lx * 2.4, @eye_y + ly * 2.4 * (1 - blink)})
    squash = 1 - blink

    [
      ellipse(x, y, len.(@eye_r), len.(@eye_r * squash), color: @eye_white, fill: true),
      ellipse(px, py, len.(@pupil_r), len.(min(@pupil_r, @eye_r * squash)),
        color: @pupil,
        fill: true
      )
    ]
  end

  # Aria: eyes shut in a happy arc (the board's quadratic curve).
  defp shut_arc(ex, len, to) do
    pts = Draw.quad({ex - 4, @eye_y + 1}, {ex, @eye_y - 4}, {ex + 4, @eye_y + 1}, 6)
    path(to.(pts), color: @pupil, width: len.(1.8), cap: :round, join: :round)
  end

  # Asleep, no mic, or a blink at its end: a straight bar.
  defp shut_bar(ex, len, to) do
    path(to.([{ex - 4, @eye_y}, {ex + 4, @eye_y}]), color: @pupil, width: len.(1.8), cap: :round)
  end

  defp look(:flat, _look), do: {0.3, 1}
  defp look(:sharp, _look), do: {0.3, -1}
  defp look(:listening, nil), do: {0.3, -1}
  defp look(_mood, nil), do: {0, 0}
  defp look(_mood, {dx, dy}), do: {Draw.clamp(dx, -1, 1), Draw.clamp(dy, -1, 1)}

  # ── Extras ──────────────────────────────────────────────────────────────

  defp headphones(:headphones, at, len, to) do
    band = Draw.cubic({6, 30}, {6, 2}, {46, 2}, {46, 30}, 12)

    [
      path(to.(band), color: @beak_ink, width: len.(3.5)),
      for x <- [2, 42] do
        {cx, cy} = at.({x, 24})
        rect(cx, cy, len.(8), len.(12), color: @beak_ink, fill: true, radius: len.(3))
      end
    ]
  end

  defp headphones(_mood, _at, _len, _to), do: []

  # Note glyphs: the board's `a rx ry 0 1 0 0.1 0` arcs are near-full
  # ellipses whose top sits at the move-to point; the stem rises from the
  # head's right side. The 1.6 stroke around the head is folded into its radii.
  defp marks(:aria, at, len, to),
    do:
      note_glyph({50, 12}, {2.4, 2}, 52.3, 4, 1, at, len, to) ++
        note_glyph({58, 6}, {2, 1.7}, 60, 0, 0.7, at, len, to)

  defp marks(:singing, at, len, to), do: note_glyph({52, 18}, {2, 1.7}, 54, 12, 0.6, at, len, to)

  defp marks(:sharp, _at, len, to),
    do: arrow([{56, 14}, {56, 4}], [{52, 8}, {56, 4}, {60, 8}], len, to)

  defp marks(:flat, _at, len, to),
    do: arrow([{56, 40}, {56, 50}], [{52, 46}, {56, 50}, {60, 46}], len, to)

  defp marks(_mood, _at, _len, _to), do: []

  # The board draws head and stem as one path under one opacity; here they
  # are two translucent ops, so the stem starts just above the head (its
  # round cap meeting the head's edge) instead of overlapping it, which
  # would show a brighter spot.
  defp note_glyph({x, top}, {rx, ry}, stem_x, stem_top, opacity, at, len, to) do
    {hx, hy} = at.({x + 0.05, top + ry})

    [
      ellipse(hx, hy, len.(rx + 0.8), len.(ry + 0.8), color: @mark, fill: true, opacity: opacity),
      path(to.([{stem_x, top - 0.8}, {stem_x, stem_top}]),
        color: @mark,
        width: len.(1.6),
        cap: :round,
        opacity: opacity
      )
    ]
  end

  defp arrow(shaft, head, len, to) do
    style = [color: @mark, width: len.(1.6), cap: :round, join: :round, opacity: 0.8]
    [path(to.(shaft), style), path(to.(head), style)]
  end

  # "zZ" above the head, the small z's baseline on the big Z's.
  defp zz(:paused, at, len) do
    baseline = 9.3
    {zx, zy} = at.({44, baseline - 7 * 0.93})
    {bx, by} = at.({44 + Draw.text_width("z", 7), baseline - 10 * 0.93})
    style = [color: Style.muted(), weight: :bold, family: Style.font_family(:bold)]

    [
      text(zx, zy, "z", [size: len.(7)] ++ style),
      text(bx, by, "Z", [size: len.(10)] ++ style)
    ]
  end

  defp zz(_mood, _at, _len), do: []

  # One band of the icon's stripe between x0 and x1: the strip along the
  # bottom edge, `h` high, inside a rounded square of side `size`, radius r.
  defp stripe_band(x0, x1, size, h, r) do
    top = size - h
    xs = sample(x0, x1, 8)

    bottom =
      xs
      |> Enum.map(fn x -> {x, bottom_edge(x, size, r)} end)
      |> Enum.filter(fn {_x, y} -> y > top end)

    case bottom do
      [] ->
        []

      [{xa, _} | _] ->
        {xb, _} = List.last(bottom)

        [{xa, top}, {xb, top} | Enum.reverse(bottom)]
        |> Enum.map(fn {x, y} -> {Draw.r1(x), Draw.r1(y)} end)
    end
  end

  defp bottom_edge(_x, size, r) when r <= 0, do: size

  defp bottom_edge(x, size, r) do
    dx =
      cond do
        x < r -> r - x
        x > size - r -> x - (size - r)
        true -> 0
      end

    if dx >= r, do: size - r, else: size - r + :math.sqrt(r * r - dx * dx)
  end

  defp sample(a, b, n), do: for(i <- 0..n, do: a + (b - a) * i / n)
end
