defmodule Humdinger.Output.Device do
  @moduledoc """
  External MIDI devices: USB-MIDI and Bluetooth-MIDI synths.

  Opening a device and sending to it goes through `mob_midi` (`MobMidi`). What
  mob_midi 0.2.0 doesn't do on Android comes from the `humdinger_midi_port`
  plugin (`HumdingerMidiBridge.kt`):

  * the device list with each device's transport (`:usb`, `:bluetooth`,
    `:virtual`): mob_midi's list has no transport, and the Output board
    keeps USB and Bluetooth apart;
  * hot-plug: mob_midi's Android side sends no `:device_added` /
    `:device_removed` events, so the plugin's `MidiManager.DeviceCallback`
    does;
  * Bluetooth-MIDI as a central: a BLE scan for the BLE-MIDI service and
    `MidiManager.openBluetoothDevice/3`. (`MobMidi.Ble` is the other role,
    the phone advertising itself as a BLE-MIDI peripheral.) While the opened
    device stays open, it is a MIDI device like a USB one.

  The plugin's events go to the process that called `subscribe/0` (one
  process: `Humdinger.Output`), as `{:humdinger_midi, tag, json}`; mob_midi's
  replies to `open/1` go to the caller as `{:midi, :opened, %{device: id}}`
  or `{:midi, :error, %{device: id, op: :open_output, reason: reason}}`.

  Only Android has the plugin: elsewhere these answer `{:error,
  :unavailable}` and there are no devices.
  """

  @type id :: integer()
  @type t :: %{
          id: id(),
          name: String.t(),
          type: :usb | :bluetooth | :virtual,
          inputs: non_neg_integer(),
          outputs: non_neg_integer(),
          own: boolean(),
          address: String.t()
        }

  @remembered_key {__MODULE__, :bluetooth}

  @doc """
  Sends the plugin's events (port connections, devices added and removed,
  Bluetooth scan results) to the calling process from now on.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: :humdinger_midi_port_nif.subscribe()

  @doc "The MIDI devices Android knows about now."
  @spec list() :: {:ok, [t()]} | {:error, term()}
  def list do
    with json when is_binary(json) <- :humdinger_midi_port_nif.devices(),
         {:ok, list} when is_list(list) <- JSON.decode(json) do
      {:ok, Enum.map(list, &from_json/1)}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_reply}
    end
  end

  @doc "A device from the plugin's JSON object."
  @spec from_json(map()) :: t()
  def from_json(map) do
    %{
      id: map["id"],
      name: map["name"] || "MIDI device",
      type: type(map["type"]),
      inputs: map["inputs"] || 0,
      outputs: map["outputs"] || 0,
      own: map["own"] == true,
      address: map["address"] || ""
    }
  end

  defp type("usb"), do: :usb
  defp type("bluetooth"), do: :bluetooth
  defp type(_), do: :virtual

  @doc "True when Humdinger can send to the device (it has an input port)."
  @spec writable?(t()) :: boolean()
  def writable?(device), do: device.inputs > 0

  @doc "Opens the device's input port 0 for sending (mob_midi; replies to the caller)."
  @spec open(id()) :: :ok | {:error, term()}
  def open(id), do: result(MobMidi.open_output(nil, id))

  @doc "Closes what `open/1` opened."
  @spec close(id()) :: :ok | {:error, term()}
  def close(id), do: result(MobMidi.close(nil, id))

  @doc "Sends one MIDI message to an opened (or still opening) device."
  @spec send(id(), binary()) :: :ok | {:error, term()}
  def send(id, bytes), do: result(MobMidi.send_raw(nil, id, bytes))

  # MobMidi returns the socket it was given (nil here) on success.
  defp result(nil), do: :ok
  defp result({:error, _} = error), do: error

  @doc """
  Scans `ms` milliseconds for Bluetooth-MIDI devices. Each one found arrives
  as `{:humdinger_midi, :ble_found, json}` (address, name, rssi), the end as
  `:ble_scan_done`. Errors: `:no_permission` (request the `:midi_bluetooth`
  capability with `Mob.Permissions.request/2`), `:bluetooth_off`,
  `:location_off` (Android 11 and older find nothing without it),
  `:no_bluetooth`.
  """
  @spec scan(pos_integer()) :: :ok | {:error, atom()}
  def scan(ms), do: :humdinger_midi_port_nif.ble_scan(ms)

  @doc "Ends a scan early."
  @spec stop_scan() :: :ok | {:error, term()}
  def stop_scan, do: :humdinger_midi_port_nif.ble_stop_scan()

  @doc """
  Connects a Bluetooth-MIDI device by address. The outcome arrives as
  `{:humdinger_midi, :ble_connected, json}` (address, id, name) or
  `:ble_failed` (address, reason).
  """
  @spec connect(String.t()) :: :ok | {:error, atom()}
  def connect(address), do: :humdinger_midi_port_nif.ble_connect(address)

  @doc "Disconnects a device `connect/1` connected."
  @spec disconnect(String.t()) :: :ok | {:error, term()}
  def disconnect(address), do: :humdinger_midi_port_nif.ble_disconnect(address)

  @doc "The Bluetooth-MIDI device last connected (`%{address, name}`), if any."
  @spec recall() :: %{address: String.t(), name: String.t()} | nil
  def recall, do: Mob.State.get(@remembered_key)

  @doc "Remembers (or, with nil, forgets) the Bluetooth-MIDI device."
  @spec remember(%{address: String.t(), name: String.t()} | nil) :: :ok
  def remember(nil), do: Mob.State.delete(@remembered_key)
  def remember(device), do: Mob.State.put(@remembered_key, device)
end
