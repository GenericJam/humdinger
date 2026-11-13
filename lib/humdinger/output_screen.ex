defmodule Humdinger.OutputScreen do
  @moduledoc """
  Output: where the MIDI goes ("Send MIDI to", board `04-output`).

  The four destination cards come from `Humdinger.Output` (`destinations/0`,
  then `{:output, :destinations, list}`): a card that is on has its switch lit
  and, when the destination can be reached, a lime outline; one that can't be
  reached is dimmed (it can still be switched on, and sends once it shows
  up). "Pair FMutate · QR or code" opens `Humdinger.PairScreen`; "Scan
  Bluetooth" opens a sheet listing what `Output.scan_bluetooth/0` finds
  (`{:output, :bluetooth, view}`), with Connect and Forget. A scan refused
  with `{:error, :no_permission}` asks for the `:midi_bluetooth` capability
  and scans again once it is granted.

  CHANNEL changes go through `Humdinger.Engine.update_settings/1`, so notes
  still sounding are released on the old channel first. WHAT GETS SENT
  reflects the Engine's settings; "Last sent" follows `{:output, :sent,
  summary}`; "Send test note" calls `Output.test_note/0`.

  The FMutate card follows the link's status (`{:fmutate, :status, status}`
  from the module in `config :humdinger, :fmutate`, default
  `Humdinger.FMutate`): "not paired · pair below" until a pairing exists,
  then a "Forget this FMutate" action behind a confirmation.

  The screen re-renders on every output event, so every tap target also
  declares `on_press_out={held()}` (MOB-509).
  """

  use Mob.Screen

  alias Humdinger.{Engine, Output, PairScreen, Style}

  @impl true
  def mount(_params, _session, socket) do
    :ok = Output.subscribe(self())
    :ok = fmutate().subscribe(self())

    {:ok,
     Mob.Socket.assign(socket,
       destinations: Output.destinations(),
       fmutate: :unpaired,
       settings: Engine.settings(),
       last_sent: Output.last_sent(),
       bluetooth: Output.bluetooth(),
       bt_sheet: false,
       bt_permission: :unknown,
       confirm: nil
     )}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    none_on = not Enum.any?(assigns.destinations, & &1.enabled)

    footer_color = if none_on, do: Style.warn(), else: Style.muted()
    footer_font = if none_on, do: :semibold, else: :default

    ~MOB"""
    <Column
      background={Style.bg()}
      fill_width={true}
      fill_height={true}
      padding_left={20}
      padding_right={20}
      padding_top={12}
      padding_bottom={22}
      gap={14}
    >
      {header("Send MIDI to")}
      <Scroll weight={1} show_indicator={false}>
        <Column fill_width={true} gap={14}>
          <Column fill_width={true} gap={8}>
            {Enum.map(@destinations, &card(&1, @fmutate))}
            <Row fill_width={true} gap={8}>
              {flat_button("Pair FMutate · QR or code", :pair, weight: 1)}
              {flat_button("Scan Bluetooth", :scan_bluetooth, weight: 1)}
            </Row>
          </Column>
          {channel_section(@settings.channel)}
          {sent_section(@settings, @last_sent)}
        </Column>
      </Scroll>
      <Text
        text="Humdinger makes no sound itself. Turn on at least one destination, or nothing will play."
        font={footer_font}
        text_size={12}
        text_color={footer_color}
      />
      {if @bt_sheet, do: bluetooth_sheet(assigns)}
    </Column>
    """
  end

  @doc "The back chevron and the title, as on the Output and Pair boards (tap: `:back`)."
  def header(title) do
    back = {self(), :back}

    ~MOB"""
    <Row fill_width={true} gap={8} align={:center}>
      <Canvas width={44} height={44} draw={back_ops()} on_tap={back} on_press_out={held()} />
      <Text text={title} font={:display} text_size={24} text_color={Style.text()} />
    </Row>
    """
  end

  @doc "The back chevron (board: 22 dp, stroke 2, in a 44 dp target)."
  def back_ops do
    [
      Mob.Canvas.path([{24.75, 15.6}, {19.4, 22}, {24.75, 28.4}],
        color: Style.text(),
        width: 2,
        cap: :round,
        join: :round
      )
    ]
  end

  defp card(dest, fmutate_status) do
    toggle = {self(), {:toggle, dest.id}}
    lit = dest.enabled and dest.available

    {name_color, detail_color, badge_color} =
      if dest.available,
        do: {Style.text(), Style.muted(), badge_color(dest.id)},
        else: {Style.text_2(), Style.faint(), Style.faint()}

    border = if lit, do: Style.fm(), else: Style.surface()
    forget = {self(), :forget_fmutate}
    paired = dest.id == :fmutate and fmutate_status != :unpaired

    ~MOB"""
    <Box
      id={dest.id}
      fill_width={true}
      background={Style.surface()}
      corner_radius={16}
      border_color={border}
      border_width={1}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
    >
      <Row fill_width={true} gap={12} align={:center}>
        <Box width={40} height={40} corner_radius={12} background={Style.raised_hi()} align="center">
          <Text text={badge(dest.id)} font={:mono_bold} text_size={11} text_color={badge_color} />
        </Box>
        <Column weight={1} gap={1}>
          <Text text={dest.name} font={:bold} text_size={15} text_color={name_color} />
          <Text
            text={detail(dest, fmutate_status)}
            font={:mono}
            text_size={11}
            text_color={detail_color}
          />
          <Box
            :if={paired}
            fill_width={false}
            padding_top={6}
            padding_bottom={2}
            on_tap={forget}
            on_press_out={held()}
          >
            <Text
              text="Forget this FMutate"
              font={:semibold}
              text_size={12}
              text_color={Style.danger_text()}
            />
          </Box>
        </Column>
        {switch(dest.enabled, toggle)}
      </Row>
    </Box>
    """
  end

  defp badge(:fmutate), do: "FM"
  defp badge(:port), do: "PORT"
  defp badge(:usb), do: "USB"
  defp badge(:bt), do: "BT"

  defp badge_color(:fmutate), do: Style.fm()
  defp badge_color(:port), do: Style.info()
  defp badge_color(_), do: Style.key_white()

  # Output words the unpaired FMutate row for the Live pill; here the
  # button that fixes it sits right below.
  defp detail(%{id: :fmutate}, :unpaired), do: "not paired · pair below"
  defp detail(dest, _), do: dest.detail

  # The board's 48 × 28 switch: lime with a dark knob when on.
  defp switch(on?, tap) do
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

  defp channel_section(selected) do
    rows = Enum.chunk_every(1..16, 8)

    ~MOB"""
    <Column
      fill_width={true}
      background={Style.surface()}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      gap={10}
    >
      {heading("CHANNEL")}
      <Column fill_width={true} gap={4}>
        <Row :for={row <- rows} fill_width={true} gap={4}>
          {Enum.map(row, &channel_cell(&1, &1 == selected))}
        </Row>
      </Column>
    </Column>
    """
  end

  defp channel_cell(n, selected) do
    {bg, fg} = if selected, do: {Style.fm(), Style.ink()}, else: {Style.bg(), Style.text_2()}
    tap = {self(), {:channel, n}}

    ~MOB"""
    <Box
      weight={1}
      height={36}
      corner_radius={8}
      background={bg}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={Integer.to_string(n)} font={:mono_semibold} text_size={12} text_color={fg} />
    </Box>
    """
  end

  defp sent_section(settings, last_sent) do
    ~MOB"""
    <Column
      fill_width={true}
      background={Style.surface()}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      gap={8}
    >
      {heading("WHAT GETS SENT")}
      <Wrap spacing={6} run_spacing={6} fill_width={true}>
        {Enum.map(chips(settings), fn {label, on} -> chip(label, on) end)}
      </Wrap>
      <Row fill_width={true} gap={10} align={:center} padding_top={4}>
        <Column weight={1}>
          <Text text="Last sent:" text_size={12} text_color={Style.muted()} />
          <Text
            text={last_sent || "nothing yet"}
            font={:mono}
            text_size={12}
            text_color={Style.key_white()}
          />
        </Column>
        {flat_button("Send test note", :test_note, height: 40, padding: 14)}
      </Row>
    </Column>
    """
  end

  @doc """
  WHAT GETS SENT for `settings`: `{label, on?}` per chip. An off chip is
  drawn outlined (the board's "pitch bend · open mode" in Scale mode); CC 1
  shows only while vibrato drives it.
  """
  def chips(settings) do
    [
      {"note on / off", true},
      {if(settings.velocity_from_loudness, do: "velocity", else: "velocity · fixed 100"),
       settings.velocity_from_loudness},
      {"CC 11 expression", settings.cc11_from_loudness},
      {"pitch bend · open mode", settings.mode == :open}
    ] ++ if(settings.cc1_from_vibrato, do: [{"CC 1 vibrato", true}], else: [])
  end

  defp chip(label, on) do
    {bg, border, color} =
      if on,
        do: {Style.raised_hi(), Style.raised_hi(), Style.text()},
        else: {Style.surface(), 0xFF4A4560, Style.muted()}

    ~MOB"""
    <Box
      fill_width={false}
      background={bg}
      border_color={border}
      border_width={1}
      corner_radius={8}
      padding_left={9}
      padding_right={9}
      padding_top={5}
      padding_bottom={5}
    >
      <Text text={label} font={:mono_semibold} text_size={11} text_color={color} />
    </Box>
    """
  end

  @doc "A section heading (mono 11, spaced capitals); the Pair screen's too."
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

  defp flat_button(label, tag, opts) do
    tap = {self(), tag}
    weight = Keyword.get(opts, :weight)
    pad = Keyword.get(opts, :padding, 4)

    ~MOB"""
    <Box
      weight={weight}
      fill_width={weight != nil}
      height={Keyword.get(opts, :height, 44)}
      corner_radius={12}
      background={Style.raised_hi()}
      padding_left={pad}
      padding_right={pad}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text
        text={label}
        font={:semibold}
        text_size={13}
        text_color={Style.text()}
        text_align="center"
        fill_width={false}
      />
    </Box>
    """
  end

  # ── Bluetooth sheet ────────────────────────────────────────────────────────

  defp bluetooth_sheet(assigns) do
    dismiss = {self(), :bt_sheet}
    bt = assigns.bluetooth
    found = Enum.reject(bt.found, &(bt.paired && &1.address == bt.paired.address))
    message = bt_message(bt, assigns.bt_permission)

    {scan_label, scan_tag} =
      if bt.scanning, do: {"Stop", :stop_scan}, else: {"Scan again", :scan_bluetooth}

    ~MOB"""
    <Sheet
      id="bluetooth"
      detents={[:medium, :large]}
      on_dismiss={dismiss}
      background={Style.surface()}
    >
      <Column fill_width={true} padding={20} gap={12}>
        <Text text="Bluetooth MIDI" font={:display} text_size={22} text_color={Style.text()} />
        <Row :if={bt.scanning} fill_width={true} gap={10} align={:center}>
          <Box width={8} height={8} corner_radius={4} background={Style.fm()} />
          <Text
            text="Looking for Bluetooth MIDI devices…"
            text_size={13}
            text_color={Style.text_2()}
          />
        </Row>
        <Text :if={message} text={message} text_size={13} text_color={Style.danger_text()} />
        {if bt.paired, do: bt_row(bt.paired, bt_paired_detail(@destinations), :forget, bt)}
        {Enum.map(found, &bt_row(&1, "#{&1.rssi} dBm", :connect, bt))}
        <Text
          :if={found == [] and not bt.scanning and bt.paired == nil and message == nil}
          text="Nothing found yet. Switch the synth's Bluetooth MIDI on and scan."
          text_size={13}
          text_color={Style.muted()}
        />
        <Row fill_width={true} gap={8}>
          {flat_button(scan_label, scan_tag, weight: 1)}
          {flat_button("Done", :bt_sheet, weight: 1)}
        </Row>
      </Column>
    </Sheet>
    """
  end

  defp bt_row(device, detail, action, bt) do
    {label, tag, color} =
      case action do
        :forget ->
          {"Forget", :forget_bluetooth, Style.danger_text()}

        :connect when bt.connecting == device.address ->
          {"Connecting…", nil, Style.muted()}

        :connect ->
          {"Connect", {:connect_bluetooth, device.address}, Style.fm()}
      end

    tap = if tag, do: {self(), tag}
    name = if device.name in [nil, ""], do: device.address, else: device.name

    ~MOB"""
    <Box
      id={device.address}
      fill_width={true}
      background={Style.raised()}
      corner_radius={14}
      padding_left={12}
      padding_right={12}
      padding_top={10}
      padding_bottom={10}
    >
      <Row fill_width={true} gap={12} align={:center}>
        <Column weight={1}>
          <Text text={name} font={:bold} text_size={14} text_color={Style.text()} />
          <Text text={detail} font={:mono} text_size={11} text_color={Style.muted()} />
        </Column>
        <Box
          fill_width={false}
          height={36}
          corner_radius={10}
          background={Style.raised_hi()}
          padding_left={12}
          padding_right={12}
          align="center"
          on_tap={tap}
          on_press_out={if(tap, do: held())}
        >
          <Text text={label} font={:semibold} text_size={13} text_color={color} />
        </Box>
      </Row>
    </Box>
    """
  end

  defp bt_paired_detail(destinations) do
    case Enum.find(destinations, &(&1.id == :bt)) do
      %{available: true} -> "connected"
      %{detail: "connecting…"} -> "connecting…"
      _ -> "not connected"
    end
  end

  @doc "The plain-words line for a Bluetooth scan or connection problem, or nil."
  def bt_message(_bt, :asking),
    do: "Allow Nearby devices so Humdinger can look for Bluetooth MIDI."

  def bt_message(_bt, :denied),
    do:
      "Bluetooth permission is off. Allow Nearby devices for Humdinger in Settings, then scan again."

  def bt_message(%{error: nil}, _), do: nil

  def bt_message(%{error: :no_permission}, _),
    do: "Humdinger needs the Nearby devices permission to scan."

  def bt_message(%{error: :bluetooth_off}, _),
    do: "Bluetooth is off. Turn it on, then scan again."

  def bt_message(%{error: :location_off}, _),
    do: "Location is off. Android needs it on to find Bluetooth devices."

  def bt_message(%{error: :no_bluetooth}, _), do: "This phone has no Bluetooth LE."
  def bt_message(%{error: :unavailable}, _), do: "Bluetooth MIDI isn't available on this phone."
  def bt_message(%{error: :scan_failed}, _), do: "The scan didn't start. Try again."

  def bt_message(%{error: reason}, _) when reason in [:open_failed, :connect_failed],
    do: "Couldn't connect. Check the device is on and close by, then try again."

  def bt_message(%{error: _}, _), do: "Something went wrong with Bluetooth. Try again."

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, {:toggle, id}}, socket) do
    dest = Enum.find(socket.assigns.destinations, &(&1.id == id))
    :ok = Output.set_enabled(id, not dest.enabled)
    {:noreply, Mob.Socket.assign(socket, :destinations, Output.destinations())}
  end

  def handle_info({:tap, {:channel, n}}, socket) do
    case Engine.update_settings(%{channel: n}) do
      {:ok, settings} -> {:noreply, Mob.Socket.assign(socket, :settings, settings)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:tap, :test_note}, socket) do
    :ok = Output.test_note()
    {:noreply, socket}
  end

  def handle_info({:tap, :pair}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, PairScreen, %{})}

  def handle_info({:tap, :forget_fmutate}, socket) do
    name = fmutate_name(socket.assigns.destinations)

    if device_calls?() do
      Mob.Alert.alert(socket,
        title: "Forget #{name}?",
        message: "Humdinger stops sending to it. To use it again, pair with its code.",
        buttons: [
          [label: "Forget", style: :destructive, action: :forget_fmutate],
          [label: "Cancel", style: :cancel]
        ]
      )
    end

    {:noreply, Mob.Socket.assign(socket, :confirm, :forget_fmutate)}
  end

  def handle_info({:alert, :forget_fmutate}, socket) do
    _ = fmutate().forget()
    {:noreply, Mob.Socket.assign(socket, :confirm, nil)}
  end

  def handle_info({:alert, _}, socket), do: {:noreply, Mob.Socket.assign(socket, :confirm, nil)}

  def handle_info({:tap, :scan_bluetooth}, socket) do
    {:noreply, socket |> Mob.Socket.assign(bt_sheet: true, bt_permission: :unknown) |> scan()}
  end

  def handle_info({:tap, :stop_scan}, socket) do
    :ok = Output.stop_bluetooth_scan()
    {:noreply, socket}
  end

  def handle_info({tag, :bt_sheet}, socket) when tag in [:tap, :dismiss] do
    if socket.assigns.bluetooth.scanning, do: Output.stop_bluetooth_scan()
    {:noreply, Mob.Socket.assign(socket, :bt_sheet, false)}
  end

  def handle_info({:tap, {:connect_bluetooth, address}}, socket) do
    _ = Output.connect_bluetooth(address)
    {:noreply, Mob.Socket.assign(socket, :bluetooth, Output.bluetooth())}
  end

  def handle_info({:tap, :forget_bluetooth}, socket) do
    :ok = Output.forget_bluetooth()
    {:noreply, Mob.Socket.assign(socket, :bluetooth, Output.bluetooth())}
  end

  def handle_info({:permission, :midi_bluetooth, :granted}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:bt_permission, :granted) |> scan()}

  def handle_info({:permission, :midi_bluetooth, _denied}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :bt_permission, :denied)}

  def handle_info({:output, :destinations, list}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :destinations, list)}

  def handle_info({:output, :sent, summary}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :last_sent, summary)}

  def handle_info({:output, :bluetooth, view}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :bluetooth, view)}

  def handle_info({:fmutate, :status, status}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :fmutate, status)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # A scan the permission refused asks for it; the grant scans again.
  defp scan(socket) do
    case Output.scan_bluetooth() do
      {:error, :no_permission} when socket.assigns.bt_permission == :unknown ->
        if device_calls?(), do: Mob.Permissions.request(socket, :midi_bluetooth)
        Mob.Socket.assign(socket, bt_permission: :asking, bluetooth: Output.bluetooth())

      {:error, :no_permission} ->
        Mob.Socket.assign(socket, bt_permission: :denied, bluetooth: Output.bluetooth())

      _ ->
        Mob.Socket.assign(socket, :bluetooth, Output.bluetooth())
    end
  end

  defp fmutate_name(destinations) do
    case Enum.find(destinations, &(&1.id == :fmutate)) do
      %{name: name} -> name
      nil -> "FMutate"
    end
  end

  @doc """
  Every tap target's `on_press_out` (MOB-509; the screen answers
  `{:press_out, :held}` with nothing). The Pair screen uses it too.
  """
  def held, do: {self(), :held}

  defp fmutate, do: Application.get_env(:humdinger, :fmutate, Humdinger.FMutate)
  defp device_calls?, do: Application.get_env(:humdinger, :device_calls, true)
end
