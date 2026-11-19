defmodule Humdinger.OutputScreenTest do
  # A real Output (named) and Engine over doubles; Mob.State is shared.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens, only: [assert_every_tap_held: 1, tap_tags: 1, texts: 1]

  alias Humdinger.Audio.Fake
  alias Humdinger.{Engine, Output, OutputScreen, PairScreen, Settings, Style}

  # Doubles behind Output (and the screen's FMutate link). They report to
  # the test, registered under this module's name.
  defmodule FMutate do
    def status, do: :persistent_term.get({__MODULE__, :status}, :unpaired)

    def subscribe(pid) do
      send(pid, {:fmutate, :status, status()})
      :ok
    end

    def send_midi(bytes), do: Humdinger.OutputScreenTest.report({:fmutate, bytes})
    def forget, do: Humdinger.OutputScreenTest.report(:forget)
  end

  defmodule Port do
    def available?, do: true
    def connections, do: 0
    def send(bytes), do: Humdinger.OutputScreenTest.report({:port, bytes})
  end

  defmodule Device do
    alias Humdinger.OutputScreenTest, as: T
    def subscribe, do: :ok
    def list, do: {:ok, []}
    def open(_id), do: :ok
    def close(_id), do: :ok
    def send(id, bytes), do: T.report({:device, id, bytes})

    def scan(ms) do
      T.report({:scan, ms})
      :persistent_term.get({__MODULE__, :scan}, :ok)
    end

    def stop_scan, do: T.report(:stop_scan)
    def connect(address), do: T.report({:connect, address})
    def disconnect(address), do: T.report({:disconnect, address})
    def recall, do: nil
    def remember(_device), do: :ok
  end

  @doc false
  def report(message) do
    send(__MODULE__, message)
    :ok
  end

  @connected {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 8", emulator: nil}}

  setup do
    Mob.State.delete(:settings)
    :ok = Settings.save(Settings.defaults())
    Fake.reset()
    Process.register(self(), __MODULE__)

    previous = Application.fetch_env(:humdinger, :fmutate)
    Application.put_env(:humdinger, :fmutate, FMutate)

    on_exit(fn ->
      :persistent_term.erase({FMutate, :status})
      :persistent_term.erase({Device, :scan})

      case previous do
        {:ok, module} -> Application.put_env(:humdinger, :fmutate, module)
        :error -> Application.delete_env(:humdinger, :fmutate)
      end
    end)

    # The test note's player runs on this clock (tests move it).
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    start_supervised!(
      {Output,
       name: Output,
       fmutate: FMutate,
       settings: Settings,
       port: Port,
       device: Device,
       sent_interval_ms: 0,
       clock: fn -> Agent.get(clock, & &1) end}
    )

    start_supervised!({Engine, audio: Fake, output: Output})
    %{clock: clock}
  end

  defp mount, do: OutputScreen |> mount_screen() |> pump()

  # Hands the screen what Output and FMutate sent it until things go quiet.
  defp pump(view, quiet_ms \\ 30) do
    receive do
      message when is_tuple(message) and elem(message, 0) in [:output, :fmutate] ->
        pump(render_info(view, message), quiet_ms)
    after
      quiet_ms -> view
    end
  end

  defp press(view, tag), do: view |> render_info({:tap, tag}) |> pump()

  defp card(view, id), do: find(view, :box, id: id)

  defp card_texts(view, id),
    do: for(n <- flatten(card(view, id)), n.type == :text, do: n.props.text)

  defp switch_on?(view, id) do
    card(view, id)
    |> flatten()
    |> Enum.find(&(&1.props[:on_tap] == {self(), {:toggle, id}}))
    |> on?()
  end

  defp on?(%{props: %{background: bg}}), do: bg == Style.fm()

  defp text_node(view, text),
    do: Enum.find(flatten(view), &(&1.type == :text and &1.props.text == text))

  defp set_fmutate(view, status) do
    :persistent_term.put({FMutate, :status}, status)
    send(Output, {:fmutate, :status, status})
    _ = Output.destinations()
    view |> render_info({:fmutate, :status, status}) |> pump()
  end

  describe "the board" do
    test "four destination cards, the channel grid, what gets sent, the footer" do
      view = mount()
      assert_renderable(view)

      assert card_texts(view, :fmutate) == ["FM", "FMutate", "not paired · pair below"]

      assert card_texts(view, :port) == [
               "PORT",
               "Humdinger port",
               "virtual MIDI · any app can pick it"
             ]

      assert card_texts(view, :usb) == ["USB", "USB MIDI out", "nothing plugged in"]
      assert card_texts(view, :bt) == ["BT", "Bluetooth MIDI", "none paired"]

      assert switch_on?(view, :fmutate) and switch_on?(view, :port)
      refute switch_on?(view, :usb) or switch_on?(view, :bt)
      # On and reachable: lime outline. On but FMutate isn't paired: none.
      assert card(view, :port).props.border_color == Style.fm()
      assert card(view, :fmutate).props.border_color == Style.surface()

      for text <- [
            "Pair FMutate · QR or code",
            "Scan Bluetooth",
            "CHANNEL",
            "WHAT GETS SENT",
            "note on / off",
            "velocity",
            "CC 11 expression",
            "pitch bend · open mode",
            "Last sent:",
            "nothing yet",
            "Send test note"
          ] do
        assert text in texts(view), text
      end

      refute "CC 1 vibrato" in texts(view)
      assert channel_selected(view) == [1]
      assert text_node(view, footer()).props.text_color == Style.muted()
    end

    test "every tap target carries the press-out handle (MOB-509), sheet and Forget included" do
      view = mount() |> set_fmutate(@connected) |> press(:scan_bluetooth)

      send(
        Output,
        {:humdinger_midi, :ble_found,
         JSON.encode!(%{address: "AA", name: "Minilogue", rssi: -60})}
      )

      view = pump(view)

      assert_every_tap_held(view)

      tags = tap_tags(view)

      for tag <-
            [:back, :pair, :scan_bluetooth, :test_note, :forget_fmutate, :stop_scan, :bt_sheet] ++
              Enum.map([:fmutate, :port, :usb, :bt], &{:toggle, &1}) ++
              Enum.map(1..16, &{:channel, &1}) ++ [{:connect_bluetooth, "AA"}] do
        assert tag in tags, inspect(tag)
      end
    end
  end

  describe "destinations" do
    test "a switch turns its destination on or off, saved, and the card follows" do
      view = mount() |> press({:toggle, :port})
      refute Enum.find(Output.destinations(), &(&1.id == :port)).enabled
      assert Settings.load().destinations.port == false
      refute switch_on?(view, :port)
      assert card(view, :port).props.border_color == Style.surface()

      view = press(view, {:toggle, :usb})
      assert Settings.load().destinations.usb
      assert switch_on?(view, :usb)
      # On, but nothing plugged in: no outline, dimmed.
      assert card(view, :usb).props.border_color == Style.surface()
      assert text_node(view, "USB MIDI out").props.text_color == Style.text_2()
    end

    test "with every destination off the footer warns" do
      view = mount() |> press({:toggle, :fmutate}) |> press({:toggle, :port})
      node = text_node(view, footer())
      assert node.props.text_color == Style.warn()
      assert node.props.font == :semibold
    end

    test "a connected FMutate shows its name and firmware, lit, and can be forgotten after a confirm" do
      view = set_fmutate(mount(), @connected)

      assert card_texts(view, :fmutate) == [
               "FM",
               "FMutate A",
               "sibling app · connected · X0X",
               "Forget this FMutate"
             ]

      assert card(view, :fmutate).props.border_color == Style.fm()

      view = press(view, :forget_fmutate)
      assert assigns(view).confirm == :forget_fmutate
      refute_received :forget

      view = render_info(view, {:alert, :dismiss})
      refute_received :forget
      assert assigns(view).confirm == nil

      view = view |> press(:forget_fmutate) |> render_info({:alert, :forget_fmutate})
      assert_received :forget
      assert assigns(view).confirm == nil

      view = set_fmutate(view, :unpaired)
      refute "Forget this FMutate" in texts(view)
      assert "not paired · pair below" in texts(view)
    end

    test "a paired FMutate that isn't connected still offers Forget" do
      view = set_fmutate(mount(), :disconnected)

      assert card_texts(view, :fmutate) == [
               "FM",
               "FMutate",
               "sibling app · not connected",
               "Forget this FMutate"
             ]
    end
  end

  describe "channel and test note" do
    # An app opens the Humdinger port, so Output sends to it.
    setup do
      send(Output, {:humdinger_midi, :port, ~s({"connections":1})})
      Output.sync()
      :ok
    end

    defp sync_test_player do
      player = GenServer.call(Output, :test_player)
      sync_player(player)
      player
    end

    defp sync_player(player) do
      :sys.replace_state(player, fn state ->
        case state.output do
          {module, server} -> module.sync(server)
          module -> module.sync()
        end

        state
      end)

      :ok
    end

    defp sync_engine do
      :sys.replace_state(Engine, fn state ->
        state.output.sync()
        state
      end)

      :ok
    end

    defp at(player, clock, t) do
      Agent.update(clock, fn _ -> t end)

      case :sys.get_state(player).token do
        nil -> :ok
        token -> send(player, {:tick, token})
      end

      sync_player(player)
    end

    test "the test note goes out on the channel, and Last sent follows Output", ctx do
      view = mount() |> press(:test_note)
      player = sync_test_player()
      assert_received {:port, <<0x90, 69, 92>>}
      view = pump(view, 0)
      assert "A4 on · vel 92 · ch 1" in texts(view)

      # 300 ms on the test note's clock, its tick run now.
      at(player, ctx.clock, 300)
      assert_received {:port, <<0x80, 69, 64>>}
      view = pump(view, 0)
      assert "A4 off · ch 1" in texts(view)
    end

    test "a channel goes through the Engine (saved, Output moved) and lights its cell" do
      view = mount() |> press({:channel, 5})
      assert Engine.settings().channel == 5
      assert Settings.load().channel == 5
      assert channel_selected(view) == [5]
      sync_engine()

      view = press(view, :test_note)
      sync_test_player()
      assert_received {:port, <<0x94, 69, 92>>}
      assert "A4 on · vel 92 · ch 5" in texts(pump(view, 0))
    end
  end

  describe "what gets sent" do
    test "chips follow the settings: open mode lights pitch bend, CC 1 appears with vibrato" do
      {:ok, _} =
        Engine.update_settings(%{
          mode: :open,
          cc1_from_vibrato: true,
          velocity_from_loudness: false,
          cc11_from_loudness: false
        })

      view = mount()

      assert OutputScreen.chips(Engine.settings()) == [
               {"note on / off", true},
               {"velocity · fixed 100", false},
               {"CC 11 expression", false},
               {"pitch bend · open mode", true},
               {"CC 1 vibrato", true}
             ]

      assert "CC 1 vibrato" in texts(view)
      assert text_node(view, "pitch bend · open mode").props.text_color == Style.text()
      assert text_node(view, "CC 11 expression").props.text_color == Style.muted()
    end
  end

  describe "Bluetooth" do
    test "Scan Bluetooth opens a sheet, lists finds, connects, forgets, and closes" do
      view = press(mount(), :scan_bluetooth)
      assert_received {:scan, 10_000}
      assert find(view, :sheet)
      assert "Looking for Bluetooth MIDI devices…" in texts(view)

      send(
        Output,
        {:humdinger_midi, :ble_found,
         JSON.encode!(%{address: "AA:BB", name: "Minilogue", rssi: -61})}
      )

      view = pump(view)
      assert "Minilogue" in texts(view)
      assert "-61 dBm" in texts(view)

      view = press(view, {:connect_bluetooth, "AA:BB"})
      assert_received {:connect, "AA:BB"}
      assert "Connecting…" in texts(view)
      refute {:connect_bluetooth, "AA:BB"} in tap_tags(view)

      send(
        Output,
        {:humdinger_midi, :ble_connected, JSON.encode!(%{address: "AA:BB", name: "x"})}
      )

      send(Output, {:humdinger_midi, :ble_scan_done, JSON.encode!(%{})})
      view = pump(view)
      assert assigns(view).bluetooth.paired == %{address: "AA:BB", name: "Minilogue"}
      assert "Forget" in texts(view)
      assert "Scan again" in texts(view)
      assert "Minilogue · not connected" in card_texts(view, :bt)

      view = press(view, :forget_bluetooth)
      assert_received {:disconnect, "AA:BB"}
      assert assigns(view).bluetooth.paired == nil
      assert "none paired" in card_texts(view, :bt)

      view = render_info(view, {:dismiss, :bt_sheet})
      refute find(view, :sheet)
    end

    test "closing the sheet while scanning stops the scan" do
      view = mount() |> press(:scan_bluetooth) |> press(:bt_sheet)
      assert_received :stop_scan
      refute find(view, :sheet)
    end

    test "a scan without the permission asks for it and scans once it's granted" do
      :persistent_term.put({Device, :scan}, {:error, :no_permission})
      view = press(mount(), :scan_bluetooth)
      assert_received {:scan, _}
      assert assigns(view).bt_permission == :asking
      assert "Allow Nearby devices so Humdinger can look for Bluetooth MIDI." in texts(view)

      :persistent_term.put({Device, :scan}, :ok)
      view = view |> render_info({:permission, :midi_bluetooth, :granted}) |> pump()
      assert_received {:scan, _}
      assert assigns(view).bluetooth.scanning
      assert "Looking for Bluetooth MIDI devices…" in texts(view)
    end

    test "a refused permission says how to turn it on" do
      :persistent_term.put({Device, :scan}, {:error, :no_permission})

      view =
        mount() |> press(:scan_bluetooth) |> render_info({:permission, :midi_bluetooth, :denied})

      assert "Bluetooth permission is off. Allow Nearby devices for Humdinger in Settings, then scan again." in texts(
               view
             )

      # Scan again asks again (Android shows the prompt until "don't ask again").
      view = press(view, :scan_bluetooth)
      assert assigns(view).bt_permission == :asking
      view = render_info(view, {:permission, :midi_bluetooth, :denied})
      assert assigns(view).bt_permission == :denied
    end

    test "scan errors read as plain words" do
      view = press(mount(), :scan_bluetooth)
      send(Output, {:humdinger_midi, :ble_scan_done, JSON.encode!(%{error: "bluetooth_off"})})
      assert "Bluetooth is off. Turn it on, then scan again." in texts(pump(view))
    end
  end

  describe "navigation" do
    test "Pair opens the Pair screen; back pops" do
      assert navigated_to(press(mount(), :pair)) == PairScreen
      assert navigated_to(press(mount(), :back)) == {:pop}
    end
  end

  defp footer,
    do: "Humdinger makes no sound itself. Turn on at least one destination, or nothing will play."

  defp channel_selected(view) do
    for node <- flatten(view),
        match?({_, {:channel, _}}, node.props[:on_tap]),
        node.props.background == Style.fm(),
        do: elem(elem(node.props.on_tap, 1), 1)
  end
end
