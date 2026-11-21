defmodule Humdinger.Audio.Native.Mic do
  @moduledoc """
  The microphone's stream: one process per listening, which owns the
  `mob_audio_io` input stream on the `"hum_mic"` processor and stands
  between it and the listener. `Humdinger.Audio.Native` starts it after
  arming the NIF (`Humdinger.Audio.Nif.listen/3`); the NIF's listen thread
  sends the readings to the listener itself.

  It ends the listening (stops the NIF, closes the stream, exits) when the
  listener exits, when `close/1` asks, and when the stream fails: a lost
  device (`{:mob_audio_io, :device_lost, ...}`) or a reopen that failed
  (`:error`) reach the listener as `{:hum_audio, ref, {:error, :device_lost |
  :input_error}}`, as the microphone's loss always has. iOS interruptions and
  route changes reopen on their own (the plugin's), so listening goes on.

  Registered under its module name: one listening at a time.
  """

  use GenServer

  require Logger

  alias Humdinger.Audio.Native

  @processor "hum_mic"

  @doc """
  Open the stream for `owner`'s listening `ref` and start relaying. `opts`:
  `input` (a device id or nil) and `preset` (a `MobAudioIo` input preset).
  `{:ok, pid}` or `{:error, reason}`: `:permission`, `:owner_dead`,
  `:microphone_unavailable`, or the plugin's own error.
  """
  @spec start(pid(), reference(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(owner, ref, opts) do
    case GenServer.start(__MODULE__, {owner, ref, opts}, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, {:already_started, _}} -> {:error, :microphone_unavailable}
    end
  end

  @doc "Close the current listening's stream, whatever its reference. `:ok`."
  @spec close() :: :ok
  def close do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> call(pid, :close)
    end
  end

  @doc "Close the stream if `ref` is the current listening's. `:ok`."
  @spec close(reference()) :: :ok
  def close(ref) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> call(pid, {:close, ref})
    end
  end

  @doc "The current stream's `MobAudioIo.status/1`, or nil."
  @spec status() :: map() | nil
  def status do
    case GenServer.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        case call(pid, :status) do
          %{} = status -> status
          _ -> nil
        end
    end
  end

  # The process may end between whereis and the call: it has closed then.
  defp call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> :ok
  end

  @impl GenServer
  def init({owner, ref, opts}) do
    if Process.alive?(owner) do
      monitor = Process.monitor(owner)

      case open(Keyword.get(opts, :input), Keyword.fetch!(opts, :preset)) do
        {:ok, stream} ->
          {:ok, %{owner: owner, ref: ref, monitor: monitor, stream: stream}}

        {:error, reason} ->
          {:stop, {:shutdown, reason}}
      end
    else
      {:stop, {:shutdown, :owner_dead}}
    end
  end

  # A chosen input the system won't open (unplugged since it was listed)
  # falls back to the system's default, as the microphone always has.
  defp open(nil, preset), do: open_stream(nil, preset) |> plugin_error()

  defp open(input, preset) do
    case open_stream(input, preset) do
      {:error, {kind, detail}} when kind in [:invalid_device, :unavailable] ->
        Logger.warning(
          "[hum_audio] input #{inspect(input)} unavailable (#{detail}): using the default"
        )

        open_stream(nil, preset) |> plugin_error()

      result ->
        plugin_error(result)
    end
  end

  defp open_stream(input, preset) do
    MobAudioIo.open(self(), :input,
      processor: @processor,
      module: Humdinger.Audio.Nif,
      preset: preset,
      device: input,
      input_channels: 1
    )
  end

  # The platform refusing the microphone is `:microphone_unavailable` to the
  # app, as before; `:permission` stays; anything else (a build without the
  # processor) passes through for the log and the "no microphone" screen.
  defp plugin_error({:ok, _} = ok), do: ok
  defp plugin_error({:error, :permission}), do: {:error, :permission}
  defp plugin_error({:error, reason}) when reason in [:busy, :unsupported], do: unavailable()

  defp plugin_error({:error, {kind, _detail}})
       when kind in [:unavailable, :invalid_device, :session],
       do: unavailable()

  defp plugin_error({:error, _} = error), do: error

  defp unavailable, do: {:error, :microphone_unavailable}

  @impl GenServer
  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, finish(state)}

  def handle_call({:close, ref}, _from, %{ref: ref} = state),
    do: {:stop, :normal, :ok, finish(state)}

  def handle_call({:close, _stale}, _from, state), do: {:reply, :ok, state}

  def handle_call(:status, _from, state), do: {:reply, MobAudioIo.status(state.stream), state}

  @impl GenServer
  def handle_info({:mob_audio_io, :device_lost, stream, _}, %{stream: stream} = state),
    do: lost(state, :device_lost)

  def handle_info({:mob_audio_io, :error, stream, _}, %{stream: stream} = state),
    do: lost(state, :input_error)

  # :started, :stopped, :xrun, :interrupted, :resumed, :route_changed: the
  # plugin logs them and reopens what needs it.
  def handle_info({:mob_audio_io, _kind, _stream, _payload}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, finish(state)}

  @impl GenServer
  def terminate(_reason, %{ref: ref}) do
    # Also after a crash: the listen thread must not outlive its stream.
    Native.nif().stop(ref)
  end

  # The NIF stops first, so the readings it already sent arrive before the
  # error, and none after it.
  defp lost(state, reason) do
    Logger.warning("[hum_audio] microphone lost (#{reason}): listening ended")
    state = finish(state)
    send(state.owner, {:hum_audio, state.ref, {:error, reason}})
    {:stop, :normal, state}
  end

  defp finish(%{stream: nil} = state), do: state

  defp finish(state) do
    Native.nif().stop(state.ref)
    _ = MobAudioIo.close(state.stream)
    %{state | stream: nil}
  end
end
