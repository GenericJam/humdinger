defmodule Humdinger.Widgets do
  @moduledoc """
  Function composites shared by the Live, Settings, Spectrum and First run
  screens (all of which re-render on Engine frames): segmented controls,
  switches, chips, Mimi on a canvas, the step bars. Call them from a
  screen's `render/1` (they build `{self(), tag}` targets for that screen).

  Every tap target here also declares `on_press_out={held()}`: on a screen
  that re-renders many times a second Mob's Android bridge drops a plain
  tap whose handle is from an earlier render (MOB-509); a node with a press
  handler is matched by slot, pid and tag instead. The screens answer
  `{:press_out, :held}` with nothing.
  """

  import Mob.Sigil

  alias Humdinger.{Mimi, Style}

  @doc "The `on_press_out` target every tap target on a frame-driven screen carries."
  def held, do: {self(), :held}

  @doc """
  A segmented control: `options` are `%{label, tap, selected}` (optional
  `sub`, a second mono line, and `muted`). Options: `height` (segment, default
  40), `width` (nil: the control takes `weight: 1` in its row), `track`
  (default `Style.surface/0`), `text_size` (13).
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

  defp segment(option, height, size) do
    selected = option.selected
    bg = if selected, do: Style.selected(), else: track_clear()
    color = if selected, do: Style.text(), else: Style.muted()
    sub_color = if selected, do: Style.text_2(), else: Style.muted()
    sub = Map.get(option, :sub)

    ~MOB"""
    <Box
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

  # An unselected segment shows the track through it.
  defp track_clear, do: 0x00000000

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

  @doc "A 48 × 28 switch as on the Settings board: lime with a dark knob when on."
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
  A small chip (bend ranges, roots, modes): `selected` fills it and turns
  the text lime. Options: `min_width` (default 40), `height` (34), `font`
  (`:mono_semibold`), `dim` (faint text when unselected).
  """
  def chip(label, selected, tap, opts \\ []) do
    bg = if selected, do: Style.selected(), else: Style.bg()

    color =
      cond do
        selected -> Style.fm()
        Keyword.get(opts, :dim, false) -> Style.faint()
        true -> Style.text_2()
      end

    ~MOB"""
    <Box
      fill_width={false}
      height={Keyword.get(opts, :height, 34)}
      corner_radius={9}
      background={bg}
      padding_left={12}
      padding_right={12}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text
        text={label}
        font={Keyword.get(opts, :font, :mono_semibold)}
        text_size={12}
        text_color={color}
      />
    </Box>
    """
  end

  @doc "A rounded button: `style` `:lime` (primary) or `:flat` (surface)."
  def button(label, tap, style \\ :flat, opts \\ []) do
    {bg, color} =
      case style do
        :lime -> {Style.fm(), Style.ink()}
        :flat -> {Style.surface(), Style.text()}
      end

    ~MOB"""
    <Box
      fill_width={Keyword.get(opts, :fill_width, false)}
      height={Keyword.get(opts, :height, 44)}
      corner_radius={Keyword.get(opts, :radius, 22)}
      background={bg}
      padding_left={18}
      padding_right={18}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={label} font={:bold} text_size={14} text_color={color} />
    </Box>
    """
  end

  @doc "Mimi `size` dp wide, centred on a `w` × `h` canvas."
  def mimi(w, h, size, state) do
    ops = Mimi.ops(w / 2, h / 2, size, state)
    ~MOB(<Canvas width={w} height={h} draw={ops} />)
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
end
