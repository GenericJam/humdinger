defmodule Humdinger.Style do
  @moduledoc """
  Design tokens for Humdinger, from the Claude Design boards in `design/`
  (reference artboard 390 × 844 pt; screenshots in `design/shots/`). The
  palette is FMutate's flat skin (`design/fmutate/style.ex`): the two apps
  are siblings.

  Colours are ARGB integers (`0xAARRGGBB`), which node colour props and
  `Mob.Canvas` ops accept directly.

  Lime (`fm/0`) means "live / selected / primary action" and nothing else.
  Pitch colours (`pitch_color/2`) belong to notes: the piano strip, note
  blocks, Mimi's feathers. Violet (`agent/0`) marks anything driven by or
  sent to another app.
  """

  import Bitwise

  # ── Colour ──────────────────────────────────────────────────────────────

  @doc "App background."
  def bg, do: 0xFF14121A
  @doc "Wells: the piano roll, the spectrum, code fields."
  def bg_deep, do: 0xFF0E0D12
  @doc "Cards and sheets."
  def surface, do: 0xFF1C1925
  @doc "Buttons, segmented-control tracks."
  def raised, do: 0xFF221F2B
  @doc "Selected segment, chips."
  def raised_hi, do: 0xFF2A2636
  def selected, do: 0xFF34304A
  @doc "1 pt borders."
  def line, do: 0xFF34304A
  def line_soft, do: 0xFF2E2A3B

  def text, do: 0xFFF3EFF8
  def text_2, do: 0xFFC9C3D6
  @doc "Captions and labels (4.5:1 on `bg/0`)."
  def muted, do: 0xFFA9A3B8
  @doc "Disabled, faint labels."
  def faint, do: 0xFF6B6580

  def key_white, do: 0xFFECE7F2
  def key_black, do: 0xFF2A2633

  @doc "Live / selected / primary action."
  def fm, do: 0xFFC6F24E
  def fm_dim, do: 0xFF7FA62A
  @doc "Ink on lime."
  def ink, do: 0xFF14121A

  @doc "Another app (FMutate) is driving or being driven."
  def agent, do: 0xFFA98BFF
  def agent_bg, do: 0xFF2A2240

  @doc "Record button, Discard, Stop."
  def danger, do: 0xFFFF9A7A
  def danger_text, do: 0xFFFFB4A3
  @doc "Unsure notes, warnings."
  def warn, do: 0xFFFFB547
  @doc "MIDI chips."
  def info, do: 0xFF8FD8FF

  @doc "Sheet music paper and ink."
  def paper, do: 0xFFF7F4EC
  def paper_ink, do: 0xFF17141F

  # ── Space, radius, size ─────────────────────────────────────────────────

  @doc "Spacing scale in pt."
  def space(:xs), do: 4
  def space(:s), do: 8
  def space(:m), do: 12
  def space(:l), do: 16
  def space(:xl), do: 20
  def space(:xxl), do: 28

  def radius(:button), do: 12
  def radius(:card), do: 18
  def radius(:sheet), do: 24
  def radius(:pill), do: 999

  @doc "Minimum touch target."
  def touch, do: 48

  # ── Type ────────────────────────────────────────────────────────────────
  #
  # Display: Bricolage Grotesque 800. UI: Inter. Numbers, notes, captions:
  # JetBrains Mono. Static instances live in priv/fonts (see OFL.txt).

  @fonts [
    default: "Inter-Regular",
    medium: "Inter-Medium",
    semibold: "Inter-SemiBold",
    bold: "Inter-Bold",
    mono: "JetBrainsMono-Medium",
    mono_semibold: "JetBrainsMono-SemiBold",
    mono_bold: "JetBrainsMono-Bold",
    display: "BricolageGrotesque-ExtraBold",
    music: "NotoMusic-Regular"
  ]

  @doc "Font tokens for `font:` props (`font: :display`)."
  def font_names, do: Keyword.keys(@fonts)

  @doc """
  The font family name behind a token, for `Mob.Canvas.text/4`'s `family:`
  (canvas text takes a family name, not a token). iOS draws canvas text in
  it; Android's canvas renderer ignores `family:` and uses the system face.
  """
  def font_family(token), do: Keyword.fetch!(@fonts, token)

  @doc "The app theme: the palette above and the bundled fonts."
  def theme do
    Mob.Theme.build(
      primary: fm(),
      on_primary: ink(),
      secondary: raised_hi(),
      on_secondary: text(),
      surface: surface(),
      surface_raised: raised(),
      on_surface: text(),
      muted: muted(),
      background: bg(),
      on_background: text(),
      error: danger(),
      on_error: ink(),
      border: line(),
      radius_sm: 8,
      radius_md: 12,
      radius_lg: 18,
      fonts:
        Map.new(@fonts, fn {token, name} ->
          {token, Mob.Theme.font(name, from_file: "priv/fonts/#{name}.ttf")}
        end)
    )
  end

  # ── Pitch colours ───────────────────────────────────────────────────────

  @doc """
  The 88-key colour of a MIDI note (21 = A0 … 108 = C8): hue 0° (red) to
  300° (violet), saturation 72 %. Notes outside the piano clamp to its ends.
  Black keys and dimmed uses pass a lower `lightness` (45–50).
  """
  def pitch_color(midi, lightness \\ 62) do
    midi = midi |> round() |> max(21) |> min(108)
    hsl((midi - 21) / 87 * 300, 0.72, lightness / 100)
  end

  @doc "An opaque ARGB colour from hue (degrees), saturation and lightness (0..1)."
  def hsl(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    hp = h / 60
    x = c * (1 - abs(fmod(hp, 2) - 1))

    {r, g, b} =
      cond do
        hp < 1 -> {c, x, 0}
        hp < 2 -> {x, c, 0}
        hp < 3 -> {0, c, x}
        hp < 4 -> {0, x, c}
        hp < 5 -> {x, 0, c}
        true -> {c, 0, x}
      end

    m = l - c / 2
    argb(255, channel(r + m), channel(g + m), channel(b + m))
  end

  @doc "Replace a colour's alpha (0..1)."
  def alpha(color, a), do: (color &&& 0x00FFFFFF) ||| round(a * 255) <<< 24

  defp argb(a, r, g, b), do: a <<< 24 ||| r <<< 16 ||| g <<< 8 ||| b
  defp channel(v), do: v |> Kernel.*(255) |> round() |> max(0) |> min(255)
  defp fmod(a, b), do: a - b * Float.floor(a / b)
end
