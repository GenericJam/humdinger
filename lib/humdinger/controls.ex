defmodule Humdinger.Controls do
  @moduledoc """
  The UI pieces every screen shares, drawn as on the boards
  (`design/shots/*.webp`, `design/boards/*.html`): the page column, the
  header with its back chevron, section headings, buttons, segmented
  controls, chips, switches, steppers, sheets and Mimi on a canvas.

  Each is a function composite returning Mob nodes, called from a screen's
  `render/1` (screens `import Humdinger.Controls`), so `self()` is the
  screen and the tap targets are `{self(), tag}`. Where screens need a
  different size or colour they pass options; the defaults are the boards'.

  Every tap target carries `on_press_out={held()}`: the screens re-render
  many times a second (Engine frames, Output events, a phrase playing), and
  Mob's Android bridge drops a plain tap whose handle is from an earlier
  render (MOB-509); a node with a press handler is matched by slot, pid and
  tag instead. The press-out arrives as `{:press_out, :held}`; screens
  answer it with nothing.
  """

  import Mob.Canvas
  import Mob.Sigil

  alias Humdinger.{Mimi, Style}

  # The boards' side margin: 390 artboard, content 350.
  @margin 20

  @doc "`{self(), :held}`: the press-out every tap target carries, so its tap survives re-renders."
  def held, do: {self(), :held}

  @doc """
  The width the boards lay out in (390 artboard − 20 a side): canvases are
  drawn at it, so the page is a column this wide, centred (wider phones get
  wider margins; Mob gives screens no window width).
  """
  def content_width, do: 350

  # ── Layout ──────────────────────────────────────────────────────────────

  @doc """
  A screen's page on the app background: `children` (nils dropped) in the
  boards' column, centred between flexible spacers (a column's `align`
  doesn't move a fixed-width child).

  Options: `width` (default `content_width/0`; nil: the full width less 20
  a side, for screens without fixed-width canvases), `gap` (12; nil for
  none), `padding_top` (12), `padding_bottom` (22).
  """
  def page(children, opts \\ []) do
    column(
      children,
      Keyword.get(opts, :width, content_width()),
      Style.bg(),
      true,
      Keyword.get(opts, :padding_top, 12),
      Keyword.get(opts, :padding_bottom, 22),
      Keyword.get(opts, :gap, 12)
    )
  end

  defp column(children, nil, background, fill_height, top, bottom, gap) do
    margin = @margin

    ~MOB"""
    <Column
      background={background}
      fill_width={true}
      fill_height={fill_height}
      padding_left={margin}
      padding_right={margin}
      padding_top={top}
      padding_bottom={bottom}
      gap={gap}
    >
      {clean(children)}
    </Column>
    """
  end

  defp column(children, width, background, fill_height, top, bottom, gap) do
    ~MOB"""
    <Row background={background} fill_width={true} fill_height={fill_height} align={:top}>
      <Spacer />
      <Column
        width={width}
        fill_height={fill_height}
        padding_top={top}
        padding_bottom={bottom}
        gap={gap}
      >
        {clean(children)}
      </Column>
      <Spacer />
    </Row>
    """
  end

  defp clean(children), do: children |> List.flatten() |> Enum.reject(&is_nil/1)

  @doc """
  `node` centred across the width (a Row with spacers: Android's Column
  ignores `align`).
  """
  def centered(node) do
    ~MOB"""
    <Row fill_width={true}>
      <Spacer />
      {node}
      <Spacer />
    </Row>
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

  # ── Header ──────────────────────────────────────────────────────────────

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

  @doc "A section heading: mono 11, spaced capitals."
  def heading(text) do
    ~MOB"""
    <Text
      text={text}
      font={:mono_semibold}
      text_size={11}
      letter_spacing={0.88}
      text_color={Style.muted()}
    />
    """
  end

  # ── Buttons ─────────────────────────────────────────────────────────────

  @doc """
  A rounded button with a centred label. `kind` picks the boards' look:

    * `:flat` (default): #1F1C27 surface, white bold 14, 44 high, round ends
      (Live's trouble actions, First run).
    * `:lime`: the lime primary of the same shape ("Done", "Start humming").
    * `:primary`: the full-width lime action, 56 high, radius 16, bold 16
      ("Play out", "Edit as a phrase"); `icon: :play | :stop` before the label.
    * `:header`: 40 high, radius 12, semibold 13 on the surface ("Hum
      again", "Other file").
    * `:raised`: #2A2636, radius 12, semibold 13 (Output's buttons, Paste).
    * `:action`: a bottom-row action, #2A2636, 48 high, radius 14,
      semibold 14, sharing the row (`weight: 1`).
    * `:outline`: the same in Discard's colours: transparent, 1 dp #4A4560
      border, `Style.danger_text/0`.

  Options override the kind: `id`, `width`, `weight`, `fill_width`,
  `height`, `radius`, `padding` (each side), `background` (nil for none),
  `color` (the label's), `font`, `text_size`, `max_lines`, `icon`. A nil
  `tap` draws the button without a target ("Connecting…").
  """
  def button(label, tap, opts \\ []) do
    style = button_style(Keyword.get(opts, :kind, :flat))
    o = fn key -> Keyword.get(opts, key, Map.get(style, key)) end
    weight = o.(:weight)
    border = o.(:border)
    color = o.(:color)
    text = button_label(label, o, color)

    content =
      case o.(:icon) do
        nil ->
          text

        icon ->
          ~MOB"""
          <Row gap={10} align={:center} fill_width={false}>
            <Canvas width={16} height={16} draw={icon_ops(icon, 16, color)} />
            {text}
          </Row>
          """
      end

    ~MOB"""
    <Box
      id={o.(:id)}
      width={o.(:width)}
      weight={weight}
      fill_width={Keyword.get(opts, :fill_width, style.fill or weight != nil)}
      height={o.(:height)}
      corner_radius={o.(:radius)}
      background={o.(:background)}
      border_color={border}
      border_width={if(border, do: 1)}
      padding_left={o.(:padding)}
      padding_right={o.(:padding)}
      align="center"
      on_tap={tap}
      on_press_out={if(tap, do: held())}
    >
      {content}
    </Box>
    """
  end

  defp button_label(label, o, color) do
    ~MOB"""
    <Text
      text={label}
      font={o.(:font)}
      text_size={o.(:text_size)}
      text_color={color}
      max_lines={o.(:max_lines)}
      text_align="center"
      fill_width={false}
    />
    """
  end

  defp button_style(:flat),
    do: %{
      background: Style.surface(),
      color: Style.text(),
      height: 44,
      radius: 22,
      padding: 18,
      font: :bold,
      text_size: 14,
      fill: false
    }

  defp button_style(:lime),
    do: %{button_style(:flat) | background: Style.fm(), color: Style.ink()}

  defp button_style(:primary),
    do: %{
      background: Style.fm(),
      color: Style.ink(),
      height: 56,
      radius: 16,
      font: :bold,
      text_size: 16,
      fill: true
    }

  defp button_style(:header),
    do: %{
      background: Style.surface(),
      color: Style.text(),
      height: 40,
      radius: 12,
      padding: 12,
      font: :semibold,
      text_size: 13,
      fill: false
    }

  defp button_style(:raised),
    do: %{button_style(:header) | background: Style.raised_hi(), height: 44, padding: 4}

  defp button_style(:action),
    do: %{
      background: Style.raised_hi(),
      color: Style.text(),
      weight: 1,
      height: 48,
      radius: 14,
      font: :semibold,
      text_size: 14,
      max_lines: 1,
      fill: true
    }

  defp button_style(:outline),
    do:
      Map.merge(button_style(:action), %{
        background: 0x00000000,
        color: Style.danger_text(),
        border: 0xFF4A4560
      })

  @doc "Bottom-row actions in a row, 8 apart."
  def action_row(buttons) do
    ~MOB"""
    <Row gap={8} fill_width={true}>
      {buttons}
    </Row>
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

  # ── Choices ─────────────────────────────────────────────────────────────

  @doc """
  A segmented control: `options` are `%{label, tap, selected}`, optionally
  `id` (the segment's node id) and `sub` (a second mono line). Options:
  `height` (each segment's, default 40), `width` (nil: the control takes
  `weight: 1` in its row), `track` (default `Style.surface/0`), `text_size`
  (13).
  """
  def segmented(options, opts \\ []) do
    height = Keyword.get(opts, :height, 40)
    width = Keyword.get(opts, :width)
    weight = if width, do: nil, else: 1
    track = Keyword.get(opts, :track, Style.surface())
    size = Keyword.get(opts, :text_size, 13)

    ~MOB"""
    <Row width={width} weight={weight} background={track} corner_radius={12} padding={3} gap={3}>
      {Enum.map(options, &segment(&1, height, size))}
    </Row>
    """
  end

  @doc """
  `segmented/2` options for `choices` (`[value: label]`): a tap sends
  `{tag, value}`, the segment with `selected`'s value is filled, and each
  is the node `"seg_<value>"`.
  """
  def segments(choices, selected, tag) do
    for {value, label} <- choices,
        do: %{
          id: "seg_#{value}",
          label: label,
          tap: {self(), {tag, value}},
          selected: value == selected
        }
  end

  defp segment(option, height, size) do
    selected = option.selected
    # An unselected segment shows the track through it.
    bg = if selected, do: Style.selected(), else: 0x00000000
    color = if selected, do: Style.text(), else: Style.muted()
    sub_color = if selected, do: Style.text_2(), else: Style.muted()
    sub = Map.get(option, :sub)

    ~MOB"""
    <Box
      id={Map.get(option, :id)}
      weight={1}
      height={height}
      corner_radius={9}
      background={bg}
      align="center"
      on_tap={option.tap}
      on_press_out={held()}
    >
      <Column fill_width={true}>
        <Text
          text={option.label}
          font={:semibold}
          text_size={size}
          text_align="center"
          fill_width={true}
          text_color={color}
          max_lines={1}
        />
        <Text
          :if={sub}
          text={sub}
          font={:mono}
          text_size={9}
          text_align="center"
          fill_width={true}
          text_color={sub_color}
        />
      </Column>
    </Box>
    """
  end

  @doc """
  A chip: `selected` fills it. `kind`:

    * `:pick` (default): the boards' picker chip (bend ranges, roots,
      modes), 34 high, mono 12 on the background, lime text when selected;
      `dim: true` fades the unselected text, `font` replaces the mono.
    * `:menu`: a chip in a sheet's grid (Import's key), semibold 13 on
      #26222F, white when selected.
    * `:tag`: a label that only shows a state (Output's WHAT GETS SENT): an
      off tag is outlined. Pass a nil `tap`.

  `id` names the node.
  """
  def chip(label, selected, tap, opts \\ []) do
    style = chip_style(Keyword.get(opts, :kind, :pick), selected, Keyword.get(opts, :dim, false))
    border = style[:border]

    ~MOB"""
    <Box
      id={Keyword.get(opts, :id)}
      fill_width={false}
      height={style[:height]}
      corner_radius={style.radius}
      background={style.background}
      border_color={border}
      border_width={if(border, do: 1)}
      padding_left={style.padding}
      padding_right={style.padding}
      padding_top={style[:padding_v]}
      padding_bottom={style[:padding_v]}
      align="center"
      on_tap={tap}
      on_press_out={if(tap, do: held())}
    >
      <Text
        text={label}
        font={Keyword.get(opts, :font, style.font)}
        text_size={style.text_size}
        text_color={style.color}
      />
    </Box>
    """
  end

  defp chip_style(:pick, selected, dim) do
    %{
      background: if(selected, do: Style.selected(), else: Style.bg()),
      color:
        cond do
          selected -> Style.fm()
          dim -> Style.faint()
          true -> Style.text_2()
        end,
      height: 34,
      radius: 9,
      padding: 8,
      font: :mono_semibold,
      text_size: 12
    }
  end

  defp chip_style(:menu, selected, _dim) do
    %{
      background: if(selected, do: Style.selected(), else: Style.raised()),
      color: if(selected, do: Style.text(), else: Style.muted()),
      radius: 9,
      padding: 12,
      padding_v: 8,
      font: :semibold,
      text_size: 13
    }
  end

  defp chip_style(:tag, selected, _dim) do
    %{
      background: if(selected, do: Style.raised_hi(), else: Style.surface()),
      border: if(selected, do: Style.raised_hi(), else: 0xFF4A4560),
      color: if(selected, do: Style.text(), else: Style.muted()),
      radius: 8,
      padding: 9,
      padding_v: 5,
      font: :mono_semibold,
      text_size: 11
    }
  end

  @doc "A 48 × 28 switch as on the Settings and Output boards: lime with a dark knob when on."
  def switch(on?, tap) do
    {track, knob, align} =
      if on?,
        do: {Style.fm(), Style.ink(), "trailing"},
        else: {Style.selected(), Style.muted(), "leading"}

    ~MOB"""
    <Box
      width={48}
      height={28}
      corner_radius={14}
      background={track}
      padding={3}
      align={align}
      on_tap={tap}
      on_press_out={held()}
    >
      <Box width={22} height={22} corner_radius={11} background={knob} />
    </Box>
    """
  end

  @doc """
  A − value + stepper in a 44 (or `height`) high well: Tempo on Review,
  Ignore on Import, octave and transpose on Live. `caption` (optional)
  sits at the left of the value. With an `id`, the − and + are
  `"<id>_minus"` and `"<id>_plus"`.
  """
  def stepper(id, value, minus, plus, opts \\ []) do
    height = Keyword.get(opts, :height, 44)
    caption = Keyword.get(opts, :caption)

    ~MOB"""
    <Box id={id} weight={1} height={height} corner_radius={12} background={Style.surface()}>
      <Row align={:center} fill_width={true} padding_left={4} padding_right={4}>
        {step_button(id && "#{id}_minus", "−", minus, height)}
        <Text :if={caption} text={caption} text_size={12} text_color={Style.muted()} />
        <Spacer />
        <Text text={value} font={:mono_semibold} text_size={12} text_color={Style.text()} />
        <Spacer />
        {step_button(id && "#{id}_plus", "+", plus, height)}
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

  # ── Mimi ────────────────────────────────────────────────────────────────

  @doc "Mimi on a `w` × `h` canvas, `size` wide, centred."
  def mimi(w, h, size, state) do
    ~MOB"""
    <Canvas width={w} height={h} draw={Mimi.ops(w / 2, h / 2, size, state)} />
    """
  end

  # ── Sheets ──────────────────────────────────────────────────────────────

  @doc """
  A bottom sheet on `Style.surface/0`: `on_dismiss` is the swipe-down /
  back / outside tap, `id` keeps one sheet's identity, `children` (nils
  dropped) stack in a column.

  Options: `detents` (default `[:content]`), `scroll` (false; true puts
  the column in a `<Scroll>`), `width` (nil: the full width less 20 a side;
  a number: a centred column that wide, for sheets with fixed-width
  canvases), `gap` (8), `padding_top` (8), `padding_bottom` (24).
  """
  def sheet(id, on_dismiss, children, opts \\ []) do
    column =
      column(
        children,
        Keyword.get(opts, :width),
        nil,
        nil,
        Keyword.get(opts, :padding_top, 8),
        Keyword.get(opts, :padding_bottom, 24),
        Keyword.get(opts, :gap, 8)
      )

    content =
      if Keyword.get(opts, :scroll, false),
        do: ~MOB(<Scroll fill_width={true}>
  {column}
</Scroll>),
        else: column

    ~MOB"""
    <Sheet
      id={id}
      detents={Keyword.get(opts, :detents, [:content])}
      on_dismiss={on_dismiss}
      background={Style.surface()}
      corner_radius={24}
    >
      {content}
    </Sheet>
    """
  end

  @doc """
  A sheet's title: bold 17 (or `font:` / `size:`), with `note:` under it
  and 4 dp below (`padding_bottom:`). `done:` (a tap) puts the lime Done
  button at its right, as on the Settings board.
  """
  def sheet_title(title, opts \\ []) do
    note = Keyword.get(opts, :note)
    done = Keyword.get(opts, :done)

    ~MOB"""
    <Column fill_width={true} gap={4} padding_bottom={Keyword.get(opts, :padding_bottom, 4)}>
      <Row>
        <Text
          text={title}
          font={Keyword.get(opts, :font, :bold)}
          text_size={Keyword.get(opts, :size, 17)}
          text_color={Style.text()}
        />
        <Spacer :if={done} />
        {if(done, do: button("Done", done, kind: :lime, height: 40, radius: 20))}
      </Row>
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
