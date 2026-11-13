defmodule Humdinger.Controls do
  @moduledoc """
  Controls the phrase screens share (Phrases, Review, Import), drawn as on
  the boards (`design/boards/06-record_review.html`, `07-saved.html`,
  `10-sheet_music.html`, `12-import_audio.html`): the back chevron, the
  header, segmented controls, buttons, steppers and sheets.

  Each is a function composite returning Mob nodes, called from a screen's
  `render/1` (so `self()` is the screen). Every tap target also carries
  `on_press_out={held()}`: these screens re-render while a phrase plays, and
  Android drops a plain tap whose handle is from an earlier render (MOB-509).
  The press-out itself arrives as `{:press_out, :held}`; screens ignore it.
  """

  import Mob.Canvas
  import Mob.Sigil

  alias Humdinger.{Mimi, Style}

  @doc "`{self(), :held}`: the press-out every tap target carries, so its tap survives re-renders."
  def held, do: {self(), :held}

  @doc "The 44 dp back chevron (the boards' 22 dp icon, stroke 2)."
  def back_button(tap) do
    ~MOB"""
    <Canvas id="back" width={44} height={44} draw={chevron()} on_tap={tap} on_press_out={held()} />
    """
  end

  defp chevron do
    # The board's `M15 5 l-7 7 7 7` in a 24 box drawn 22 wide, centred in 44.
    s = 22 / 24
    at = fn {x, y} -> {11 + x * s, 11 + y * s} end

    [
      path(Enum.map([{15, 5}, {8, 12}, {15, 19}], at),
        color: Style.text(),
        width: 2,
        cap: :round,
        join: :round
      )
    ]
  end

  @doc """
  The screen header: back, the title (Bricolage 22, or `size:`) with an
  optional mono subtitle, and an optional node on the right. `title_tap`
  makes the title block a tap target (Review: tap to rename).
  """
  def header(back_tap, title, subtitle, right, opts \\ []) do
    size = Keyword.get(opts, :size, 22)
    title_tap = Keyword.get(opts, :title_tap)

    ~MOB"""
    <Row align={:center} gap={8} fill_width={true}>
      {back_button(back_tap)}
      <Column weight={1} gap={1} on_tap={title_tap} on_press_out={if(title_tap, do: held())}>
        <Text text={title} font={:display} text_size={size} text_color={Style.text()} max_lines={1} />
        <Text :if={subtitle} text={subtitle} font={:mono} text_size={11} text_color={Style.muted()} />
      </Column>
      {right}
    </Row>
    """
  end

  @doc ~S|The header's small button ("Hum again", "Other file", "+ From audio file").|
  def header_button(id, label, tap, background \\ Style.surface()) do
    ~MOB"""
    <Box
      id={id}
      height={40}
      fill_width={false}
      padding_left={12}
      padding_right={12}
      corner_radius={12}
      background={background}
      align={:center}
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={label} font={:semibold} text_size={13} text_color={Style.text()} />
    </Box>
    """
  end

  @doc """
  A segmented control: `options` are `{id, label, tap}`; the one whose id is
  `selected` is filled. `height` is each segment's (38 on Review, 36 on
  Staff and Import), `text_size` its label's.
  """
  def segmented(options, selected, opts \\ []) do
    height = Keyword.get(opts, :height, 38)
    text_size = Keyword.get(opts, :text_size, 13)

    segments =
      for {id, label, tap} <- options do
        on = id == selected

        ~MOB"""
        <Box
          id={"seg_#{id}"}
          weight={1}
          height={height}
          corner_radius={9}
          background={if(on, do: Style.selected(), else: 0x00000000)}
          align={:center}
          on_tap={tap}
          on_press_out={held()}
        >
          <Text
            text={label}
            font={:semibold}
            text_size={text_size}
            text_color={if(on, do: Style.text(), else: Style.muted())}
            max_lines={1}
          />
        </Box>
        """
      end

    ~MOB"""
    <Box background={Style.surface()} corner_radius={12} padding={3} weight={1}>
      <Row gap={3} fill_width={true}>
        {segments}
      </Row>
    </Box>
    """
  end

  @doc "A labelled control row: the label column (`width` dp) and the control."
  def labelled(label, width, control) do
    ~MOB"""
    <Row align={:center} gap={8} fill_width={true}>
      <Text text={label} font={:semibold} text_size={13} text_color={Style.text()} width={width} />
      {control}
    </Row>
    """
  end

  @doc """
  The lime primary action (56 high on Review/Staff, 54 on Import), with the
  play triangle (or the stop square) before the label when `icon` is set.
  """
  def primary_button(id, label, tap, opts \\ []) do
    height = Keyword.get(opts, :height, 56)
    icon = Keyword.get(opts, :icon)

    ~MOB"""
    <Box
      id={id}
      height={height}
      corner_radius={16}
      background={Style.fm()}
      align={:center}
      on_tap={tap}
      on_press_out={held()}
    >
      <Row gap={10} align={:center} fill_width={false}>
        <Canvas :if={icon} width={16} height={16} draw={icon_ops(icon, 16, Style.ink())} />
        <Text text={label} font={:bold} text_size={16} text_color={Style.ink()} />
      </Row>
    </Box>
    """
  end

  @doc """
  A secondary action in the bottom row: `:flat` (#2A2636) or `:outline`
  (Discard: transparent, 1 dp #4A4560 border, `Style.danger_text/0`).
  """
  def action_button(id, label, tap, kind \\ :flat, opts \\ []) do
    height = Keyword.get(opts, :height, 48)
    text_size = Keyword.get(opts, :text_size, 14)

    {bg, fg, border} =
      case kind do
        :flat -> {Style.raised_hi(), Style.text(), nil}
        :outline -> {0x00000000, Style.danger_text(), 0xFF4A4560}
      end

    ~MOB"""
    <Box
      id={id}
      weight={1}
      height={height}
      corner_radius={14}
      background={bg}
      border_color={border}
      border_width={if(border, do: 1)}
      align={:center}
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={label} font={:semibold} text_size={text_size} text_color={fg} max_lines={1} />
    </Box>
    """
  end

  @doc "Three secondary actions in a row, 8 apart."
  def action_row(buttons) do
    ~MOB"""
    <Row gap={8} fill_width={true}>
      {buttons}
    </Row>
    """
  end

  @doc """
  A − value + stepper in a 44 (or `height`) high well: Tempo on Review,
  Ignore on Import. `caption` (optional) sits at the left of the value.
  """
  def stepper(id, value, minus, plus, opts \\ []) do
    height = Keyword.get(opts, :height, 44)
    caption = Keyword.get(opts, :caption)

    ~MOB"""
    <Box id={id} weight={1} height={height} corner_radius={12} background={Style.surface()}>
      <Row align={:center} fill_width={true} padding_left={4} padding_right={4}>
        {step_button("#{id}_minus", "−", minus, height)}
        <Text :if={caption} text={caption} text_size={12} text_color={Style.muted()} />
        <Spacer />
        <Text text={value} font={:mono_semibold} text_size={12} text_color={Style.text()} />
        <Spacer />
        {step_button("#{id}_plus", "+", plus, height)}
      </Row>
    </Box>
    """
  end

  defp step_button(id, label, tap, height) do
    ~MOB"""
    <Box id={id} width={44} height={height - 6} align={:center} on_tap={tap} on_press_out={held()}>
      <Text text={label} font={:bold} text_size={18} text_color={Style.text()} />
    </Box>
    """
  end

  @doc "A round 44 dp play button: lime with a dark triangle while `playing`, else #2A2636."
  def play_button(id, playing, tap) do
    {bg, fg} = if playing, do: {Style.fm(), Style.ink()}, else: {Style.raised_hi(), Style.text()}

    ~MOB"""
    <Box
      id={id}
      width={44}
      height={44}
      corner_radius={22}
      background={bg}
      align={:center}
      on_tap={tap}
      on_press_out={held()}
    >
      <Canvas width={14} height={14} draw={icon_ops(:play, 14, fg)} />
    </Box>
    """
  end

  @doc "Ops for the play triangle (`M7 4l12 8-12 8z` in a 24 box) or a stop square, `size` wide."
  def icon_ops(:play, size, color) do
    s = size / 24

    [
      path(Enum.map([{7, 4}, {19, 12}, {7, 20}], fn {x, y} -> {x * s, y * s} end),
        color: color,
        fill: true
      )
    ]
  end

  def icon_ops(:stop, size, color) do
    s = size / 24
    [rect(6 * s, 6 * s, 12 * s, 12 * s, color: color, fill: true, radius: 2 * s)]
  end

  @doc "The ⋯ button (three 4 dp dots in #C9C3D6, 44 dp target)."
  def more_button(id, tap) do
    dots =
      for x <- [15, 22, 29], do: circle(x, 22, 2, color: Style.text_2(), fill: true)

    ~MOB"""
    <Canvas id={id} width={44} height={44} draw={dots} on_tap={tap} on_press_out={held()} />
    """
  end

  @doc "Mimi on a `w` × `h` canvas, `size` wide, centred."
  def mimi(w, h, size, state) do
    ~MOB"""
    <Canvas width={w} height={h} draw={Mimi.ops(w / 2, h / 2, size, state)} />
    """
  end

  @doc """
  A bottom sheet (content height) on `Style.surface/0`: `on_dismiss` is the
  swipe-down / back / outside tap. `id` keeps one sheet's identity.
  """
  def sheet(id, on_dismiss, children) do
    ~MOB"""
    <Sheet
      id={id}
      detents={[:content]}
      on_dismiss={on_dismiss}
      background={Style.surface()}
      corner_radius={24}
    >
      <Column padding_left={20} padding_right={20} padding_top={8} padding_bottom={24} gap={8}>
        {children}
      </Column>
    </Sheet>
    """
  end

  @doc "A sheet's title (and optional note under it)."
  def sheet_title(title, note \\ nil) do
    ~MOB"""
    <Column gap={4} padding_bottom={4}>
      <Text text={title} font={:bold} text_size={17} text_color={Style.text()} />
      <Text :if={note} text={note} text_size={13} text_color={Style.text_2()} />
    </Column>
    """
  end

  @doc "A full-width row in a menu sheet; `:danger` labels it in the Discard colour."
  def menu_item(id, label, tap, kind \\ :normal) do
    color = if kind == :danger, do: Style.danger_text(), else: Style.text()

    ~MOB"""
    <Box
      id={id}
      height={48}
      corner_radius={12}
      background={Style.raised()}
      padding_left={16}
      align={:leading}
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={label} font={:semibold} text_size={15} text_color={color} />
    </Box>
    """
  end

  @doc "A notice line (an export that failed, a file that couldn't be read)."
  def notice(nil), do: nil

  def notice(text) do
    ~MOB"""
    <Text id="notice" text={text} text_size={12} text_color={Style.warn()} />
    """
  end
end
