defmodule Humdinger.SettingsSheet do
  @moduledoc """
  The Settings sheet over Live (board `03-settings`): Live renders it with
  `sheet/1` while it is open and keeps listening underneath, so the header
  shows the note being sung.

  Every control sends `{:tap, {:set, field, value}}` to the Live screen,
  which passes the change to `Humdinger.Engine.update_settings/1`. The
  Sensitivity bar is a canvas dragged with `on_drag` (`{:drag,
  :sensitivity, payload}`): `db_at/2` turns the finger's x into a gate
  level within `Humdinger.Settings.sensitivity_range/0`. `bar_ops/3` draws
  it: the room's level (measured while nothing is sung), the singer's level
  (while singing) and the gate line between them.
  """

  import Mob.Canvas, except: [text: 4]
  import Mob.Sigil

  alias Humdinger.{Music, RangeFinder, Settings, Style, Tracker, Widgets}
  alias Humdinger.Views.Draw

  @bar_w 350
  @bar_h 28

  @doc "The Sensitivity bar's size."
  def bar_size, do: {@bar_w, @bar_h}

  @doc "The gate level (dBFS, whole dB) at x on a bar `w` wide."
  @spec db_at(number(), number()) :: float()
  def db_at(x, w) do
    {lo, hi} = Settings.sensitivity_range()
    (lo + Draw.clamp(x / w, 0, 1) * (hi - lo)) |> Float.round() |> Kernel.*(1.0)
  end

  @doc "The x of a level (dBFS) on a bar `w` wide, clamped to the bar."
  @spec x_of(number(), number()) :: float()
  def x_of(db, w) do
    {lo, hi} = Settings.sensitivity_range()
    Draw.r1(Draw.clamp((db - lo) / (hi - lo), 0, 1) * w)
  end

  @doc """
  The bar: `%{gate, room, voice, note}` (dBFS; room and voice nil until
  heard; the voice band in the sung note's colour).
  """
  @spec bar_ops(map(), number(), number()) :: [map()]
  def bar_ops(data, w, h) do
    gate_x = x_of(data.gate, w)
    label = [size: 10, weight: :semibold, family: Style.font_family(:mono_semibold)]

    List.flatten([
      rect(0, 0, w, h, color: Style.bg(), fill: true, radius: 8),
      level(data.room, w, h, Style.selected(), 1.0),
      level(data.voice, w, h, Style.pitch_color(data.note || 69), 0.45),
      rect(Draw.r1(gate_x - 2), 0, 4, h, color: Style.text(), fill: true),
      Mob.Canvas.text(8, 8, "room", [color: Style.text_2()] ++ label),
      Mob.Canvas.text(
        Draw.r1(min(gate_x + 10, w - 64)),
        8,
        "your voice",
        [color: if(data.voice, do: Style.ink(), else: Style.muted())] ++ label
      )
    ])
  end

  # A fill from the left edge to the level, rounded on the left only.
  defp level(nil, _w, _h, _color, _opacity), do: []

  defp level(db, w, h, color, opacity) do
    x = x_of(db, w)

    if x < 1 do
      []
    else
      [
        rect(0, 0, x, h, color: color, fill: true, radius: 8, opacity: opacity),
        rect(Draw.r1(max(x - 8, 0)), 0, Draw.r1(min(8, x)), h,
          color: color,
          fill: true,
          opacity: opacity
        )
      ]
    end
  end

  @doc "The settings icon on Live's header (board: 20 × 20 sliders)."
  def icon_ops do
    s = 20 / 24
    stroke = [color: Style.text(), width: 2, cap: :round]
    l = fn x1, y1, x2, y2 -> line(x1 * s, y1 * s, x2 * s, y2 * s, stroke) end

    [
      l.(4, 7, 14, 7),
      l.(18, 7, 20, 7),
      l.(4, 17, 8, 17),
      l.(12, 17, 20, 17),
      circle(16 * s, 7 * s, 2 * s, color: Style.text(), width: 2),
      circle(10 * s, 17 * s, 2 * s, color: Style.text(), width: 2)
    ]
  end

  @doc """
  The sheet's content. `a` holds `settings`, `note` (the sung note or nil),
  `mimi_ops` (the header's Mimi, 44 × 40) and `bar_ops`.
  """
  def sheet(a) do
    s = a.settings
    set = fn field, value -> {self(), {:set, field, value}} end
    done = {self(), :settings_done}
    find_range = {self(), :find_range}
    dismiss = {self(), :settings_sheet}
    drag = {self(), :sensitivity}
    {bar_w, bar_h} = bar_size()
    note_name = if a.note, do: Music.note_name(a.note), else: "–"
    note_color = if a.note, do: Style.pitch_color(a.note), else: Style.faint()
    range = if s.range, do: RangeFinder.label(s.range) <> " · find again ›", else: "find it ›"
    bend_dim = s.mode != :open

    responses =
      for r <- [:fast, :balanced, :steady] do
        %{
          label: response_label(r),
          sub: "~#{Tracker.response_ms(r)} ms",
          tap: set.(:response, r),
          selected: s.response == r
        }
      end

    pitch_change = [
      %{label: "Legato", tap: set.(:pitch_change, :legato), selected: s.pitch_change == :legato},
      %{
        label: "New note",
        tap: set.(:pitch_change, :new_note),
        selected: s.pitch_change == :new_note
      }
    ]

    on_stop = [
      %{label: "Note off", tap: set.(:on_stop, :note_off), selected: s.on_stop == :note_off},
      %{
        label: "Hold #{Tracker.hold_ms()} ms",
        tap: set.(:on_stop, :hold),
        selected: s.on_stop == :hold
      }
    ]

    toggles = [
      {"Loudness → velocity", "how hard each note starts", :velocity_from_loudness},
      {"Loudness → CC 11", "swells while you hold a note", :cc11_from_loudness},
      {"Vibrato → CC 1", "mod wheel follows your vibrato", :cc1_from_vibrato}
    ]

    ~MOB"""
    <Sheet
      id="settings"
      detents={[:large]}
      on_dismiss={dismiss}
      background={Style.surface()}
      corner_radius={24}
    >
      <Scroll fill_width={true}>
        <Row fill_width={true} align={:top}>
          <Spacer />
          <Column width={350} padding_top={4} padding_bottom={24} gap={16}>
            <Row gap={12} height={44}>
              <Canvas width={44} height={40} draw={a.mimi_ops} />
              <Text text={note_name} font={:display} text_size={36} text_color={note_color} />
              <Text
                text="still listening while you adjust"
                text_size={12}
                text_color={Style.text_2()}
              />
            </Row>
            <Row>
              <Text text="Settings" font={:display} text_size={24} text_color={Style.text()} />
              <Spacer />
              {Widgets.button("Done", done, :lime, height: 40, radius: 20)}
            </Row>
            <Column gap={10}>
              {Widgets.heading("LISTENING")}
              <Row>
                <Text text="Sensitivity" font={:semibold} text_size={14} text_color={Style.text()} />
                <Spacer />
                <Text
                  text="drag the line above the room noise"
                  text_size={12}
                  text_color={Style.muted()}
                />
              </Row>
              <Canvas width={bar_w} height={bar_h} draw={a.bar_ops} on_drag={drag} />
              <Row>
                <Text text="Response" font={:semibold} text_size={14} text_color={Style.text()} />
                <Spacer />
                {Widgets.segmented(responses,
                  width: 230,
                  height: 42,
                  track: Style.bg(),
                  text_size: 12
                )}
              </Row>
              <Text
                text="Fast reacts sooner but wobbles on vibrato; Steady waits a little to be sure."
                text_size={12}
                line_height={1.4}
                text_color={Style.muted()}
              />
            </Column>
            <Column gap={10}>
              {Widgets.heading("NOTES")}
              <Row>
                <Text text="Pitch change" font={:semibold} text_size={14} text_color={Style.text()} />
                <Spacer />
                {Widgets.segmented(pitch_change,
                  width: 200,
                  height: 34,
                  track: Style.bg(),
                  text_size: 12
                )}
              </Row>
              <Row>
                <Text
                  text="When you stop"
                  font={:semibold}
                  text_size={14}
                  text_color={Style.text()}
                />
                <Spacer />
                {Widgets.segmented(on_stop, width: 200, height: 34, track: Style.bg(), text_size: 12)}
              </Row>
              <Row>
                <Text text="Bend range" font={:semibold} text_size={14} text_color={Style.text()} />
                <Text text=" (open mode)" text_size={14} text_color={Style.muted()} />
                <Spacer />
                <Row gap={4}>
                  {for n <- Settings.bend_ranges() do
                    Widgets.chip("±#{n}", s.bend_range == n, set.(:bend_range, n), dim: bend_dim)
                  end}
                </Row>
              </Row>
              <Text
                text="Set the same bend range on the synth, or bends will land on the wrong note."
                text_size={12}
                line_height={1.4}
                text_color={Style.muted()}
              />
            </Column>
            <Column gap={4}>
              {Widgets.heading("EXPRESSION")}
              {for {name, sub, field} <- toggles do
                toggle_row(name, sub, Map.fetch!(s, field), set.(field, not Map.fetch!(s, field)))
              end}
            </Column>
            <Box
              height={52}
              corner_radius={14}
              background={Style.raised_hi()}
              padding_left={16}
              padding_right={16}
              on_tap={find_range}
              on_press_out={Widgets.held()}
            >
              <Row height={52}>
                <Text text="Your range" font={:semibold} text_size={14} text_color={Style.text()} />
                <Spacer />
                <Text text={range} font={:mono_semibold} text_size={12} text_color={Style.text_2()} />
              </Row>
            </Box>
          </Column>
          <Spacer />
        </Row>
      </Scroll>
    </Sheet>
    """
  end

  defp toggle_row(name, sub, on?, tap) do
    ~MOB"""
    <Row gap={12} height={44}>
      <Column weight={1}>
        <Text text={name} font={:semibold} text_size={14} text_color={Style.text()} />
        <Text text={sub} text_size={12} text_color={Style.muted()} />
      </Column>
      {Widgets.switch(on?, tap)}
    </Row>
    """
  end

  defp response_label(:fast), do: "Fast"
  defp response_label(:balanced), do: "Balanced"
  defp response_label(:steady), do: "Steady"
end
