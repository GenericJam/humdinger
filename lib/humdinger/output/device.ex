defmodule Humdinger.Output.Device do
  @moduledoc """
  External MIDI devices: USB-MIDI and Bluetooth-MIDI synths, backed by
  `mob_midi` (`MobMidi`).

  Every operation passes `nil` as the socket, so replies arrive in the calling
  process (`Humdinger.Output`) as `{:midi, ...}` messages:

  * `list/0` → `{:midi, :devices, payload}` (normalised by `parse/1`) and
    hot-plug `{:midi, :device_added | :device_removed, nil}`;
  * `open/1` → `{:midi, :opened, %{device: id, port: 0, direction: :output, ...}}`
    or `{:midi, :error, %{device: id, op: :open_output, reason: reason, dropped: _}}`;
  * `scan/1` → `{:midi, :bluetooth_scan, :started}`,
    `{:midi, :bluetooth_device, %{address: _, name: _, rssi: _}}`,
    `{:midi, :bluetooth_scan, :stopped}`, or `{:midi, :error, %{op: :scan_bluetooth, ...}}`;
  * `connect/1` → `{:midi, :connected, %{device: id, address: address}}` or
    `{:midi, :error, %{op: :connect_bluetooth, reason: reason, ...}}`.
    `close/1` closes the device's open ports and disconnects Bluetooth.

  On the host (and iOS for BLE-MIDI central), `MobMidi` answers
  `{:error, :unsupported}`.
  """

  @type id :: MobMidi.device_id()
  @type t :: %{
          id: id(),
          name: String.t(),
          direction: :input | :output | :both,
          manufacturer: String.t(),
          type: :usb | :bluetooth | :virtual | :other,
          address: String.t(),
          input_ports: non_neg_integer(),
          output_ports: non_neg_integer(),
          own: boolean()
        }

  @remembered_key {__MODULE__, :bluetooth}

  @doc """
  Requests the current MIDI device list (and subscribes the calling process to
  hot-plug events).
  """
  @spec list() :: :ok | {:error, atom()}
  def list, do: result(MobMidi.list_devices(nil))

  @doc "Normalises a `{:midi, :devices, payload}` payload into device maps."
  @spec parse(list() | binary() | term()) :: [t()]
  def parse(payload), do: MobMidi.parse_devices(payload)

  @doc """
  True when Humdinger can send to the device (it has a writeable port:
  `output_ports > 0`, which is Android's `inputPortCount`).
  """
  @spec writable?(t()) :: boolean()
  def writable?(device), do: device.output_ports > 0

  @doc "Opens port 0 for sending (`{:midi, :opened, ...}` / `{:midi, :error, ...}`)."
  @spec open(id()) :: :ok | {:error, atom()}
  def open(id) when is_integer(id), do: result(MobMidi.open_output(nil, id))

  @doc "Closes open ports on `id` and disconnects a Bluetooth-MIDI device."
  @spec close(id()) :: :ok | {:error, atom()}
  def close(id) when is_integer(id), do: result(MobMidi.close(nil, id))

  @doc "Sends one MIDI message to an opened (or still opening) device."
  @spec send(id(), binary()) :: :ok | {:error, atom()}
  def send(id, bytes) when is_integer(id) and is_binary(bytes),
    do: result(MobMidi.send_raw(nil, id, bytes))

  @doc "Drops queued bytes for `id` and returns `{:ok, generation}`."
  @spec discard(id()) :: {:ok, pos_integer()} | {:error, atom()}
  def discard(id) when is_integer(id), do: MobMidi.discard(id)

  # MobMidi returns the socket it was given (nil here) on success.
  defp result(nil), do: :ok
  defp result({:error, _} = error), do: error

  @doc """
  Scans `ms` milliseconds for Bluetooth-MIDI devices (Android). On
  `:permission_denied`, request the `:midi_bluetooth` capability with
  `Mob.Permissions.request/2`.
  """
  @spec scan(pos_integer()) :: :ok | {:error, atom()}
  def scan(ms) when is_integer(ms) and ms > 0,
    do: result(MobMidi.scan_bluetooth(nil, duration_ms: ms))

  @doc "Ends a Bluetooth-MIDI scan early."
  @spec stop_scan() :: :ok | {:error, atom()}
  def stop_scan, do: result(MobMidi.stop_bluetooth_scan(nil))

  @doc "Connects a Bluetooth-MIDI device by address (Android)."
  @spec connect(String.t()) :: :ok | {:error, atom()}
  def connect(address) when is_binary(address),
    do: result(MobMidi.connect_bluetooth(nil, address))

  @doc "The Bluetooth-MIDI device last connected (`%{address, name}`), if any."
  @spec recall() :: %{address: String.t(), name: String.t()} | nil
  def recall, do: Mob.State.get(@remembered_key)

  @doc "Remembers (or, with nil, forgets) the Bluetooth-MIDI device."
  @spec remember(%{address: String.t(), name: String.t()} | nil) :: :ok
  def remember(nil), do: Mob.State.delete(@remembered_key)
  def remember(device), do: Mob.State.put(@remembered_key, device)
end
