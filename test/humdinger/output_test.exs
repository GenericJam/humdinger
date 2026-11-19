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
    def open(_name), do: :ok
    def send(_id, bytes), do: Humdinger.OutputTest.report_from_double({:port, bytes})
    def discard(_id), do: {:ok, 2}
  end

  # A port whose queue is full behind a stalled listener: refuses while the
  # test has set {RefusingPort, test} in persistent_term.
  defmodule RefusingPort do
    def open(_name), do: :ok

    def send(_id, bytes) do
      [test | _] = Process.get(:"$callers")

      if :persistent_term.get({__MODULE__, test}, false) do
        Humdinger.OutputTest.report_from_double({:refused, bytes})
        {:error, :queue_full}
      else
        Humdinger.OutputTest.report_from_double({:port, bytes})
      end
    end

    def discard(_id) do
      [test | _] = Process.get(:"$callers")
      gen = :persistent_term.get({__MODULE__, :gen, test}, 1) + 1
      :persistent_term.put({__MODULE__, :gen, test}, gen)
      Humdinger.OutputTest.report_from_double({:port_discard, gen})
      {:ok, gen}
    end
  end

  # A port whose native side throws on every send (a NIF exception).
  defmodule RaisingPort do
    def open(_name), do: :ok
    def send(_id, _bytes), do: raise(ArgumentError, "port gone")
    def discard(_id), do: {:ok, 1}
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
    def list, do: Humdinger.OutputTest.report_from_double(:list_devices)
    def open(id), do: Humdinger.OutputTest.report_from_double({:open, id})
    def close(id), do: Humdinger.OutputTest.report_from_double({:close, id})
    def send(id, bytes), do: Humdinger.OutputTest.report_from_double({:device, id, bytes})
    def discard(id), do: {:ok, id}
    def scan(ms), do: Humdinger.OutputTest.report_from_double({:scan, ms})
    def stop_scan, do: :ok
    def connect(address), do: Humdinger.OutputTest.report_from_double({:connect, address})
    def recall, do: nil
    def remember(device), do: Humdinger.OutputTest.report_from_double({:remember, device})
  end

  defmodule RefusingDevice do
    defdelegate list, to: Humdinger.OutputTest.Device
    defdelegate open(id), to: Humdinger.OutputTest.Device
    defdelegate close(id), to: Humdinger.OutputTest.Device
    defdelegate scan(ms), to: Humdinger.OutputTest.Device
    defdelegate stop_scan, to: Humdinger.OutputTest.Device
    defdelegate connect(address), to: Humdinger.OutputTest.Device
    defdelegate recall, to: Humdinger.OutputTest.Device
    defdelegate remember(device), to: Humdinger.OutputTest.Device

    def send(id, bytes) do
      [test | _] = Process.get(:"$callers")

      if :persistent_term.get({__MODULE__, test}, false) do
        Humdinger.OutputTest.report_from_double({:device_refused, id, bytes})
        {:error, :queue_full}
      else
        Humdinger.OutputTest.report_from_double({:device, id, bytes})
      end
    end

    def discard(id) do
      Humdinger.OutputTest.report_from_double({:device_discard, id})
      {:ok, 2}
    end
  end

  defmodule PairedDevice do
    defdelegate list, to: Humdinger.OutputTest.Device
    defdelegate open(id), to: Humdinger.OutputTest.Device
    defdelegate close(id), to: Humdinger.OutputTest.Device
    defdelegate send(id, bytes), to: Humdinger.OutputTest.Device
    defdelegate discard(id), to: Humdinger.OutputTest.Device
    defdelegate connect(address), to: Humdinger.OutputTest.Device
    defdelegate remember(device), to: Humdinger.OutputTest.Device
    def recall, do: %{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}
  end

  defmodule NoPort do
    def open(_name), do: {:error, :unsupported}
    def send(_id, _bytes), do: {:error, :unsupported}
    def discard(_id), do: {:error, :unsupported}
  end

  @doc false
  def report_from_double(message) do
    [test | _] = Process.get(:"$callers")
    send(test, message)
    :ok
  end

  @port_id 1
  @connected {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 8"}}

  defp start(opts \\ []) do
    {open_port, opts} = Keyword.pop(opts, :open_port, Keyword.get(opts, :port, Port) != NoPort)

    defaults = [
      name: nil,
      fmutate: FMutate,
      settings: Settings,
      port: Port,
      device: Device,
      sent_interval_ms: 50
    ]

    {:ok, pid} = Output.start_link(Keyword.merge(defaults, opts))
    Output.sync(pid)

    receive do
      :list_devices -> :ok
    after
      0 -> :ok
    end

    if open_port do
      send(pid, {:midi, :opened, %{device: @port_id, direction: :virtual, name: "Humdinger"}})
      send(pid, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 1}})
      # A fresh Output resets the port's 16 channels (tested on its own).
      Output.sync(pid)
      for bytes <- port_reset(), do: receive(do: ({:port, ^bytes} -> :ok), after: (0 -> :ok))
    end

    pid
  end

  defp port_reset, do: Humdinger.Midi.panic()

  test "a fresh Output resets all 16 channels of the port before anything else" do
    {:ok, output} =
      Output.start_link(
        name: nil,
        fmutate: FMutate,
        settings: Settings,
        port: Port,
        device: Device
      )

    send(output, {:midi, :opened, %{device: @port_id, direction: :virtual, name: "Humdinger"}})
    send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 1}})
    Output.send_events([{:note_on, 60, 100}], output)
    for bytes <- port_reset(), do: assert_receive({:port, ^bytes})
    assert_receive {:port, <<0x90, 60, 100>>}
  end

  defp connect_fmutate(output) do
    send(output, {:fmutate, :status, @connected})
    Output.destinations(output)
  end

  defp device_entry(id, type, opts \\ []) do
    %{
      id: id,
      name: Keyword.get(opts, :name, "Synth #{id}"),
      type: type,
      direction: :output,
      manufacturer: "",
      input_ports: Keyword.get(opts, :input_ports, 0),
      output_ports: Keyword.get(opts, :output_ports, 1),
      own: Keyword.get(opts, :own, false),
      address: Keyword.get(opts, :address, "")
    }
  end

  # Delivers a device list (as mob_midi does) and reports the device open
  # unless `opened: false`.
  defp plug(output, id, type, opts \\ []) do
    send(output, {:midi, :devices, [device_entry(id, type, opts)]})

    if Keyword.get(opts, :opened, true) do
      send(output, {:midi, :opened, %{device: id, port: 0, direction: :output, handle: id}})
    end

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
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed in 300..1_000
  end

  test "a second test note restarts the first instead of being cut short by it" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    output = start(clock: fn -> Agent.get(clock, & &1) end)
    player = test_note(output)

    # Taking the output from the singer puts its controllers back first.
    assert sent_to_port(player) ==
             Humdinger.Midi.reset_controllers(1) ++ [<<0x90, 69, 92>>]

    at(player, clock, 150)
    ^player = test_note(output)
    # Struck again at 150: the first ends there, the second starts.
    assert sent_to_port(player) == [<<0x80, 69, 64>>, <<0x90, 69, 92>>]

    # It lasts its own 300 ms (to 450), not the first's (to 300).
    at(player, clock, 449)
    assert sent_to_port(player) == []
    at(player, clock, 450)
    assert sent_to_port(player) == [<<0x80, 69, 64>>]
  end

  defp test_note(output) do
    :ok = Output.test_note(output)
    player = GenServer.call(output, :test_player)
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

  # What the test player has sent the port through Output so far, in order.
  defp sent_to_port(player) do
    sync_player(player)
    drain(:port, [])
  end

  defp drain(tag, acc) do
    receive do
      {^tag, bytes} -> drain(tag, [bytes | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Moves the test player's clock to `t` and runs its pending tick now.
  defp at(player, clock, t) do
    Agent.update(clock, fn _ -> t end)

    case :sys.get_state(player).token do
      nil -> :ok
      token -> send(player, {:tick, token})
    end

    sync_player(player)
  end

  describe "one source at a time" do
    defp session_note(output, ref, event), do: Output.session_events(ref, [event], output)

    test "a session takes over: the live note goes off, live events are dropped until release" do
      output = start()
      Output.follow_session(self(), output)
      assert_receive {:output, :session, :idle}
      Output.send_events([{:note_on, 60, 100}, {:pitch_bend, 900}], output)
      flush_port()

      {:ok, ref} = Output.acquire(self(), output)
      assert_receive {:output, :session, :active}
      # The singer's note off and its controllers back before the session plays.
      for bytes <- [<<0x80, 60, 64>> | Humdinger.Midi.reset_controllers(1)],
          do: assert_receive({:port, ^bytes})

      # The same pitch from both: the singer's events can't touch the session's.
      session_note(output, ref, {:note_on, 60, 90})
      Output.send_events([{:note_off, 60}, {:note_on, 64, 100}], output)
      assert_receive {:port, <<0x90, 60, 90>>}
      refute_receive {:port, _}

      :ok = Output.release(ref, output)
      assert_receive {:port, <<0x80, 60, 64>>}
      assert_receive {:output, :session, :idle}
      Output.send_events([{:note_on, 64, 100}], output)
      assert_receive {:port, <<0x90, 64, 100>>}
    end

    test "a newer session preempts: the older one's notes go off and its owner is told" do
      output = start()
      {:ok, first} = Output.acquire(self(), output)
      session_note(output, first, {:note_on, 60, 90})
      flush_port()

      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, second} = Output.acquire(owner, output)
      assert_receive {:output, :session_ended, ^first}
      assert_receive {:port, <<0x80, 60, 64>>}

      # The old session's events are dropped; the new one's go out.
      session_note(output, first, {:note_on, 62, 90})
      session_note(output, second, {:note_on, 64, 90})
      assert_receive {:port, <<0x90, 64, 90>>}
      refute_received {:port, <<0x90, 62, 90>>}
    end

    test "a session whose owner is killed has its notes released" do
      output = start()
      Output.follow_session(self(), output)
      assert_receive {:output, :session, :idle}
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, ref} = Output.acquire(owner, output)
      session_note(output, ref, {:note_on, 67, 90})
      flush_port()

      Process.exit(owner, :kill)
      assert_receive {:port, <<0x80, 67, 64>>}
      assert_receive {:output, :session, :idle}
    end
  end

  describe "never leaving a receiver stuck" do
    test "stopping Output silences what it left sounding" do
      output = start()
      Output.send_events([{:note_on, 60, 100}, {:pitch_bend, 900}], output)
      flush_port()

      Process.unlink(output)
      :ok = GenServer.stop(output, :shutdown)

      assert port_messages() ==
               MapSet.new([
                 <<0x80, 60, 64>>,
                 <<0xB0, 123, 0>> | Humdinger.Midi.reset_controllers(1)
               ])
    end

    test "the first app to open the port again starts from silence, before any note" do
      output = start()
      Output.configure([channel: 2], output)
      Output.send_events([{:note_on, 60, 100}], output)
      send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 0}})
      flush_port()

      send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 1}})
      Output.send_events([{:note_on, 64, 100}], output)

      for bytes <- Humdinger.Midi.panic(), do: assert_receive({:port, ^bytes})
      assert_receive {:port, <<0x91, 64, 100>>}
    end

    test "a port that refuses bytes gets nothing until it drains, then the releases first" do
      key = {RefusingPort, self()}
      gen_key = {RefusingPort, :gen, self()}

      on_exit(fn ->
        :persistent_term.erase(key)
        :persistent_term.erase(gen_key)
      end)

      output = start(port: RefusingPort)
      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:port, <<0x90, 60, 100>>}

      :persistent_term.put(key, true)
      Output.send_events([{:note_off, 60}, {:note_on, 62, 100}], output)
      assert_receive {:refused, <<0x80, 60, 64>>}
      assert_receive {:port_discard, 2}
      # Refused once, it isn't sent to again until it has drained.
      refute_receive {:refused, _}
      :persistent_term.put(key, false)
      Output.send_events([{:note_on, 64, 100}], output)
      refute_receive {:port, _}

      # Stale drain generation is ignored.
      send(output, {:midi, :drained, %{device: @port_id, port: 0, handle: 1, generation: 1}})
      Output.send_events([{:note_on, 64, 100}], output)
      refute_receive {:port, _}

      send(output, {:midi, :drained, %{device: @port_id, port: 0, handle: 1, generation: 2}})
      assert_receive {:port, <<0x80, 60, 64>>}

      for bytes <- Humdinger.Midi.panic(), do: assert_receive({:port, ^bytes})

      # A duplicate drain for the handled generation doesn't panic again.
      send(output, {:midi, :drained, %{device: @port_id, port: 0, handle: 1, generation: 2}})
      Output.sync(output)
      refute_receive {:port, _}

      Output.send_events([{:note_on, 65, 100}], output)
      assert_receive {:port, <<0x90, 65, 100>>}
    end

    test "a USB device that refuses bytes gets nothing until it drains, then releases first" do
      key = {RefusingDevice, self()}
      on_exit(fn -> :persistent_term.erase(key) end)
      output = start(device: RefusingDevice)
      plug(output, 7, "usb")
      flush_devices()

      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:device, 7, <<0x90, 60, 100>>}

      :persistent_term.put(key, true)
      Output.send_events([{:note_off, 60}, {:note_on, 62, 100}], output)
      assert_receive {:device_refused, 7, <<0x80, 60, 64>>}
      assert_receive {:device_discard, 7}
      refute_receive {:device_refused, _, _}

      :persistent_term.put(key, false)
      Output.send_events([{:note_on, 64, 100}], output)
      refute_receive {:device, 7, _}

      # Stale drain generation is ignored.
      send(output, {:midi, :drained, %{device: 7, port: 0, handle: 7, generation: 1}})
      Output.send_events([{:note_on, 64, 100}], output)
      refute_receive {:device, 7, _}

      send(output, {:midi, :drained, %{device: 7, port: 0, handle: 7, generation: 2}})
      assert_receive {:device, 7, <<0x80, 60, 64>>}
      for bytes <- Humdinger.Midi.panic(), do: assert_receive({:device, 7, ^bytes})

      Output.send_events([{:note_on, 65, 100}], output)
      assert_receive {:device, 7, <<0x90, 65, 100>>}
    end

    test "FMutate resynchronising gets no MIDI, and its notes are its own to release" do
      output = start()
      connect_fmutate(output)
      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:fmutate, <<0x90, 60, 100>>}

      send(output, {:fmutate, :midi, :resyncing})
      Output.send_events([{:note_off, 60}, {:note_on, 62, 100}], output)
      Output.set_enabled(:fmutate, false, output)
      refute_receive {:fmutate, _}

      Output.set_enabled(:fmutate, true, output)
      send(output, {:fmutate, :midi, :ready})
      Output.send_events([{:note_on, 64, 100}], output)
      assert_receive {:fmutate, <<0x90, 64, 100>>}
    end

    test "a device whose output opens is reset before its first note" do
      output = start()
      plug(output, 7, "usb", opened: false)
      Output.send_events([{:note_on, 60, 100}], output)
      refute_receive {:device, 7, _}

      send(output, {:midi, :opened, %{device: 7, port: 0, direction: :output, handle: 7}})
      Output.send_events([{:note_on, 62, 100}], output)

      for bytes <- Humdinger.Midi.panic(), do: assert_receive({:device, 7, ^bytes})
      assert_receive {:device, 7, <<0x90, 62, 100>>}
    end

    test "a port refusing a note doesn't stop USB from getting and tracking it" do
      key = {RefusingPort, self()}
      gen_key = {RefusingPort, :gen, self()}

      on_exit(fn ->
        :persistent_term.erase(key)
        :persistent_term.erase(gen_key)
      end)

      output = start(port: RefusingPort)
      plug(output, 7, "usb")
      flush_devices()

      :persistent_term.put(key, true)
      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:refused, <<0x90, 60, 100>>}
      assert_receive {:device, 7, <<0x90, 60, 100>>}

      Output.set_enabled(:usb, false, output)
      assert_receive {:device, 7, <<0x80, 60, 64>>}
    end

    test "a drain this Output didn't see the refusal for still resets the port" do
      output = start()
      send(output, {:midi, :drained, %{device: @port_id, port: 0, handle: 1, generation: 3}})
      for bytes <- Humdinger.Midi.panic(), do: assert_receive({:port, ^bytes})
    end

    @tag :capture_log
    test "a destination that raises doesn't keep the others from their notes or their panic" do
      output = start(port: RaisingPort)
      connect_fmutate(output)
      plug(output, 7, "usb")
      flush_devices()

      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:fmutate, <<0x90, 60, 100>>}
      assert_receive {:device, 7, <<0x90, 60, 100>>}

      Process.unlink(output)
      :ok = GenServer.stop(output, :shutdown)
      assert_receive {:fmutate, <<0x80, 60, 64>>}
      assert_receive {:fmutate, <<0xB0, 123, 0>>}
      # USB comes after the port that raised: it is silenced too.
      assert_receive {:device, 7, <<0x80, 60, 64>>}
      assert_receive {:device, 7, <<0xB0, 123, 0>>}
    end
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
      send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 2}})
      assert row(output, :port).detail == "virtual MIDI · 2 apps listening"
      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:port, <<0x90, 60, 100>>}

      send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 0}})
      assert %{available: true, detail: "virtual MIDI · any app can pick it"} = row(output, :port)
      Output.send_events([{:note_off, 60}], output)
      refute_receive {:port, _}

      # The app that held the note has gone: a new one doesn't get a stray note-off.
      send(output, {:midi, :virtual_status, %{device: @port_id, senders: 0, listeners: 1}})
      Output.set_enabled(:port, false, output)
      refute_receive {:port, <<0x80, 60, _>>}
    end

    test "where the port doesn't exist" do
      output = start(port: NoPort)
      assert %{available: false, detail: "virtual MIDI · not on this phone"} = row(output, :port)
    end

    @tag :capture_log
    test "where open_virtual fails asynchronously" do
      output = start(open_port: false)

      send(
        output,
        {:midi, :error, %{device: 0, op: :open_virtual, reason: :no_such_device, dropped: 0}}
      )

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
    test "hot-plug re-lists devices, opens new ones and closes removed ones" do
      output = start()
      send(output, {:midi, :device_added, nil})
      assert_receive :list_devices

      send(output, {:midi, :devices, JSON.encode!([device_entry(7, "usb", name: "Volca Keys")])})
      assert_receive {:open, 7}
      send(output, {:midi, :opened, %{device: 7, port: 0, direction: :output, handle: 7}})
      assert %{available: true, detail: "Volca Keys"} = row(output, :usb)

      send(output, {:midi, :device_removed, nil})
      assert_receive :list_devices
      send(output, {:midi, :devices, JSON.encode!([])})
      assert %{available: false, detail: "nothing plugged in"} = row(output, :usb)
      assert_receive {:close, 7}
    end

    test "ignores devices it can't send to, its own port and other apps' virtual devices" do
      output = start()

      devices = [
        device_entry(1, "usb", input_ports: 1, output_ports: 0),
        device_entry(2, "virtual", own: true),
        device_entry(3, "virtual", name: "FMutate A")
      ]

      send(output, {:midi, :devices, JSON.encode!(devices)})
      assert %{available: false} = row(output, :usb)
      refute_receive {:open, _}
    end

    @tag :capture_log
    test "a device that fails to open is shown and not sent to" do
      output = start()
      plug(output, 7, "usb", name: "Volca Keys", opened: false)

      send(
        output,
        {:midi, :error, %{device: 7, op: :open_output, reason: :open_failed, dropped: 0}}
      )

      assert %{available: false, detail: "Volca Keys · can't open"} = row(output, :usb)
      Output.send_events([{:note_on, 60, 100}], output)
      refute_receive {:device, 7, _}
    end

    test "an own_device open_output error drops the device from external rows" do
      output = start()
      plug(output, 7, "usb", name: "Humdinger", opened: false)

      send(
        output,
        {:midi, :error, %{device: 7, op: :open_output, reason: :own_device, dropped: 0}}
      )

      assert %{available: false, detail: "nothing plugged in"} = row(output, :usb)
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

      send(output, {:midi, :bluetooth_scan, :started})
      found = %{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue", rssi: -60}
      send(output, {:midi, :bluetooth_device, found})
      send(output, {:midi, :bluetooth_device, found})
      send(output, {:midi, :bluetooth_scan, :stopped})

      assert %{scanning: false, found: [%{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}]} =
               Output.bluetooth(output)

      assert :ok = Output.connect_bluetooth("AA:BB:CC:DD:EE:FF", output)
      assert_receive {:connect, "AA:BB:CC:DD:EE:FF"}
      assert row(output, :bt).detail == "connecting…"

      send(output, {:midi, :connected, %{device: 12, address: "AA:BB:CC:DD:EE:FF"}})
      assert_receive :list_devices
      plug(output, 12, "bluetooth", name: "Minilogue", address: "AA:BB:CC:DD:EE:FF")

      assert_receive {:remember, %{address: "AA:BB:CC:DD:EE:FF", name: "Minilogue"}}
      assert_receive {:open, 12}
      assert %{available: true, detail: "Minilogue"} = row(output, :bt)

      Output.send_events([{:note_on, 60, 100}], output)
      assert_receive {:device, 12, <<0x90, 60, 100>>}

      # Forgetting releases notes and closes the device (which disconnects BLE).
      Output.forget_bluetooth(output)
      assert_receive {:device, 12, <<0x80, 60, 64>>}
      assert_receive {:close, 12}
      assert_receive {:remember, nil}
      assert %{available: false, detail: "none paired"} = row(output, :bt)

      # A connection that completes after it was forgotten is closed at once.
      send(output, {:midi, :connected, %{device: 12, address: "AA:BB:CC:DD:EE:FF"}})
      assert_receive {:close, 12}
      assert Output.bluetooth(output).paired == nil
    end

    test "scan errors end the scan and record the reason" do
      output = start()
      assert :ok = Output.scan_bluetooth(output)

      send(
        output,
        {:midi, :error, %{device: 0, op: :scan_bluetooth, reason: :permission_denied, dropped: 0}}
      )

      assert %{scanning: false, error: :permission_denied} = Output.bluetooth(output)
    end

    test "reconnects the remembered device at start and can forget it" do
      output = start(device: PairedDevice)
      assert_receive {:connect, "AA:BB:CC:DD:EE:FF"}

      send(
        output,
        {:midi, :error, %{device: 0, op: :connect_bluetooth, reason: :open_failed, dropped: 0}}
      )

      assert row(output, :bt).detail == "Minilogue · not connected"
      assert Output.bluetooth(output).error == :open_failed

      Output.forget_bluetooth(output)
      assert_receive {:remember, nil}
      assert row(output, :bt).detail == "none paired"
    end

    test "an earlier connect failing doesn't cancel the device chosen since" do
      output = start()
      assert :ok = Output.connect_bluetooth("AA:AA:AA:AA:AA:AA", output)
      assert_receive {:connect, "AA:AA:AA:AA:AA:AA"}
      assert :ok = Output.connect_bluetooth("BB:BB:BB:BB:BB:BB", output)
      assert_receive {:connect, "BB:BB:BB:BB:BB:BB"}

      # mob_midi's connect errors carry no address: this one is the first's.
      send(
        output,
        {:midi, :error, %{device: 0, op: :connect_bluetooth, reason: :open_failed, dropped: 0}}
      )

      assert row(output, :bt).detail == "connecting…"
      assert %{error: nil, connecting: "BB:BB:BB:BB:BB:BB"} = Output.bluetooth(output)

      send(output, {:midi, :connected, %{device: 13, address: "BB:BB:BB:BB:BB:BB"}})
      assert_receive :list_devices
      assert Output.bluetooth(output).paired.address == "BB:BB:BB:BB:BB:BB"
      refute_received {:close, 13}

      # The first one connecting after all is closed: it was replaced.
      send(output, {:midi, :connected, %{device: 12, address: "AA:AA:AA:AA:AA:AA"}})
      assert_receive {:close, 12}
      assert Output.bluetooth(output).paired.address == "BB:BB:BB:BB:BB:BB"
    end

    test "turning Bluetooth MIDI off and on again reconnects the remembered device" do
      address = "AA:BB:CC:DD:EE:FF"
      output = start(device: PairedDevice)
      assert_receive {:connect, ^address}
      send(output, {:midi, :connected, %{device: 12, address: address}})
      assert_receive :list_devices
      plug(output, 12, "bluetooth", name: "Minilogue", address: address)
      assert_receive {:open, 12}

      # Closing disconnects it in mob_midi.
      Output.set_enabled(:bt, false, output)
      assert_receive {:close, 12}

      Output.set_enabled(:bt, true, output)
      assert_receive {:connect, ^address}
      refute_received {:open, 12}
      assert row(output, :bt).detail == "connecting…"
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

  defp flush_devices do
    receive do
      {:device, _, _} -> flush_devices()
    after
      50 -> :ok
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
