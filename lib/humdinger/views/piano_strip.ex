defmodule Humdinger.Views.PianoStrip do
  @moduledoc """
  The Live screen's piano: an 88-key overview strip with the visible window
  boxed, and below it a zoomed keyboard of that window with the sung note
  lit (board `02-live`: overview 334 × 12 at top 70, keyboard 334 × 104 at
  top 92).

  ## Layout (canvas-local)

    * y 0–15: the overview. 88 slivers `w / 88` wide in their pitch colours
      (whites from y 6, 9 high, lightness 62; blacks from y 3, 6 high,
      lightness 45), the window box (2 px #F3EFF8 outline, r4) from y 0,
      14 high, so the overview itself starts 3 px down.
    * y 25–h: the keyboard (`h − 25` high; 104 on the board), #0E0D12 with
      r10 corners. White keys are 41 wide every 44 with bottom corners r8,
      a 9-high cap in the key's pitch colour and the note name (mono bold
      11, #6B6580) 8 above the bottom. Black keys are 26 × 62 with r6
      bottom corners, a 2 px #0E0D12 outline and a 7-high cap at lightness
      50. The active key (white or black) is filled in its pitch colour;
      a lit white key's name is drawn in ink.
    * The sung-pitch tick: with `pitch` set, a 3 × 14 r2 bar in `Style.bg/0`
      on the lit key, at the key's centre plus `(pitch − active)` key widths
      (±0.5 semitone reaches the key's edges; clamped inside it), its top
      34 above a white key's bottom (board: y 70 of 104) or 20 above a
      black key's.

  The natural height is `height/0` (129 = 3 + 12 + 10 + 104).

  ## Mapping the window to keys

  The midpoint of `low..high` (in white-key units; a black key counts as
  half-way between its neighbours) sits at the canvas centre. The key
  pitch is `(w + 18) / span` where `span` is the white-key distance from
  `low` to `high`, so the window's end keys hang partly off the edges as on
  the board (low 62 / high 76 at w 334 → 44 per key, D4 at x −29, E5 at
  323). The pitch is held between 39 and 66 (whites 36–63 wide): a window
  too wide for the canvas shows its middle, a narrow one gets wide keys.
  Keys are clipped at the canvas edges by clamping their outlines, and the
  keyboard's rounded corners are masked in the app background
  (`Style.bg/0`), which is what the board's `overflow: hidden` shows.

  ## Hit-test

  `hit/5` takes canvas-local coordinates (from `on_drag`). Above the
  keyboard (y < 25: the strip and the gap below it) it returns
  `{:window, midi}`, the overview key under the finger, for moving the
  window. On the keyboard it returns `{:key, midi}` (black keys win where
  they cover whites; the 3 px gap after a white belongs to it), and
  `:none` outside the canvas or beyond the piano's ends.

  On Android a canvas drag only starts past touch slop and `on_tap` has no
  coordinates, so a stationary tap can't reach `hit/5`; `keys/3` exposes
  the visible keys' rects for laying native tap targets over them.
  """

  import Mob.Canvas

  alias Humdinger.{Music, Style}
  alias Humdinger.Views.Draw

  @typedoc """
  `low`/`high`: the visible keyboard window (MIDI, inclusive; default
  62..76). `active`: the sung note to light, or nil. `pitch`: the sung
  pitch as fractional MIDI (the tick on the lit key), or nil. `range`: the
  singer's range; overview keys outside it are dimmed (nil: none dimmed).
  """
  @type data :: %{
          optional(:low) => integer() | nil,
          optional(:high) => integer() | nil,
          optional(:active) => integer() | nil,
          optional(:pitch) => float() | nil,
          optional(:range) => {integer(), integer()} | nil
        }

  @type hit :: {:key, integer()} | {:window, integer()} | :none

  @typedoc "A visible key's rect in canvas units (see `keys/3`)."
  @type key :: %{
          midi: integer(),
          x: float(),
          y: number(),
          w: float(),
          h: float(),
          black: boolean()
        }

  @overview_top 3
  @kb_top 25
  @height 129
  @board_pitch 44
  @gap 3
  @min_pitch 39
  @max_pitch 66
  @dim 0.35
  # White-key index within an octave for C D E F G A B.
  @white_steps [0, 2, 4, 5, 7, 9, 11]

  @doc "The natural canvas height: 3 + 12 (overview) + 10 + 104 (keyboard)."
  @spec height() :: pos_integer()
  def height, do: @height

  @doc "Canvas ops for the strip at `w` × `h`."
  @spec ops(data(), number(), number()) :: [map()]
  def ops(data, w, h) do
    kb = keyboard(data, w, h)
    active = Map.get(data, :active)

    overview_ops(data, w) ++
      [
        rect(0, @kb_top, Draw.r1(w), Draw.r1(kb.kh),
          color: Style.bg_deep(),
          fill: true,
          radius: 10
        )
      ] ++
      Enum.flat_map(kb.whites, &white_ops(&1, kb, active, w)) ++
      Enum.flat_map(kb.blacks, &black_ops(&1, kb, active, w)) ++
      pitch_tick(kb, active, Map.get(data, :pitch), w) ++
      corner_masks(w, kb.kh)
  end

  defp pitch_tick(_kb, active, pitch, _w) when is_nil(active) or is_nil(pitch), do: []

  defp pitch_tick(kb, active, pitch, w) do
    found =
      case Enum.find(kb.blacks, &(elem(&1, 0) == active)) do
        {_, l, kw} ->
          {l, kw, kb.black_h - 20}

        nil ->
          with {_, l, kw} <- Enum.find(kb.whites, &(elem(&1, 0) == active)),
               do: {l, kw, kb.kh - 34}
      end

    case found do
      {l, kw, top} ->
        x = Draw.clamp(l + kw / 2 + (pitch - active) * kw - 1.5, l + 1, l + kw - 4)

        if x >= 0 and x + 3 <= w do
          [
            rect(Draw.r1(x), Draw.r1(@kb_top + top), 3, 14,
              color: Style.bg(),
              fill: true,
              radius: 2
            )
          ]
        else
          []
        end

      nil ->
        []
    end
  end

  @doc """
  What's under canvas-local `{x, y}`: `{:key, midi}` on the keyboard,
  `{:window, midi}` on the overview strip, `:none` elsewhere.
  """
  @spec hit(data(), number(), number(), number(), number()) :: hit()
  def hit(_data, w, h, x, y) when x < 0 or y < 0 or x > w or y > h, do: :none

  def hit(_data, w, _h, x, y) when y < @kb_top do
    {:window, Draw.clamp(21 + floor(x / (w / 88)), 21, 108)}
  end

  def hit(data, w, h, x, y) do
    kb = keyboard(data, w, h)

    black =
      Enum.find(kb.blacks, fn {_m, l, bw} ->
        x >= l and x <= l + bw and y <= @kb_top + kb.black_h
      end)

    white = Enum.find(kb.whites, fn {_m, l, _ww} -> x >= l and x < l + kb.pitch end)

    case black || white do
      {m, _, _} -> {:key, m}
      nil -> :none
    end
  end

  @doc """
  The visible keyboard keys as canvas-local rects, clipped to the canvas:
  whites first, then blacks (which overlap them), so a screen laying native
  tap targets over the keys (Android `on_tap` carries no coordinates) can
  stack them in list order.
  """
  @spec keys(data(), number(), number()) :: [key()]
  def keys(data, w, h) do
    kb = keyboard(data, w, h)

    Enum.map(kb.whites, &key_rect(&1, kb.kh, false, w)) ++
      Enum.map(kb.blacks, &key_rect(&1, kb.black_h, true, w))
  end

  defp key_rect({m, l, kw}, kh, black, w) do
    x1 = Draw.clamp(l, 0, w)
    x2 = Draw.clamp(l + kw, 0, w)
    %{midi: m, x: Draw.r1(x1), y: @kb_top, w: Draw.r1(x2 - x1), h: Draw.r1(kh), black: black}
  end

  # ── Overview ────────────────────────────────────────────────────────────

  defp overview_ops(data, w) do
    mw = w / 88
    {lo, hi} = window(data)
    range = Map.get(data, :range)

    keys =
      for m <- 21..108 do
        white? = Music.white_key?(m)
        {top, kh, l} = if white?, do: {3, 9, 62}, else: {0, 6, 45}
        opts = [color: Style.pitch_color(m, l), fill: true]
        opts = if in_range?(m, range), do: opts, else: [{:opacity, @dim} | opts]
        x = (m - 21) * mw
        rect(Draw.r1(x), @overview_top + top, Draw.r1(mw + 0.4), kh, opts)
      end

    box_x = round((lo - 21) * mw)
    box_w = round((hi - lo + 1) * mw)

    keys ++
      [rect(box_x + 1, 1, box_w - 2, 12, color: Style.text(), width: 2, radius: 3)]
  end

  defp in_range?(_m, nil), do: true
  defp in_range?(m, {lo, hi}), do: m >= min(lo, hi) and m <= max(lo, hi)

  # ── Keyboard geometry ───────────────────────────────────────────────────

  # Whites and blacks as `{midi, left, width}` with lefts in canvas x
  # (possibly off-canvas; drawing clamps), the key pitch and heights.
  defp keyboard(data, w, h) do
    {lo, hi} = window(data)
    span = max(wi(hi) - wi(lo), 1)
    pitch = Draw.clamp((w + 18) / span, @min_pitch, @max_pitch)
    s = pitch / @board_pitch
    centre = (wi(lo) + wi(hi)) / 2
    x0 = w / 2 - (pitch - @gap) / 2
    left = fn k -> Float.floor(x0 + (k - centre) * pitch + 0.5) end
    white_w = pitch - @gap

    reach = w / 2 / pitch + 2
    ks = max(floor(centre - reach), wi(21))..min(ceil(centre + reach), wi(108))//1

    whites =
      for k <- ks, l = left.(k), l + white_w > 0 and l < w, do: {white_midi(k), l, white_w}

    blacks =
      for k <- ks,
          m = white_midi(k) - 1,
          m >= 21 and not Music.white_key?(m),
          l = left.(k) - 14 * s,
          l + 26 * s > 0 and l < w,
          do: {m, l, 26 * s}

    kh = h - @kb_top

    %{
      whites: whites,
      blacks: blacks,
      pitch: pitch,
      kh: kh,
      black_h: kh * 62 / 104
    }
  end

  defp window(data) do
    lo = clamp_midi(Map.get(data, :low) || 62)
    hi = clamp_midi(Map.get(data, :high) || 76)
    {min(lo, hi), max(lo, hi)}
  end

  defp clamp_midi(m), do: m |> round() |> Draw.clamp(21, 108)

  # Position in white keys from C-1; a black key sits half-way along.
  defp wi(m) do
    oct = Integer.floor_div(m, 12)
    pc = Integer.mod(m, 12)

    case Enum.find_index(@white_steps, &(&1 == pc)) do
      nil -> wi(m - 1) + 0.5
      i -> oct * 7 + i
    end
  end

  defp white_midi(k), do: Integer.floor_div(k, 7) * 12 + Enum.at(@white_steps, Integer.mod(k, 7))

  # ── Keys ────────────────────────────────────────────────────────────────

  defp white_ops({m, l, ww}, kb, active, w) do
    lit = m == active
    body = if lit, do: Style.pitch_color(m), else: Style.key_white()
    cx = l + ww / 2
    name = Music.note_name(m)
    half = Draw.text_width(name, 11) / 2

    label =
      if cx - half >= 2 and cx + half <= w - 2 do
        [
          text(Draw.r1(cx), Draw.r1(@kb_top + kb.kh - 8 - 11), name,
            color: if(lit, do: Style.ink(), else: Style.faint()),
            size: 11,
            weight: :bold,
            anchor: :center,
            family: Style.font_family(:mono_bold)
          )
        ]
      else
        []
      end

    [key_shape(l, @kb_top, ww, kb.kh, 8, body, w)] ++
      cap(lit, l, ww, 9, Style.pitch_color(m), w) ++ label
  end

  defp black_ops({m, l, bw}, kb, active, w) do
    lit = m == active
    body = if lit, do: Style.pitch_color(m), else: Style.key_black()

    [
      key_shape(l - 2, @kb_top, bw + 4, kb.black_h + 2, 8, Style.bg_deep(), w),
      key_shape(l, @kb_top, bw, kb.black_h, 6, body, w)
    ] ++ cap(lit, l, bw, 7, Style.pitch_color(m, 50), w)
  end

  defp cap(true, _l, _kw, _ch, _color, _w), do: []

  defp cap(false, l, kw, ch, color, w) do
    x1 = Draw.clamp(l, 0, w)
    x2 = Draw.clamp(l + kw, 0, w)
    [rect(Draw.r1(x1), @kb_top, Draw.r1(x2 - x1), ch, color: color, fill: true)]
  end

  # A key: square top, bottom corners rounded `r`, its outline clamped to
  # 0..w so keys hanging off the canvas are cut straight at the edge.
  defp key_shape(x, y, kw, kh, r, color, w) do
    bottom = y + kh

    points =
      [{x, y}, {x + kw, y}] ++
        arc_points({x + kw - r, bottom - r}, r, 0, 90) ++
        arc_points({x + r, bottom - r}, r, 90, 180)

    points = Enum.map(points, fn {px, py} -> {Draw.r1(Draw.clamp(px, 0, w)), Draw.r1(py)} end)
    path(points, color: color, fill: true, closed: true)
  end

  defp arc_points({cx, cy}, r, from, to) do
    for i <- 0..4 do
      a = (from + (to - from) * i / 4) * :math.pi() / 180
      {cx + r * :math.cos(a), cy + r * :math.sin(a)}
    end
  end

  # The keyboard's r10 corners: the board clips the keys with
  # `overflow: hidden`; here the corners outside the arc are painted over in
  # the app background.
  defp corner_masks(w, kh) do
    r = 10
    top = @kb_top
    bottom = @kb_top + kh

    [
      {{0, top}, {r, top + r}, 180, 270},
      {{w, top}, {w - r, top + r}, 270, 360},
      {{w, bottom}, {w - r, bottom - r}, 0, 90},
      {{0, bottom}, {r, bottom - r}, 90, 180}
    ]
    |> Enum.map(fn {{x, y}, c, from, to} ->
      points = [{x, y} | arc_points(c, r, from, to)]

      path(Enum.map(points, fn {px, py} -> {Draw.r1(px), Draw.r1(py)} end),
        color: Style.bg(),
        fill: true,
        closed: true
      )
    end)
  end
end
