defmodule Humdinger.FirstRunScreen do
  @moduledoc """
  First run (board `05-first_run`): four steps, Mic · Headphones · Range ·
  Send to, with Skip on every one.

  * **Mic**: why Humdinger needs the microphone; "Allow the microphone"
    asks (`Mob.Permissions`), then starts the Engine listening. Refused:
    "Open settings" and "Try again".
  * **Headphones**: Mimi in headphones, and why (the synth feeds back
    into the microphone through a speaker).
  * **Range**: hold the lowest comfortable note for 2 s, then the highest
    (`Humdinger.RangeFinder` on the sung pitch, before octave and
    transpose). The range is saved as soon as both are in, with the octave
    `RangeFinder.octave_for/1` gives it. "Sing it again" starts over.
  * **Send to**: the destinations from Output with their switches
    (`set_enabled/2`), and a link to the Output screen.

  Finishing or Skip saves `first_run_done: true` and pops back to Live.
  Live opens it with `%{return_to: pid}` and gets `{:first_run, :done}`
  when it closes however it closes (also the back gesture), so Live then
  asks for the microphone itself. Settings' "find again" opens just the
  Range step (`%{step: :range, only: true}`): there Skip reads "Close" and
  nothing else changes.

  Frames arm a token-guarded 33 ms tick, and every tap target carries
  `on_press_out={held()}`. It watches the Engine (`Engine.watch/0`) and
  watches the new one after a restart (Live, underneath, sets it
  listening again).
  """

  use Mob.Screen

  alias Humdinger.{Audio, Engine, Music, RangeFinder, Style, Widgets}
  alias Humdinger.Views.RangeBar

  @steps [:mic, :headphones, :range, :send_to]
  @frame_ms 33
  @mimi {170, 150}
  @bar_w 342
  @output_screen Humdinger.OutputScreen
  @rewatch_ms 100

  @impl true
  def mount(params, _session, socket) do
    {:ok, engine_mon} = Engine.watch()
    destinations = subscribe_output()
    step = Map.get(params, :step, :mic)
    settings = Engine.settings()

    socket =
      Mob.Socket.assign(socket,
        return_to: Map.get(params, :return_to),
        only: Map.get(params, :only, false),
        step: step,
        mic: :unknown,
        audio_missing: false,
        status: Engine.status(),
        finder:
          if(step == :range, do: RangeFinder.new(), else: RangeFinder.from_range(settings.range)),
        frame: nil,
        shown: nil,
        tick_token: nil,
        engine_mon: engine_mon,
        destinations: destinations,
        saved_range: nil
      )
      |> enter(step)

    {:ok, socket}
  end

  defp subscribe_output do
    output = output()
    output.subscribe(self())
    output.destinations()
  catch
    :exit, _ -> []
  end

  defp output, do: Application.get_env(:humdinger, :output, Humdinger.Output)

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    skip = {self(), :skip}
    skip_label = if assigns.only, do: "Close", else: "Skip"

    ~MOB"""
    <Row background={Style.bg()} fill_width={true} fill_height={true} align={:top}>
      <Spacer />
      <Column width={342} fill_height={true} padding_top={20} padding_bottom={24} gap={20}>
        <Row gap={10}>
          <Row weight={1} gap={6}>
            {for step <- steps(), do: step_mark(step, assigns.step)}
          </Row>
          <Box
            fill_width={false}
            height={40}
            padding_left={12}
            padding_right={12}
            align="center"
            on_tap={skip}
            on_press_out={Widgets.held()}
          >
            <Text text={skip_label} font={:semibold} text_size={13} text_color={Style.muted()} />
          </Box>
        </Row>
        {body(assigns)}
      </Column>
      <Spacer />
    </Row>
    """
  end

  defp steps, do: @steps

  defp step_mark(step, current) do
    index = Enum.find_index(@steps, &(&1 == step))
    now = Enum.find_index(@steps, &(&1 == current))

    {bar, fg} =
      cond do
        index < now -> {Style.fm(), Style.text()}
        index == now -> {Style.text(), Style.text()}
        true -> {Style.selected(), Style.faint()}
      end

    ~MOB"""
    <Column weight={1} gap={6}>
      <Box height={4} corner_radius={2} background={bar} />
      <Text text={step_label(step)} font={:semibold} text_size={11} text_color={fg} max_lines={1} />
    </Column>
    """
  end

  defp step_label(:mic), do: "Mic"
  defp step_label(:headphones), do: "Headphones"
  defp step_label(:range), do: "Range"
  defp step_label(:send_to), do: "Send to"

  defp body(%{step: :mic} = a) do
    denied = a.mic == :denied
    mood = if denied, do: :no_mic, else: :listening

    {title, text, actions} =
      if denied do
        {"Mimi can't hear you",
         "The microphone is off for Humdinger. Turn it on in Settings, then try again.",
         [{"Open settings", :app_settings, :flat}, {"Try again", :allow_mic, :lime}]}
      else
        {"Let Mimi hear you",
         "Humdinger turns your humming into MIDI notes as you sing. It needs the microphone; nothing is recorded unless you press record.",
         [{"Allow the microphone", :allow_mic, :lime}]}
      end

    intro(mood, nil, {0, -0.4}, title, text, actions)
  end

  defp body(%{step: :headphones}) do
    intro(
      :headphones,
      nil,
      {0, 0},
      "Headphones help",
      "Humdinger makes no sound, but your synth does. From a speaker it sings straight back into the microphone and Mimi starts chasing it. With headphones she hears only you.",
      [{"Got it", :next, :lime}]
    )
  end

  defp body(%{step: :range} = a), do: range_body(a)

  defp body(%{step: :send_to} = a) do
    more = {self(), :output}
    finish = {self(), :finish}

    ~MOB"""
    <Column gap={14}>
      <Text
        text="Where should the notes go?"
        font={:display}
        text_size={30}
        text_color={Style.text()}
      />
      <Text
        text="Pick any. You can change this later from the pill at the top of Live."
        text_size={14}
        line_height={1.45}
        text_color={Style.text_2()}
      />
      {for d <- a.destinations, do: destination_row(d)}
      <Row gap={10}>
        {Widgets.button("More in Output ›", more, :flat)}
        <Spacer />
        {Widgets.button("Start humming", finish, :lime)}
      </Row>
    </Column>
    """
  end

  defp destination_row(d) do
    tap = {self(), {:destination, d.id, not d.enabled}}

    ~MOB"""
    <Row background={Style.surface()} corner_radius={14} padding={12} gap={12}>
      <Column weight={1}>
        <Text text={d.name} font={:semibold} text_size={14} text_color={Style.text()} />
        <Text text={d.detail} text_size={12} text_color={Style.muted()} />
      </Column>
      {Widgets.switch(d.enabled, tap)}
    </Row>
    """
  end

  defp intro(mood, note, look, title, text, actions) do
    {w, h} = @mimi

    ~MOB"""
    <Column gap={10} padding_top={20}>
      {Widgets.centered(Widgets.mimi(w, h, 166, %{mood: mood, note: note, look: look}))}
      <Text
        text={title}
        font={:display}
        text_size={30}
        text_align="center"
        fill_width={true}
        text_color={Style.text()}
      />
      <Text
        text={text}
        text_size={14}
        line_height={1.45}
        text_align="center"
        fill_width={true}
        text_color={Style.text_2()}
      />
      <Spacer size={10} />
      <Row fill_width={true} gap={10}>
        <Spacer />
        {for {label, tag, style} <- actions do
          Widgets.button(label, {self(), tag}, style)
        end}
        <Spacer />
      </Row>
    </Column>
    """
  end

  defp range_body(a) do
    shown = a.shown || %{finder: a.finder, frame: nil}
    finder = shown.finder
    frame = shown.frame
    {w, h} = @mimi
    bar_w = @bar_w
    sung = sung_pitch(frame)
    holding = RangeFinder.holding(finder)
    {title, text} = range_copy(a, finder)
    big = big_note(finder, holding)

    big_color =
      if big_note_midi(finder, holding),
        do: Style.pitch_color(big_note_midi(finder, holding)),
        else: Style.faint()

    held = RangeFinder.held_ms(finder)
    progress = held / RangeFinder.hold_ms()
    look = if finder.phase == :high, do: {0, -0.8}, else: {0, 0.8}
    mood = range_mood(a, frame)

    ~MOB"""
    <Column gap={20} weight={1}>
      <Column gap={10} padding_top={20}>
        {Widgets.centered(Widgets.mimi(w, h, 166, %{mood: mood, note: holding || 69, look: look}))}
        <Text
          text={title}
          font={:display}
          text_size={30}
          text_align="center"
          fill_width={true}
          text_color={Style.text()}
        />
        <Text
          text={text}
          text_size={14}
          line_height={1.45}
          text_align="center"
          fill_width={true}
          text_color={Style.text_2()}
        />
      </Column>
      <Column gap={6}>
        <Text
          text={big}
          font={:display}
          text_size={64}
          line_height={1.0}
          text_align="center"
          fill_width={true}
          text_color={big_color}
        />
        {if finder.phase != :done do
          Widgets.centered(progress_bar(progress))
        else
          []
        end}
        <Text
          :if={finder.phase != :done}
          text={holding_caption(a, finder, held)}
          font={:mono_semibold}
          text_size={11}
          text_align="center"
          fill_width={true}
          text_color={Style.muted()}
        />
      </Column>
      <Canvas
        width={bar_w}
        height={RangeBar.height()}
        draw={RangeBar.ops(bar_data(finder, holding, sung), bar_w, RangeBar.height())}
      />
      <Row gap={10}>
        {range_card("LOWEST", finder.low || (finder.phase == :low && holding), finder.phase == :low)}
        {range_card("HIGHEST", finder.high || (finder.phase == :high && holding), finder.phase == :high)}
      </Row>
      {range_actions(a, finder)}
      <Spacer />
      <Text
        text="Your range sets the starting octave and the part of the piano the strip shows. Change it any time in Settings."
        text_size={12}
        line_height={1.45}
        text_align="center"
        fill_width={true}
        text_color={Style.muted()}
      />
    </Column>
    """
  end

  defp progress_bar(progress) do
    ~MOB"""
    <Box width={200} height={6} corner_radius={3} background={Style.line_soft()}>
      <Box width={max(progress * 200, 0.1)} height={6} background={Style.fm()} />
    </Box>
    """
  end

  defp range_actions(a, %{phase: :done}) do
    again = {self(), :range_again}
    next = {self(), if(a.only, do: :finish, else: :next)}
    label = if a.only, do: "Done", else: "Next"

    ~MOB"""
    <Row gap={10}>
      {Widgets.button("Sing it again", again, :flat)}
      <Spacer />
      {Widgets.button(label, next, :lime)}
    </Row>
    """
  end

  defp range_actions(_a, _finder), do: []

  # While a bound is being held, the bar dims as if it were chosen (the board).
  defp bar_data(%{phase: :low} = finder, holding, sung),
    do: %{pitch: sung, low: holding, high: finder.high}

  defp bar_data(%{phase: :high} = finder, holding, sung),
    do: %{pitch: sung, low: finder.low, high: holding && max(holding, finder.low)}

  defp bar_data(finder, _holding, sung), do: %{pitch: sung, low: finder.low, high: finder.high}

  defp range_card(label, note, active) do
    border = if active, do: Style.fm(), else: Style.surface()
    value = if note, do: Music.note_name(note), else: if(active, do: "–", else: "next")
    value_color = if note || active, do: Style.text(), else: Style.faint()

    ~MOB"""
    <Box
      weight={1}
      corner_radius={14}
      background={Style.surface()}
      border_color={border}
      border_width={1}
      padding={12}
    >
      <Column gap={6}>
        <Text text={label} font={:mono_semibold} text_size={10} text_color={Style.muted()} />
        <Row gap={6} align={:bottom}>
          <Text text={value} font={:bold} text_size={20} text_color={value_color} />
          <Text :if={active} text="listening" font={:medium} text_size={12} text_color={Style.fm()} />
        </Row>
      </Column>
    </Box>
    """
  end

  @doc false
  # The title and line under Mimi for the range step.
  def range_copy(a, finder) do
    cond do
      a.audio_missing ->
        {"No audio engine", "This build of Humdinger can't use the microphone yet."}

      a.mic == :denied or match?({:error, _}, a.status) ->
        {"Mimi can't hear you", "Allow the microphone on the first step, then come back here."}

      finder.phase == :low ->
        {"Sing your lowest comfortable note",
         "Hum it and hold for two seconds. Don’t strain: this is where you can sing all day."}

      finder.phase == :high and finder.refused ->
        {"Now your highest comfortable note",
         "That one was no higher than #{Music.note_name(finder.low)}. Go up, then hold it for two seconds."}

      finder.phase == :high ->
        {"Now your highest comfortable note",
         "Go up as far as feels easy and hold it for two seconds. No squeaking."}

      true ->
        {"That’s your range",
         "Humdinger starts at octave #{signed(RangeFinder.octave_for(RangeFinder.range(finder)))} so your notes land where a synth sings."}
    end
  end

  defp big_note(%{phase: :done} = finder, _holding),
    do: RangeFinder.label(RangeFinder.range(finder))

  defp big_note(_finder, nil), do: "–"
  defp big_note(_finder, holding), do: Music.note_name(holding)

  defp big_note_midi(%{phase: :done, low: low}, _holding), do: low
  defp big_note_midi(_finder, holding), do: holding

  defp holding_caption(a, finder, held) do
    cond do
      a.audio_missing or a.mic == :denied or match?({:error, _}, a.status) -> ""
      a.status == :paused -> "paused"
      held > 0 -> "holding… #{:erlang.float_to_binary(held / 1000, decimals: 1)} s"
      finder.phase == :high -> "lowest #{Music.note_name(finder.low)} · now go up"
      true -> "listening"
    end
  end

  defp range_mood(a, frame) do
    cond do
      a.audio_missing or a.mic == :denied or match?({:error, _}, a.status) -> :no_mic
      frame && frame.voiced -> :singing
      true -> :listening
    end
  end

  defp sung_pitch(%{hz: hz}) when is_number(hz), do: Music.hz_to_midi(hz)
  defp sung_pitch(_frame), do: nil

  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n) when n < 0, do: "−#{-n}"
  defp signed(_n), do: "0"

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:engine, :frame, frame}, socket) do
    a = socket.assigns

    finder =
      if a.step == :range and frame.t,
        do: RangeFinder.push(a.finder, frame.t, sung_pitch(frame)),
        else: a.finder

    socket = Mob.Socket.assign(socket, frame: frame, finder: finder)
    {:noreply, socket |> save_range() |> schedule_tick()}
  end

  def handle_info({:engine, :status, status}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :status, status)}

  def handle_info({:engine, _kind, _payload}, socket), do: {:noreply, socket}

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{assigns: %{engine_mon: mon}} = socket) do
    send(self(), :engine_rewatch)
    {:noreply, Mob.Socket.assign(socket, :engine_mon, nil)}
  end

  def handle_info(:engine_rewatch, %{assigns: %{engine_mon: nil}} = socket) do
    case Engine.watch() do
      {:ok, mon} ->
        {:noreply, Mob.Socket.assign(socket, engine_mon: mon, status: Engine.status())}

      {:error, :down} ->
        Process.send_after(self(), :engine_rewatch, @rewatch_ms)
        {:noreply, socket}
    end
  end

  def handle_info(:engine_rewatch, socket), do: {:noreply, socket}

  def handle_info({:tick, token}, %{assigns: %{tick_token: token}} = socket) do
    a = socket.assigns

    {:noreply,
     Mob.Socket.assign(socket, tick_token: nil, shown: %{finder: a.finder, frame: a.frame})}
  end

  def handle_info({:tick, _stale}, socket), do: {:noreply, socket}

  def handle_info({:output, :destinations, list}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :destinations, list)}

  def handle_info({:output, _kind, _payload}, socket), do: {:noreply, socket}

  def handle_info({:tap, :allow_mic}, socket) do
    if device_calls?(),
      do: {:noreply, Mob.Permissions.request(socket, :microphone)},
      else: handle_info({:permission, :microphone, :granted}, socket)
  end

  def handle_info({:permission, :microphone, :granted}, socket) do
    socket = socket |> Mob.Socket.assign(:mic, :granted) |> listen()
    {:noreply, if(socket.assigns.step == :mic, do: enter(socket, :headphones), else: socket)}
  end

  def handle_info({:permission, :microphone, :denied}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :mic, :denied)}

  def handle_info({:permission, _capability, _result}, socket), do: {:noreply, socket}

  def handle_info({:tap, :app_settings}, socket) do
    if device_calls?(), do: Mob.Device.open_settings(:app)
    {:noreply, socket}
  end

  def handle_info({:tap, :next}, socket),
    do: {:noreply, enter(socket, next_step(socket.assigns.step))}

  def handle_info({:tap, :range_again}, socket) do
    socket = Mob.Socket.assign(socket, finder: RangeFinder.new(), saved_range: nil)
    {:noreply, Mob.Socket.assign(socket, :shown, %{finder: socket.assigns.finder, frame: nil})}
  end

  def handle_info({:tap, {:destination, id, enabled}}, socket) do
    output().set_enabled(id, enabled)
    {:noreply, socket}
  catch
    :exit, _ -> {:noreply, socket}
  end

  def handle_info({:tap, :output}, socket) do
    if Code.ensure_loaded?(@output_screen),
      do: {:noreply, Mob.Socket.push_screen(socket, @output_screen, %{})},
      else: {:noreply, socket}
  end

  def handle_info({:tap, :finish}, socket), do: {:noreply, finish(socket)}

  def handle_info({:tap, :skip}, socket), do: {:noreply, finish(socket)}

  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:return_to], do: send(pid, {:first_run, :done})
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp next_step(step) do
    index = Enum.find_index(@steps, &(&1 == step))
    Enum.at(@steps, index + 1, step)
  end

  defp enter(socket, :range) do
    finder =
      if socket.assigns.finder.phase == :done and socket.assigns.saved_range == nil,
        do: RangeFinder.new(),
        else: socket.assigns.finder

    socket
    |> Mob.Socket.assign(step: :range, finder: finder, shown: %{finder: finder, frame: nil})
    |> listen()
  end

  defp enter(socket, step), do: Mob.Socket.assign(socket, :step, step)

  # The range step needs the engine listening (Live hasn't asked yet on a
  # first launch). Nothing to do without the microphone.
  defp listen(socket) do
    cond do
      not Code.ensure_loaded?(Audio.impl()) ->
        Mob.Socket.assign(socket, :audio_missing, true)

      socket.assigns.mic == :granted or Engine.status() in [:listening, :paused] or
          not device_calls?() ->
        if Engine.status() != :listening, do: Engine.listen()
        Mob.Socket.assign(socket, :status, Engine.status())

      true ->
        socket
    end
  end

  # Saves the range once both notes are in, with the octave that suits it.
  defp save_range(socket) do
    a = socket.assigns

    case RangeFinder.range(a.finder) do
      nil ->
        socket

      range when range == a.saved_range ->
        socket

      range ->
        Engine.update_settings(%{range: range, octave: RangeFinder.octave_for(range)})
        Mob.Socket.assign(socket, :saved_range, range)
    end
  end

  defp finish(%{assigns: %{only: true}} = socket), do: Mob.Socket.pop_screen(socket)

  defp finish(socket) do
    Engine.update_settings(%{first_run_done: true})
    Mob.Socket.pop_screen(socket)
  end

  defp schedule_tick(%{assigns: %{tick_token: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:tick, token}, @frame_ms)
    Mob.Socket.assign(socket, :tick_token, token)
  end

  defp schedule_tick(socket), do: socket

  defp device_calls?, do: Application.get_env(:humdinger, :device_calls, true)
end
