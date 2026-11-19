defmodule Humdinger.Output.Port do
  @moduledoc """
  The Humdinger port: a virtual MIDI device named "Humdinger" with one output
  port, which any app on the phone can pick as a MIDI source.

  Backed by `mob_midi` (`MobMidi.open_virtual/2`, `send_raw/3`, `discard/1`):
  on Android the app declares `io.mob.midi.MobMidiDeviceService` with
  `res/xml/mob_midi_device.xml` (`mix mob_midi.gen.virtual_device`). Opening
  subscribes the calling process to `{:midi, :opened, %{device: id,
  direction: :virtual, name: "Humdinger"}}`, `{:midi, :virtual_status,
  %{device: id, senders: _, listeners: n}}`, `{:midi, :drained, %{device: id,
  port: 0, handle: _, generation: g}}` and `{:midi, :error, %{op:
  :open_virtual, ...}}`. On the host these answer `{:error, :unsupported}`.
  """

  @name "Humdinger"

  @doc "The declared virtual MIDI device name."
  @spec name() :: String.t()
  def name, do: @name

  @doc "Subscribes the calling process to the virtual MIDI device."
  @spec open(String.t()) :: :ok | {:error, atom()}
  def open(name \\ @name) when is_binary(name), do: result(MobMidi.open_virtual(nil, name))

  @doc """
  Sends MIDI bytes (whole messages) to the apps listening to `device_id`.
  `{:error, :no_listener}` means nobody is listening; `{:error, :queue_full}`
  means the port's queue filled and refuses sends until `{:midi, :drained,
  ...}` arrives.
  """
  @spec send(MobMidi.device_id(), binary()) :: :ok | {:error, atom()}
  def send(device_id, bytes) when is_integer(device_id) and is_binary(bytes),
    do: result(MobMidi.send_raw(nil, device_id, bytes))

  @doc """
  Drops queued bytes for `device_id` and starts a new queue generation
  (`{:ok, generation}`), which the next `{:midi, :drained, ...}` carries.
  """
  @spec discard(MobMidi.device_id()) :: {:ok, pos_integer()} | {:error, atom()}
  def discard(device_id) when is_integer(device_id), do: MobMidi.discard(device_id)

  # MobMidi returns the socket it was given (nil here) on success.
  defp result(nil), do: :ok
  defp result({:error, _} = error), do: error
end
