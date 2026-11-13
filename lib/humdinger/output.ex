defmodule Humdinger.Output do
  @moduledoc """
  Where the MIDI goes. A long-lived GenServer (started from `App.on_start`)
  that takes the Tracker's events, encodes them once on the configured
  channel (`Humdinger.Midi`) and sends them to every destination that is both
  enabled and available:

  | id | name | sends with |
  |---|---|---|
  | `:fmutate` | FMutate | `Humdinger.FMutate.send_midi/1` (Erlang distribution) |
  | `:port` | Humdinger port | `Humdinger.Output.Port` (a virtual MIDI device) |
  | `:usb` | USB MIDI out | `Humdinger.Output.Device`, every USB device plugged in |
  | `:bt` | Bluetooth MIDI | `Humdinger.Output.Device`, the connected BLE-MIDI device |

  Output keeps, per destination, the notes it left sounding (as `{channel,
  note}`), so turning a destination off sends it exactly the note-offs it
  needs, `panic/0` silences everything (those note-offs plus CC 123 on each
  channel used), and a channel change can't strand a note on the old one.

  Settings: the channel and the enabled flags are read once at start from
  `Humdinger.Settings.load/0`; the Engine sends channel changes with
  `configure/1` (after the note-offs for the old channel, which the cast
  order keeps first). `set_enabled/2` saves the flags with
  `Humdinger.Settings.update/1`. Without a Settings module (a branch that
  lacks it) the defaults are channel 1, FMutate and port on, USB and
  Bluetooth off.

  Subscribers (`subscribe/1`, monitored) get:

  * `{:output, :destinations, list}` when they subscribe and whenever the
    list changes (see `destinations/0`);
  * `{:output, :sent, summary}`, e.g. `"A4 on · vel 92 · ch 1"`, for what
    was sent, at most every 100 ms (the latest one wins);
  * `{:output, :bluetooth, view}` when the Bluetooth scan or connection
    changes (see `bluetooth/0`).

  The modules it talks to are options, so tests run it against doubles:
  `:fmutate` (default `Application.get_env(:humdinger, :fmutate,
  Humdinger.FMutate)`: `status/0`, `subscribe/1`, `send_midi/1`),
  `:settings` (default `Application.get_env(:humdinger, :settings,
  Humdinger.Settings)`: `load/0`, `update/1`), `:port` (default
  `Humdinger.Output.Port`) and `:device` (default `Humdinger.Output.Device`).
  A module that isn't loaded is left out.
  """

  use GenServer
  require Logger

  alias Humdinger.Midi
  alias Humdinger.Output.{Device, Port}

  @ids [:fmutate, :port, :usb, :bt]
  @default_enabled %{fmutate: true, port: true, usb: false, bt: false}
  @test_note {:note_on, 69, 92}
  @test_note_ms 300
  @scan_ms 10_000
  @sent_interval_ms 100
  @fmutate_retry_ms 1_000

  @type id :: :fmutate | :port | :usb | :bt
  @type destination :: %{
          id: id(),
          name: String.t(),
          detail: String.t(),
          enabled: boolean(),
          available: boolean()
        }
  @type bluetooth :: %{
          scanning: boolean(),
          found: [%{address: String.t(), name: String.t(), rssi: integer()}],
          error: atom() | nil,
          connecting: String.t() | nil,
          paired: %{address: String.t(), name: String.t()} | nil
        }

  defstruct [
    :fmutate,
    :settings,
    :port,
    :device,
    :shown,
    :shown_bluetooth,
    :last_sent,
    :sent_at,
    :sent_timer,
    :connecting,
    :paired,
    channel: 1,
    enabled: @default_enabled,
    fmutate_status: :unpaired,
    port_available: false,
    port_connections: 0,
    # id => Device.t(): the USB and Bluetooth devices Humdinger can send to.
    devices: %{},
    # id => :opening | :open | {:failed, reason}: outputs asked of mob_midi.
    opened: %{},
    sounding: Map.new(@ids, &{&1, MapSet.new()}),
    scanning: false,
    found: [],
    scan_error: nil,
    subscribers: %{},
    sent_interval: @sent_interval_ms
  ]

  # ── API ──────────────────────────────────────────────────────────────────

  @doc """
  Starts Output. Options: `:name` (default `Humdinger.Output`; nil for none),
  `:fmutate`, `:settings`, `:port`, `:device` (see the moduledoc),
  `:sent_interval_ms` (default 100).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # Like Task: test doubles called from Output find their test via $callers.
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, {opts, callers}, if(name, do: [name: name], else: []))
  end

  @doc "Sends events (in order) on the configured channel to every enabled, available destination."
  @spec send_events([Midi.event()], GenServer.server()) :: :ok
  def send_events(events, server \\ __MODULE__) when is_list(events),
    do: GenServer.cast(server, {:send_events, events})

  @doc "Changes the channel (`channel: 1..16`). Notes still sounding keep their own channel."
  @spec configure(keyword() | map(), GenServer.server()) :: :ok
  def configure(opts, server \\ __MODULE__),
    do: GenServer.cast(server, {:configure, Map.new(opts)})

  @doc """
  The Output board's rows, in order: FMutate, Humdinger port, USB MIDI out,
  Bluetooth MIDI, each `%{id, name, detail, enabled, available}`.
  """
  @spec destinations(GenServer.server()) :: [destination()]
  def destinations(server \\ __MODULE__), do: GenServer.call(server, :destinations)

  @doc """
  Turns a destination on or off and saves it. Turning one off first sends it
  the note-offs for the notes it has sounding.
  """
  @spec set_enabled(id(), boolean(), GenServer.server()) :: :ok
  def set_enabled(id, enabled, server \\ __MODULE__) when id in @ids and is_boolean(enabled),
    do: GenServer.call(server, {:set_enabled, id, enabled})

  @doc "Plays A4 at velocity 92 for 300 ms on every enabled, available destination."
  @spec test_note(GenServer.server()) :: :ok
  def test_note(server \\ __MODULE__), do: GenServer.cast(server, :test_note)

  @doc """
  Silences every enabled, available destination: note-offs for the notes Output knows
  are sounding, then CC 123 (All Notes Off) on each channel they use and on
  the current one.
  """
  @spec panic(GenServer.server()) :: :ok
  def panic(server \\ __MODULE__), do: GenServer.call(server, :panic)

  @doc "The line for the last event sent anywhere, or nil."
  @spec last_sent(GenServer.server()) :: String.t() | nil
  def last_sent(server \\ __MODULE__), do: GenServer.call(server, :last_sent)

  @doc "Sends Output's messages to `pid` until it exits (see the moduledoc)."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid, server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:subscribe, pid})

  @doc """
  The Bluetooth-MIDI state for the Output screen: `scanning`, devices `found`
  by the last scan, the last `error`, the address `connecting`, and the
  `paired` device (the last one connected, remembered across launches).
  """
  @spec bluetooth(GenServer.server()) :: bluetooth()
  def bluetooth(server \\ __MODULE__), do: GenServer.call(server, :bluetooth)

  @doc """
  Scans 10 s for Bluetooth-MIDI devices ("Scan Bluetooth"). Errors are the
  `Humdinger.Output.Device.scan/1` ones; on `:no_permission`, request the
  `:midi_bluetooth` capability with `Mob.Permissions.request/2` and retry.
  """
  @spec scan_bluetooth(GenServer.server()) :: :ok | {:error, atom()}
  def scan_bluetooth(server \\ __MODULE__), do: GenServer.call(server, :scan_bluetooth)

  @doc "Ends a Bluetooth scan early."
  @spec stop_bluetooth_scan(GenServer.server()) :: :ok
  def stop_bluetooth_scan(server \\ __MODULE__), do: GenServer.call(server, :stop_bluetooth_scan)

  @doc "Connects a Bluetooth-MIDI device found by the scan, by address."
  @spec connect_bluetooth(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def connect_bluetooth(address, server \\ __MODULE__) when is_binary(address),
    do: GenServer.call(server, {:connect_bluetooth, address})

  @doc "Disconnects and forgets the paired Bluetooth-MIDI device."
  @spec forget_bluetooth(GenServer.server()) :: :ok
  def forget_bluetooth(server \\ __MODULE__), do: GenServer.call(server, :forget_bluetooth)

  # ── Server ───────────────────────────────────────────────────────────────

  @impl GenServer
  def init({opts, callers}) do
    Process.put(:"$callers", callers)

    state =
      load_settings(%__MODULE__{
        fmutate: module_opt(opts, :fmutate, Humdinger.FMutate),
        settings: module_opt(opts, :settings, Humdinger.Settings),
        port: Keyword.get(opts, :port, Port),
        device: Keyword.get(opts, :device, Device),
        sent_interval: Keyword.get(opts, :sent_interval_ms, @sent_interval_ms)
      })

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    state = link_fmutate(state)
    _ = state.device.subscribe()

    devices =
      case state.device.list() do
        {:ok, list} -> list
        {:error, _} -> []
      end

    state =
      %{
        state
        | port_available: state.port.available?(),
          port_connections: state.port.connections(),
          paired: state.device.recall()
      }
      |> add_devices(devices)
      |> sync_devices()
      |> reconnect_bluetooth()

    {:noreply, %{state | shown: destination_list(state), shown_bluetooth: bluetooth_view(state)}}
  end

  @impl GenServer
  def handle_cast({:send_events, events}, state) do
    {:noreply, state |> deliver_events(events, state.channel) |> changed()}
  end

  def handle_cast({:configure, %{channel: channel}}, state) when is_integer(channel),
    do: {:noreply, %{state | channel: Midi.channel(channel)}}

  def handle_cast({:configure, _}, state), do: {:noreply, state}

  def handle_cast(:test_note, state) do
    Process.send_after(self(), {:test_note_off, state.channel}, @test_note_ms)
    {:noreply, state |> deliver_events([@test_note], state.channel) |> changed()}
  end

  @impl GenServer
  def handle_call(:destinations, _from, state), do: {:reply, destination_list(state), state}
  def handle_call(:last_sent, _from, state), do: {:reply, state.last_sent, state}
  def handle_call(:bluetooth, _from, state), do: {:reply, bluetooth_view(state), state}

  def handle_call({:set_enabled, id, enabled}, _from, state) do
    state =
      if state.enabled[id] == enabled do
        state
      else
        persist_enabled(state, id, enabled)
        toggle(state, id, enabled)
      end

    {:reply, :ok, changed(state)}
  end

  def handle_call(:panic, _from, state), do: {:reply, :ok, state |> panic_all() |> changed()}

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
      end

    send(pid, {:output, :destinations, destination_list(state)})
    {:reply, :ok, state}
  end

  def handle_call(:scan_bluetooth, _from, state) do
    case state.device.scan(@scan_ms) do
      :ok ->
        {:reply, :ok, changed(%{state | scanning: true, found: [], scan_error: nil})}

      {:error, reason} = error ->
        {:reply, error, changed(%{state | scan_error: reason})}
    end
  end

  def handle_call(:stop_bluetooth_scan, _from, state) do
    _ = state.device.stop_scan()
    {:reply, :ok, state}
  end

  def handle_call({:connect_bluetooth, address}, _from, state) do
    case state.device.connect(address) do
      :ok -> {:reply, :ok, changed(%{state | connecting: address, scan_error: nil})}
      {:error, reason} = error -> {:reply, error, changed(%{state | scan_error: reason})}
    end
  end

  def handle_call(:forget_bluetooth, _from, state) do
    if state.paired, do: state.device.disconnect(state.paired.address)
    state.device.remember(nil)
    {:reply, :ok, changed(%{state | paired: nil, connecting: nil})}
  end

  @impl GenServer
  def handle_info({:test_note_off, channel}, state) do
    {:note_on, note, _} = @test_note
    {:noreply, state |> deliver_events([{:note_off, note}], channel) |> changed()}
  end

  def handle_info(:flush_sent, state) do
    broadcast(state, {:output, :sent, state.last_sent})
    {:noreply, %{state | sent_at: now(), sent_timer: nil}}
  end

  def handle_info(:link_fmutate, state), do: {:noreply, state |> link_fmutate() |> changed()}

  def handle_info({:fmutate, :status, status}, state),
    do: {:noreply, %{state | fmutate_status: status} |> prune_sounding() |> changed()}

  def handle_info({:humdinger_midi, tag, json}, state) do
    case JSON.decode(json) do
      {:ok, payload} -> {:noreply, state |> native_event(tag, payload) |> changed()}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({:midi, :opened, %{device: id}}, state) do
    opened =
      if Map.has_key?(state.opened, id), do: Map.put(state.opened, id, :open), else: state.opened

    {:noreply, changed(%{state | opened: opened})}
  end

  def handle_info({:midi, :error, %{device: id, op: :open_output, reason: reason}}, state) do
    if Map.has_key?(state.opened, id) and reason != :closed do
      Logger.warning("[output] MIDI device #{id} didn't open: #{inspect(reason)}")
      opened = Map.put(state.opened, id, {:failed, reason})
      {:noreply, %{state | opened: opened} |> prune_sounding() |> changed()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:midi, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  # ── Sending ──────────────────────────────────────────────────────────────

  defp deliver_events(state, [], _channel), do: state

  defp deliver_events(state, events, channel) do
    case targets(state) do
      [] ->
        state

      targets ->
        state = Enum.reduce(events, state, &deliver(&2, targets, &1, channel))
        note_sent(state, Midi.describe(List.last(events), channel))
    end
  end

  defp deliver(state, targets, event, channel) do
    bytes = Midi.encode(event, channel)
    Enum.each(targets, &write(state, &1, bytes))

    sounding =
      Enum.reduce(targets, state.sounding, fn id, sounding ->
        Map.update!(sounding, id, &track(&1, bytes, channel))
      end)

    %{state | sounding: sounding}
  end

  # The note is read back from the bytes, so it is the clamped one.
  defp track(set, <<status, note, _>>, channel) when status in 0x90..0x9F,
    do: MapSet.put(set, {channel, note})

  defp track(set, <<status, note, _>>, channel) when status in 0x80..0x8F,
    do: MapSet.delete(set, {channel, note})

  defp track(set, _bytes, _channel), do: set

  defp write(state, :fmutate, bytes), do: state.fmutate.send_midi(bytes)
  defp write(state, :port, bytes), do: state.port.send(bytes)

  defp write(state, id, bytes) do
    for device_id <- sendable_devices(state, id), do: state.device.send(device_id, bytes)
  end

  defp targets(state), do: Enum.filter(@ids, &(state.enabled[&1] and available?(state, &1)))

  defp note_sent(state, summary) do
    state = %{state | last_sent: summary}
    now = now()

    cond do
      state.sent_timer ->
        state

      is_nil(state.sent_at) or now - state.sent_at >= state.sent_interval ->
        broadcast(state, {:output, :sent, summary})
        %{state | sent_at: now}

      true ->
        delay = state.sent_at + state.sent_interval - now
        %{state | sent_timer: Process.send_after(self(), :flush_sent, delay)}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Note-offs for what `id` has sounding (when it can still be reached).
  defp release(state, id) do
    if available?(state, id) do
      for {channel, note} <- state.sounding[id],
          do: write(state, id, Midi.encode({:note_off, note}, channel))
    end

    put_in(state.sounding[id], MapSet.new())
  end

  defp panic_all(state) do
    for id <- targets(state) do
      state.sounding[id]
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.put_new(state.channel, [])
      |> Enum.flat_map(fn {channel, notes} -> Midi.all_notes_off(channel, notes) end)
      |> Enum.each(&write(state, id, &1))
    end

    %{state | sounding: Map.new(@ids, &{&1, MapSet.new()})}
  end

  defp toggle(state, id, false) do
    state
    |> release(id)
    |> Map.update!(:enabled, &Map.put(&1, id, false))
    |> sync_devices()
  end

  defp toggle(state, id, true) do
    state = state |> Map.update!(:enabled, &Map.put(&1, id, true)) |> sync_devices()
    if id == :bt, do: reconnect_bluetooth(state), else: state
  end

  # A destination that can't be reached has nothing sounding any more.
  defp prune_sounding(state) do
    sounding =
      Map.new(state.sounding, fn {id, set} ->
        {id, if(available?(state, id), do: set, else: MapSet.new())}
      end)

    %{state | sounding: sounding}
  end

  # ── Availability and the board's rows ─────────────────────────────────────

  defp available?(state, :fmutate), do: match?({:connected, _}, state.fmutate_status)
  defp available?(state, :port), do: state.port_available
  defp available?(state, id), do: sendable_devices(state, id) != []

  defp devices_for(state, id) do
    for {_, device} <- state.devices, destination(device) == id, do: device
  end

  defp sendable_devices(state, id) do
    for device <- devices_for(state, id), not match?({:failed, _}, state.opened[device.id]) do
      device.id
    end
  end

  defp destination(%{type: :usb}), do: :usb
  defp destination(%{type: :bluetooth}), do: :bt

  defp destination_list(state) do
    for id <- @ids do
      %{
        id: id,
        name: name(state, id),
        detail: detail(state, id),
        enabled: state.enabled[id],
        available: available?(state, id)
      }
    end
  end

  defp name(state, :fmutate) do
    case state.fmutate_status do
      {:connected, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> "FMutate"
    end
  end

  defp name(_state, :port), do: "Humdinger port"
  defp name(_state, :usb), do: "USB MIDI out"
  defp name(_state, :bt), do: "Bluetooth MIDI"

  defp detail(state, :fmutate) do
    case state.fmutate_status do
      {:connected, info} -> Enum.join(["sibling app", "connected" | firmware(info)], " · ")
      :disconnected -> "sibling app · not connected"
      _ -> "sibling app · not paired"
    end
  end

  defp detail(%{port_available: false}, :port), do: "virtual MIDI · not on this phone"
  defp detail(%{port_connections: 0}, :port), do: "virtual MIDI · any app can pick it"
  defp detail(%{port_connections: 1}, :port), do: "virtual MIDI · 1 app listening"
  defp detail(%{port_connections: n}, :port), do: "virtual MIDI · #{n} apps listening"

  defp detail(state, :usb) do
    case devices_for(state, :usb) do
      [] -> "nothing plugged in"
      devices -> Enum.map_join(devices, ", ", &device_label(state, &1))
    end
  end

  defp detail(state, :bt) do
    case devices_for(state, :bt) do
      [] -> bluetooth_detail(state)
      devices -> Enum.map_join(devices, ", ", &device_label(state, &1))
    end
  end

  defp bluetooth_detail(%{connecting: address}) when is_binary(address), do: "connecting…"
  defp bluetooth_detail(%{paired: %{name: name}}), do: "#{name} · not connected"
  defp bluetooth_detail(_state), do: "none paired"

  defp firmware(%{firmware: %{name: name}}) when is_binary(name), do: [name]
  defp firmware(%{firmware: name}) when is_binary(name) and name != "", do: [name]
  defp firmware(_), do: []

  defp device_label(state, device) do
    case state.opened[device.id] do
      {:failed, _} -> "#{device.name} · can't open"
      _ -> device.name
    end
  end

  defp bluetooth_view(state) do
    %{
      scanning: state.scanning,
      found: state.found,
      error: state.scan_error,
      connecting: state.connecting,
      paired: state.paired
    }
  end

  # Tells subscribers what changed since they were last told.
  defp changed(state) do
    destinations = destination_list(state)
    bluetooth = bluetooth_view(state)
    if destinations != state.shown, do: broadcast(state, {:output, :destinations, destinations})
    if bluetooth != state.shown_bluetooth, do: broadcast(state, {:output, :bluetooth, bluetooth})
    %{state | shown: destinations, shown_bluetooth: bluetooth}
  end

  defp broadcast(state, message), do: Enum.each(Map.keys(state.subscribers), &send(&1, message))

  # ── Devices and the native plugin's events ───────────────────────────────

  defp add_devices(state, devices) do
    relevant =
      for device <- devices,
          device.type in [:usb, :bluetooth],
          not device.own,
          Device.writable?(device),
          into: %{},
          do: {device.id, device}

    %{state | devices: Map.merge(state.devices, relevant)}
  end

  # Opens outputs for the devices of enabled destinations; closes the rest.
  defp sync_devices(state) do
    wanted = for {id, device} <- state.devices, state.enabled[destination(device)], do: id

    opened =
      Enum.reduce(wanted, state.opened, fn id, opened ->
        if Map.has_key?(opened, id), do: opened, else: Map.put(opened, id, open(state, id))
      end)

    {keep, drop} = Map.split(opened, wanted)
    for id <- Map.keys(drop), do: state.device.close(id)
    %{state | opened: keep}
  end

  defp open(state, id) do
    case state.device.open(id) do
      :ok -> :opening
      {:error, reason} -> {:failed, reason}
    end
  end

  defp native_event(state, :port, %{"connections" => n}) when is_integer(n),
    do: %{state | port_connections: n}

  defp native_event(state, :device_added, payload) when is_map(payload),
    do: state |> add_devices([Device.from_json(payload)]) |> sync_devices()

  defp native_event(state, :device_removed, %{"id" => id}) do
    if Map.has_key?(state.opened, id), do: state.device.close(id)

    %{state | devices: Map.delete(state.devices, id), opened: Map.delete(state.opened, id)}
    |> prune_sounding()
  end

  defp native_event(state, :ble_found, %{"address" => address} = found) do
    if Enum.any?(state.found, &(&1.address == address)) do
      state
    else
      entry = %{address: address, name: found["name"] || "", rssi: found["rssi"] || 0}
      %{state | found: state.found ++ [entry]}
    end
  end

  defp native_event(state, :ble_scan_done, payload),
    do: %{state | scanning: false, scan_error: error_atom(payload["error"]) || state.scan_error}

  defp native_event(state, :ble_connected, %{"address" => address} = payload) do
    paired = %{address: address, name: payload["name"] || address}
    state.device.remember(paired)
    %{state | paired: paired, connecting: nil}
  end

  defp native_event(state, :ble_failed, payload) do
    %{state | connecting: nil, scan_error: error_atom(payload["reason"]) || :connect_failed}
  end

  defp native_event(state, _tag, _payload), do: state

  @errors Map.new(
            ~w(scan_failed no_permission open_failed bluetooth_off location_off no_bluetooth)a,
            &{Atom.to_string(&1), &1}
          )
  defp error_atom(reason), do: Map.get(@errors, reason)

  # Reconnects the remembered Bluetooth device when Bluetooth is on.
  defp reconnect_bluetooth(%{paired: %{address: address}, connecting: nil} = state) do
    if state.enabled.bt and devices_for(state, :bt) == [] and state.device.connect(address) == :ok,
      do: %{state | connecting: address},
      else: state
  end

  defp reconnect_bluetooth(state), do: state

  # ── FMutate and Settings ───────────────────────────────────────────────────

  defp module_opt(opts, key, default) do
    module = Keyword.get_lazy(opts, key, fn -> Application.get_env(:humdinger, key, default) end)
    if Code.ensure_loaded?(module), do: module
  end

  # FMutate may start after Output; retry until it's there.
  defp link_fmutate(%{fmutate: nil} = state), do: state

  defp link_fmutate(%{fmutate: fmutate} = state) do
    fmutate.subscribe(self())
    prune_sounding(%{state | fmutate_status: fmutate.status()})
  catch
    :exit, _ ->
      Process.send_after(self(), :link_fmutate, @fmutate_retry_ms)
      state
  end

  defp load_settings(%{settings: nil} = state), do: state

  defp load_settings(%{settings: settings} = state) do
    loaded = settings.load()
    destinations = Map.get(loaded, :destinations) || %{}

    %{
      state
      | channel: Midi.channel(Map.get(loaded, :channel) || 1),
        enabled: Map.merge(@default_enabled, Map.take(destinations, @ids))
    }
  end

  defp persist_enabled(%{settings: nil}, _id, _enabled), do: :ok

  defp persist_enabled(%{settings: settings}, id, enabled) do
    case settings.update(fn s -> Map.update!(s, :destinations, &Map.put(&1, id, enabled)) end) do
      {:ok, _} -> :ok
      other -> Logger.warning("[output] couldn't save #{id} = #{enabled}: #{inspect(other)}")
    end
  end
end
