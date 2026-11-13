defmodule Humdinger.OutputTest do
  use ExUnit.Case, async: true

  alias Humdinger.Output

  # Doubles for the modules Output talks to. They run in the Output process
  # and report to the test that started it (Output keeps its starter in
  # $callers, as Task does).
  defmodule FMutate do
    def status, do: :unpaired
    def subscribe(_pid), do: :ok
    def send_midi(bytes), do: Humdinger.OutputTest.report_from_double({:fmutate, bytes})
  end

  defmodule Settings do
    @settings %{channel: 1, destinations: %{fmutate: true, port: true, usb: true, bt: true}}
    def load, do: @settings

    def update(fun) do
      settings = fun.(@settings)
      Humdinger.OutputTest.report_from_double({:saved, settings.destinations})
      {:ok, settings}
    end
  end

  defmodule Port do
    def available?, do: true
    def connections, do: 1
    def send(bytes), do: Humdinger.OutputTest.report_from_double({:port, bytes})
  end

  # A registered FMutate process, so Output can monitor it and see it restart.
  defmodule FMutateProc do
    def start(status), do: Agent.start(fn -> status end, name: __MODULE__)
    def status, do: Agent.get(__MODULE__, & &1)

    def subscribe(pid) do
      _ = status()
      Humdinger.OutputTest.report_from_double({:subscribed, pid})
    end

    def send_midi(_bytes), do: :ok
  end

  defmodule Device do
    def subscribe, do: :ok
    def list, do: {:ok, []}
    def open(id), do: Humdinger.OutputTest.report_from_double({:open, id})
    def close(id), do: Humdinger.OutputTest.report_from_double({:close, id})
    def send(id, bytes), do: Humdinger.OutputTest.report_from_double({:device, id, bytes})
    def scan(ms), do: Humdinger.OutputTest.report_from_double({:scan, ms})
    def stop_scan, do: :ok
    def connect(address), do: Humdinger.OutputTest.report_from_double({:connect, address})
    def disconnect(address), do: Humdinger.OutputTest.report_from_double({:disconnect, address})
    def recall, do: nil
    def remember(device), do: Humdinger.OutputTest.report_from_double({:remember, device})
  end

  defmodule PairedDevice do
    defdelegate subscribe, to: Humdinger.OutputTest.Device
    defdelegate list, to: Humdinger.OutputTest.Device
    defdelegate open(id), to: Humdinger.OutputTest.Device
    defdelegate close(id), to: Humdinger.OutputTest.Device
    defdelegate send(id, bytes), to: Humdinger.OutputTest.Device
    defdelegate connect(address), to: Humdinger.OutputTest.Device
    defdelegate disconnect(address), to: Humdinger.OutputTest.Device
    defdelegate remember(device), to: Humdinger.OutputTest.Device
    def recall, do: %{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}
  end

  defmodule NoPort do
    def available?, do: false
    def connections, do: 0
    def send(_bytes), do: {:error, :unavailable}
  end

  @doc false
  def report_from_double(message) do
    [test | _] = Process.get(:"$callers")
    send(test, message)
    :ok
  end

  @connected {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 8"}}

  defp start(opts \\ []) do
    defaults = [
      name: nil,
      fmutate: FMutate,
      settings: Settings,
      port: Port,
      device: Device,
      sent_interval_ms: 50
    ]

    {:ok, pid} = Output.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp connect_fmutate(output) do
    send(output, {:fmutate, :status, @connected})
    Output.destinations(output)
  end

  defp device_json(id, type, opts \\ []) do
    JSON.encode!(%{
      id: id,
      name: Keyword.get(opts, :name, "Synth #{id}"),
      type: type,
      inputs: Keyword.get(opts, :inputs, 1),
      outputs: 0,
      own: Keyword.get(opts, :own, false),
      address: Keyword.get(opts, :address, "")
    })
  end

  defp plug(output, id, type, opts \\ []) do
    send(output, {:humdinger_midi, :device_added, device_json(id, type, opts)})
    Output.destinations(output)
  end

  defp row(output, id), do: Enum.find(Output.destinations(output), &(&1.id == id))

  describe "send_events/1" do
    test "encodes once on the channel and fans out to enabled, available destinations" do
      output = start()
      connect_fmutate(output)
      plug(output, 7, "usb")
      assert_receive {:open, 7}

      Output.configure([channel: 3], output)
      Output.send_events([{:note_on, 69, 92}, {:pitch_bend, 0}], output)

      for bytes <- [<<0x92, 69, 92>>, <<0xE2, 0x00, 0x40>>] do
        assert_receive {:fmutate, ^bytes}
        assert_receive {:port, ^bytes}
        assert_receive {:device, 7, ^bytes}
      end
    end

    test "skips destinations that are off or can't be reached" do
      output = start()
      Output.set_enabled(:port, false, output)
      flush_port()

      Output.send_events([{:note_on, 60, 100}], output)
      assert Output.last_sent(output) == nil
      refute_receive {:port, _}
      refute_receive {:fmutate, _}
    end

    test "last_sent describes the last event of the batch" do
      output = start()
      Output.send_events([{:note_on, 69, 92}, {:cc, 11, 80}], output)
      assert Output.last_sent(output) == "CC 11 = 80 · ch 1"
    end
  end

  describe "turning a destination off" do
    test "sends it the note-offs it needs, and nothing to the others" do
      output = start()
      connect_fmutate(output)
      Output.send_events([{:note_on, 60, 100}, {:note_on, 64, 100}, {:note_off, 60}], output)
      flush_port()
      flush_fmutate()

      :ok = Output.set_enabled(:port, false, output)

      assert_receive {:port, <<0x80, 64, 64>>}
      refute_receive {:port, <<0x80, 60, _>>}
      refute_receive {:fmutate, <<0x80, _, _>>}
      assert_receive {:saved, %{port: false, fmutate: true}}
      assert %{enabled: false} = row(output, :port)
    end

    test "releases a note on the channel it was played on" do
      output = start()
      Output.send_events([{:note_on, 60, 100}], output)
      Output.configure([channel: 5], output)

      Output.set_enabled(:port, false, output)
      assert_receive {:port, <<0x80, 60, 64>>}
    end

    test "puts bend, modulation and expression back, and turning it on again sends nothing" do
      output = start()
      Output.send_events([{:pitch_bend, 2000}, {:cc, 11, 20}], output)
      flush_port()

      Output.set_enabled(:port, false, output)

      assert port_messages() ==
               MapSet.new([<<0xE0, 0x00, 0x40>>, <<0xB0, 1, 0>>, <<0xB0, 11, 127>>])

      Output.set_enabled(:port, true, output)
      assert_receive {:saved, %{port: true}}
      refute_receive {:port, _}
    end

    test "USB closes its devices after their note-offs" do
      output = start()
      plug(output, 7, "usb")
      Output.send_events([{:note_on, 62, 90}], output)

      Output.set_enabled(:usb, false, output)
      assert_receive {:device, 7, <<0x80, 62, 64>>}
      assert_receive {:close, 7}
    end
  end

  describe "panic/0" do
    test "note-offs for what is sounding, then CC 123 on every channel used and the current one" do
      output = start()
      Output.send_events([{:note_on, 60, 100}], output)
      Output.configure([channel: 2], output)
      Output.send_events([{:note_on, 67, 100}], output)
      Output.configure([channel: 4], output)
      flush_port()

      :ok = Output.panic(output)

      resets = fn ch ->
        [<<0xE0 + ch, 0x00, 0x40>>, <<0xB0 + ch, 1, 0>>, <<0xB0 + ch, 11, 127>>]
      end

      assert port_messages() ==
               MapSet.new(
                 [
                   <<0x80, 60, 64>>,
                   <<0xB0, 123, 0>>,
                   <<0x81, 67, 64>>,
                   <<0xB1, 123, 0>>,
                   <<0xB3, 123, 0>>
                 ] ++ resets.(0) ++ resets.(1) ++ resets.(3)
               )

      :ok = Output.panic(output)
      assert port_messages() == MapSet.new([<<0xB3, 123, 0>> | resets.(3)])
    end
  end

  test "a destination that drops out forgets its sounding notes" do
    output = start()
    connect_fmutate(output)
    Output.send_events([{:note_on, 60, 100}], output)
    send(output, {:fmutate, :status, :disconnected})
    send(output, {:fmutate, :status, @connected})
    flush_fmutate()

    Output.set_enabled(:fmutate, false, output)
    refute_receive {:fmutate, <<0x80, _, _>>}
  end

  test "re-subscribes to FMutate after it restarts" do
    {:ok, fmutate} = FMutateProc.start(@connected)
    output = start(fmutate: FMutateProc)
    assert_receive {:subscribed, ^output}
    assert row(output, :fmutate).available

    Process.exit(fmutate, :kill)
    assert eventually(fn -> row(output, :fmutate).detail == "sibling app · not connected" end)

    {:ok, restarted} = FMutateProc.start(@connected)
    assert_receive {:subscribed, ^output}, 2_000
    assert row(output, :fmutate).available
    Agent.stop(restarted)
  end

  test "test_note/0 plays A4 at velocity 92 for 300 ms" do
    output = start()
    started = System.monotonic_time(:millisecond)
    Output.test_note(output)

    assert_receive {:port, <<0x90, 69, 92>>}, 1_000
    assert_receive {:port, <<0x80, 69, 64>>}, 1_000
    assert System.monotonic_time(:millisecond) - started >= 300
  end

  describe "subscribe/1" do
    test "sends the destinations at once and on every change" do
      output = start()
      :ok = Output.subscribe(self(), output)
      assert_receive {:output, :destinations, [%{id: :fmutate, available: false} | _]}

      connect_fmutate(output)
      assert_receive {:output, :destinations, [%{id: :fmutate, available: true} | _]}

      Output.send_events([{:note_on, 60, 100}], output)
      refute_receive {:output, :destinations, _}
    end

    test "sent summaries are throttled, the latest one winning" do
      output = start(sent_interval_ms: 300)
      Output.subscribe(self(), output)
      started = System.monotonic_time(:millisecond)

      for velocity <- 1..5, do: Output.send_events([{:note_on, 60, velocity}], output)

      # The first summary goes at once; the next one is the latest, one
      # interval later, with nothing in between and nothing after.
      assert_receive {:output, :sent, "C4 on · vel 1 · ch 1"}, 2_000
      assert_receive {:output, :sent, second}, 2_000
      assert second == "C4 on · vel 5 · ch 1"
      assert System.monotonic_time(:millisecond) - started >= 300
      refute_receive {:output, :sent, _}, 400
    end

    test "a subscriber that exits is dropped" do
      output = start()
      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      Output.subscribe(subscriber, output)
      Output.subscribe(subscriber, output)
      assert {:monitors, [_]} = Process.info(output, :monitors)

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}
      Output.send_events([{:note_on, 60, 100}], output)
      assert eventually(fn -> Process.info(output, :monitors) == {:monitors, []} end)
    end
  end

  describe "destinations/0" do
    test "the board's rows with nothing connected" do
      output = start()

      assert Output.destinations(output) == [
               %{
                 id: :fmutate,
                 name: "FMutate",
                 detail: "sibling app · not paired",
                 enabled: true,
                 available: false
               },
               %{
                 id: :port,
                 name: "Humdinger port",
                 detail: "virtual MIDI · 1 app listening",
                 enabled: true,
                 available: true
               },
               %{
                 id: :usb,
                 name: "USB MIDI out",
                 detail: "nothing plugged in",
                 enabled: true,
                 available: false
               },
               %{
                 id: :bt,
                 name: "Bluetooth MIDI",
                 detail: "none paired",
                 enabled: true,
                 available: false
               }
             ]
    end

    test "FMutate's name and firmware once connected" do
      output = start()
      connect_fmutate(output)

      assert %{name: "FMutate A", detail: "sibling app · connected · X0X", available: true} =
               row(output, :fmutate)

      send(output, {:fmutate, :status, :disconnected})
      assert %{name: "FMutate", detail: "sibling app · not connected"} = row(output, :fmutate)
    end

    test "apps listening on the port, and nothing sent to it while none is" do
      output = start()
      send(output, {:humdinger_midi, :port, ~s({"connections":2})})
      assert row(output, :port).detail == "virtual MIDI · 2 apps listening"
      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:port, <<0x90, 60, 100>>}

      send(output, {:humdinger_midi, :port, ~s({"connections":0})})
      assert %{available: true, detail: "virtual MIDI · any app can pick it"} = row(output, :port)
      Output.send_events([{:note_off, 60}], output)
      refute_receive {:port, _}

      # The app that held the note has gone: a new one doesn't get a stray note-off.
      send(output, {:humdinger_midi, :port, ~s({"connections":1})})
      Output.set_enabled(:port, false, output)
      refute_receive {:port, <<0x80, 60, _>>}
    end

    test "where the port doesn't exist" do
      output = start(port: NoPort)
      assert %{available: false, detail: "virtual MIDI · not on this phone"} = row(output, :port)
    end

    test "defaults without a Settings module: FMutate and port on, USB and Bluetooth off" do
      output = start(settings: Humdinger.NoSuchSettings)

      assert Enum.map(Output.destinations(output), &{&1.id, &1.enabled}) ==
               [fmutate: true, port: true, usb: false, bt: false]

      Output.set_enabled(:usb, true, output)
      assert row(output, :usb).enabled
    end
  end

  describe "USB devices" do
    test "plugged in and pulled out" do
      output = start()
      plug(output, 7, "usb", name: "Volca Keys")
      assert_receive {:open, 7}
      assert %{available: true, detail: "Volca Keys"} = row(output, :usb)

      send(output, {:humdinger_midi, :device_removed, device_json(7, "usb")})
      assert %{available: false, detail: "nothing plugged in"} = row(output, :usb)
      assert_receive {:close, 7}
    end

    test "ignores devices it can't send to, its own port and other apps' virtual devices" do
      output = start()
      plug(output, 1, "usb", inputs: 0)
      plug(output, 2, "virtual", own: true)
      plug(output, 3, "virtual", name: "FMutate A")
      assert %{available: false} = row(output, :usb)
      refute_receive {:open, _}
    end

    @tag :capture_log
    test "a device that fails to open is shown and not sent to" do
      output = start()
      plug(output, 7, "usb", name: "Volca Keys")

      send(
        output,
        {:midi, :error, %{device: 7, op: :open_output, reason: :open_failed, dropped: 0}}
      )

      assert %{available: false, detail: "Volca Keys · can't open"} = row(output, :usb)
      Output.send_events([{:note_on, 60, 100}], output)
      refute_receive {:device, 7, _}
    end

    test "devices of a destination that is off aren't opened until it is turned on" do
      output = start()
      Output.set_enabled(:usb, false, output)
      plug(output, 7, "usb")
      refute_receive {:open, 7}

      Output.set_enabled(:usb, true, output)
      assert_receive {:open, 7}
    end
  end

  describe "Bluetooth" do
    test "scan, connect, remember" do
      output = start()
      Output.subscribe(self(), output)

      assert :ok = Output.scan_bluetooth(output)
      assert_receive {:scan, 10_000}
      assert_receive {:output, :bluetooth, %{scanning: true, found: []}}

      found = ~s({"address":"AA:BB:CC:DD:EE:FF","name":"Minilogue","rssi":-60})
      send(output, {:humdinger_midi, :ble_found, found})
      send(output, {:humdinger_midi, :ble_found, found})
      send(output, {:humdinger_midi, :ble_scan_done, "{}"})

      assert %{scanning: false, found: [%{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}]} =
               Output.bluetooth(output)

      assert :ok = Output.connect_bluetooth("AA:BB:CC:DD:EE:FF", output)
      assert_receive {:connect, "AA:BB:CC:DD:EE:FF"}
      assert row(output, :bt).detail == "connecting…"

      # Android's own name for it can be the generic one; the scan's wins.
      connected = ~s({"address":"AA:BB:CC:DD:EE:FF","id":12,"name":"MIDI device"})
      send(output, {:humdinger_midi, :ble_connected, connected})
      plug(output, 12, "bluetooth", name: "Minilogue", address: "AA:BB:CC:DD:EE:FF")

      assert_receive {:remember, %{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}}
      assert_receive {:open, 12}
      assert %{available: true, detail: "Minilogue"} = row(output, :bt)

      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:device, 12, <<0x90, 60, 100>>}

      # Forgetting it releases its notes and closes mob_midi's output too, or
      # Android would keep the device connected.
      Output.forget_bluetooth(output)
      assert_receive {:device, 12, <<0x80, 60, 64>>}
      assert_receive {:close, 12}
      assert_receive {:disconnect, "AA:BB:CC:DD:EE:FF"}
      assert %{available: false, detail: "none paired"} = row(output, :bt)

      # A connection that completes after it was forgotten is dropped.
      send(output, {:humdinger_midi, :ble_connected, connected})
      assert_receive {:disconnect, "AA:BB:CC:DD:EE:FF"}
      assert Output.bluetooth(output).paired == nil
    end

    test "reconnects the remembered device at start and can forget it" do
      output = start(device: PairedDevice)
      assert_receive {:connect, "AA:BB:CC:DD:EE:FF"}

      send(
        output,
        {:humdinger_midi, :ble_failed, ~s({"address":"AA:BB:CC:DD:EE:FF","reason":"open_failed"})}
      )

      assert row(output, :bt).detail == "Minilogue · not connected"
      assert Output.bluetooth(output).error == :open_failed

      Output.forget_bluetooth(output)
      assert_receive {:disconnect, "AA:BB:CC:DD:EE:FF"}
      assert_receive {:remember, nil}
      assert row(output, :bt).detail == "none paired"
    end
  end

  defp eventually(check, tries \\ 20) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, tries - 1)
    end
  end

  defp flush_port do
    receive do
      {:port, _} -> flush_port()
    after
      50 -> :ok
    end
  end

  defp flush_fmutate do
    receive do
      {:fmutate, _} -> flush_fmutate()
    after
      50 -> :ok
    end
  end

  defp port_messages(acc \\ MapSet.new()) do
    receive do
      {:port, bytes} -> port_messages(MapSet.put(acc, bytes))
    after
      50 -> acc
    end
  end
end
