defmodule Humdinger.Output.Port do
  @moduledoc """
  The Humdinger port: a virtual MIDI device named "Humdinger" with one output
  port, which any app on the phone can pick as a MIDI source.

  On Android it is `HumdingerMidiService`, a `MidiDeviceService` declared in
  the app manifest by the `humdinger_midi_port` plugin. Android lists it while
  the app is installed and binds the service, in the app's process, when an
  app opens the port. `send/1` hands bytes to the port, timestamped now;
  Android fans them out to every app connected to it. With no app connected
  they are dropped.

  The port exists only where the plugin's NIF is linked (Android builds):
  elsewhere `available?/0` is false and `send/1` answers
  `{:error, :unavailable}`.
  """

  @doc "True where the port exists (the native plugin is linked)."
  @spec available?() :: boolean()
  def available?, do: is_integer(:humdinger_midi_port_nif.port_connections())

  @doc """
  Sends MIDI bytes (whole messages) to the apps connected to the port.
  `{:error, :no_client}` means nobody is listening and the bytes were dropped.
  """
  @spec send(binary()) :: :ok | {:error, :no_client | :send_failed | :unavailable | :failed}
  def send(bytes) when is_binary(bytes), do: :humdinger_midi_port_nif.port_send(bytes)

  @doc "How many apps have the port open (0 where it doesn't exist)."
  @spec connections() :: non_neg_integer()
  def connections do
    case :humdinger_midi_port_nif.port_connections() do
      n when is_integer(n) -> n
      {:error, _} -> 0
    end
  end
end
