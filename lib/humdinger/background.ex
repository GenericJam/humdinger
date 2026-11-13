defmodule Humdinger.Background do
  @moduledoc """
  Listening while another app (FMutate) is in front: the "Singing into
  FMutate" board, built as Android's ongoing notification rather than a
  floating card.

  Android stops a backgrounded app's microphone unless a foreground service
  of type microphone runs, and that service must show a notification.
  `start/2` starts it (`HumListenService`, in the host package) with a
  notice:

      Humdinger.Background.start(self(), %{
        title: "Humdinger · listening",
        text: "A4 −12¢ → FMutate A · ch 1",
        state: :listening
      })

  `update/1` changes what it shows; call it as often as the text changes:
  an unchanged notice costs nothing, and the service posts at most 4 a
  second (Android drops faster updates). `state` picks the buttons: Pause
  (Resume while `:paused`), Record (Stop rec while `:recording`) and Stop.
  A tap arrives at the process that called `start/2`:

      {:background, :pause | :resume | :record | :record_stop | :stop}

  `{:background, :failed}` arrives instead if Android refused to bring the
  service to the foreground after `start/2` returned (Android 14+: the app
  went to the background first, or the microphone permission was revoked).
  The buttons do nothing by themselves: the owner acts, then calls
  `update/1` or `stop/0`. When the owner exits, the service stops and the
  notification goes, so it never outlives the process its buttons talk to.

  `stop/0` may follow `start/2` at once: if Android hasn't brought the
  service to the foreground yet, it stops as soon as it has (stopping it
  earlier crashes the app on Android).

  Start it while the app is in the foreground (Android 14+ refuses
  otherwise) and once the microphone permission is granted
  (`{:error, :permission}` otherwise). On Android 13+ the notification
  itself needs `Mob.Permissions.request(socket, :notifications)`; without
  it the service still runs, unseen.
  """

  alias Humdinger.Audio

  @defaults %{title: "Humdinger · listening", text: "", state: :listening}
  @states [:listening, :paused, :recording]

  @doc """
  Start the service showing `notice` (a map or keyword list of `title`,
  `text`, `state`; missing fields take the defaults above). Calling it again
  while running updates the notice and moves the buttons to `owner`.
  """
  @spec start(pid(), map() | keyword()) ::
          :ok | {:error, :permission | :refused | :unavailable | :owner_dead}
  def start(owner \\ self(), notice) when is_pid(owner) do
    Audio.impl().background_start(owner, normalize(notice))
  end

  @doc "Show `notice` (missing fields take the defaults). `{:error, :not_running}` before `start/2`."
  @spec update(map() | keyword()) :: :ok | {:error, :not_running}
  def update(notice), do: Audio.impl().background_update(normalize(notice))

  @doc "Stop the service and take the notification away. Idempotent."
  @spec stop() :: :ok
  def stop, do: Audio.impl().background_stop()

  @doc "Whether the service runs."
  @spec running?() :: boolean()
  def running?, do: Audio.impl().background_running?()

  defp normalize(notice) do
    notice = Map.merge(@defaults, Map.new(notice))

    unless is_binary(notice.title) and is_binary(notice.text) and notice.state in @states do
      raise ArgumentError,
            "bad notice #{inspect(notice)}: title and text are strings, state one of #{inspect(@states)}"
    end

    Map.take(notice, [:title, :text, :state])
  end
end
