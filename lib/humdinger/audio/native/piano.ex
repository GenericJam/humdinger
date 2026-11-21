defmodule Humdinger.Audio.Native.Piano do
  @moduledoc """
  A sampled-piano preview's stream: one process per `play_piano/2`, which
  owns the `mob_audio_io` output stream on the `"hum_piano"` processor (the
  phrase `Humdinger.Audio.Nif.piano_prepare/2` set up) and tells the player
  where it is:

      {:hum_audio, ref, {:piano_position, ms}}  # what has been heard, ≤ 30 Hz, never backwards
      {:hum_audio, ref, :piano_finished}        # its end has been heard
      {:hum_audio, ref, {:piano_error, reason}} # :device_lost, :output_error, or the NIF's

  The position comes from `Humdinger.Audio.Nif.piano_position/0`, read every
  34 ms (sooner when the end is nearer). The stream closes and the process
  exits on any of those three endings, on `close/1`, and when the player
  exits. Registered under its module name: one preview at a time.
  """

  use GenServer

  require Logger

  alias Humdinger.Audio.Native

  @processor "hum_piano"
  @tick_ms 34

  @doc """
  Open the stream for `owner`'s preview `ref` (prepared already) and start
  reporting. `{:ok, pid}` or `{:error, reason}`: `:owner_dead`,
  `:output_unavailable`, or the plugin's own error.
  """
  @spec start(pid(), reference()) :: {:ok, pid()} | {:error, term()}
  def start(owner, ref) do
    case GenServer.start(__MODULE__, {owner, ref}, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, {:already_started, _}} -> {:error, :output_unavailable}
    end
  end

  @doc "Close the current preview's stream, whatever its reference. `:ok`."
  @spec close() :: :ok
  def close do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> call(pid, :close)
    end
  end

  @doc "Close the stream if `ref` is the current preview's: nothing for `ref` arrives after. `:ok`."
  @spec close(reference()) :: :ok
  def close(ref) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> call(pid, {:close, ref})
    end
  end

  # The process may end between whereis and the call: it has closed then.
  defp call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> :ok
  end

  @impl GenServer
  def init({owner, ref}) do
    if Process.alive?(owner) do
      monitor = Process.monitor(owner)

      case MobAudioIo.open(self(), :output,
             processor: @processor,
             module: Humdinger.Audio.Nif,
             channels: 1
           ) do
        {:ok, stream} ->
          send(self(), :tick)
          {:ok, %{owner: owner, ref: ref, monitor: monitor, stream: stream, sent_ms: nil}}

        {:error, :unsupported} ->
          {:stop, {:shutdown, :unsupported}}

        {:error, reason} ->
          Logger.warning("[hum_audio] piano output refused: #{inspect(reason)}")
          {:stop, {:shutdown, :output_unavailable}}
      end
    else
      {:stop, {:shutdown, :owner_dead}}
    end
  end

  @impl GenServer
  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, finish(state)}

  def handle_call({:close, ref}, _from, %{ref: ref} = state),
    do: {:stop, :normal, :ok, finish(state)}

  def handle_call({:close, _stale}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info(:tick, state) do
    case Native.nif().piano_position() do
      {:playing, ms, finish_in} ->
        Process.send_after(self(), :tick, next_tick(finish_in))
        {:noreply, position(state, ms)}

      {:finished, ms} ->
        state = position(state, ms)
        send(state.owner, {:hum_audio, state.ref, :piano_finished})
        {:stop, :normal, finish(state)}

      {:failed, reason} ->
        stop_with_error(state, reason)

      # Opened, yet nothing armed: the phrase was gone.
      :idle ->
        stop_with_error(state, :output_unavailable)
    end
  end

  def handle_info({:mob_audio_io, :device_lost, stream, _}, %{stream: stream} = state),
    do: stop_with_error(state, :device_lost)

  def handle_info({:mob_audio_io, :error, stream, _}, %{stream: stream} = state),
    do: stop_with_error(state, :output_error)

  # :started, :stopped, :xrun, :interrupted, :resumed, :route_changed: the
  # plugin logs them and reopens what needs it.
  def handle_info({:mob_audio_io, _kind, _stream, _payload}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, finish(state)}

  defp next_tick(nil), do: @tick_ms
  defp next_tick(finish_in), do: finish_in |> ceil() |> max(1) |> min(@tick_ms)

  # The first position goes out whatever it is; then only a later one.
  defp position(%{sent_ms: sent} = state, ms) when sent == nil or ms > sent do
    send(state.owner, {:hum_audio, state.ref, {:piano_position, ms}})
    %{state | sent_ms: ms}
  end

  defp position(state, _ms), do: state

  defp stop_with_error(state, reason) do
    Logger.warning("[hum_audio] piano preview ended: #{inspect(reason)}")
    state = finish(state)
    send(state.owner, {:hum_audio, state.ref, {:piano_error, reason}})
    {:stop, :normal, state}
  end

  defp finish(%{stream: nil} = state), do: state

  defp finish(state) do
    _ = MobAudioIo.close(state.stream)
    %{state | stream: nil}
  end
end
