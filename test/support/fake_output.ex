defmodule Humdinger.Test.FakeOutput do
  @moduledoc """
  The `Humdinger.Output` double (`output:` / `config :humdinger, :output`):
  the Engine's and Player's `send_events/1` and `configure/1`, and the
  screens' `destinations/0`, `subscribe/1` and `set_enabled/2`.

  Destinations start as Output's defaults (FMutate and the port on,
  FMutate connected as "FMutate A"); `reset/1` replaces them. Subscribers
  get `{:output, :destinations, list}` at once and on every change. What
  is sent and configured is reported to the test listening through
  `Humdinger.Test.Listener` as `{:output, events}` and `{:configure, opts}`.
  State lives in a named Agent, so tests
  using it run `async: false`; `reset/0` from a test's setup.
  """

  alias Humdinger.Test.Listener

  @doc "Forget everything; `destinations` replaces the default list."
  def reset(destinations \\ defaults()) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> fresh(destinations) end)
  end

  def defaults do
    [
      %{
        id: :fmutate,
        name: "FMutate A",
        detail: "sibling app · connected",
        enabled: true,
        available: true
      },
      %{
        id: :port,
        name: "Humdinger port",
        detail: "virtual MIDI · any app can pick it",
        enabled: true,
        available: true
      },
      %{
        id: :usb,
        name: "USB MIDI out",
        detail: "nothing plugged in",
        enabled: false,
        available: false
      },
      %{id: :bt, name: "Bluetooth MIDI", detail: "none paired", enabled: false, available: false}
    ]
  end

  # Like a cast, these never fail: the engine's terminate/2 may call them
  # after the test has gone.
  def send_events(events), do: Listener.tell({:output, events})

  def configure(opts), do: Listener.tell({:configure, opts})

  # Messages to the listener are sent directly, so there is nothing to wait for.
  def sync, do: :ok

  # A Player's session: its events are reported like the live ones. No
  # arbitration here; tests of that use the real Humdinger.Output.
  def acquire(_owner), do: {:ok, make_ref()}
  def session_events(_ref, events), do: Listener.tell({:output, events})
  def release(_ref), do: :ok

  def destinations, do: get(& &1.destinations)

  def subscribe(pid) do
    update(fn s -> %{s | subscribers: [pid | s.subscribers]} end)
    send(pid, {:output, :destinations, destinations()})
    :ok
  end

  def set_enabled(id, enabled) do
    update(fn s ->
      %{
        s
        | destinations:
            Enum.map(s.destinations, &if(&1.id == id, do: %{&1 | enabled: enabled}, else: &1))
      }
    end)

    list = destinations()
    for pid <- get(& &1.subscribers), do: send(pid, {:output, :destinations, list})
    :ok
  end

  defp get(fun) do
    ensure_started()
    Agent.get(__MODULE__, fun)
  end

  defp update(fun) do
    ensure_started()
    Agent.update(__MODULE__, fun)
  end

  defp fresh(destinations), do: %{destinations: destinations, subscribers: []}

  defp ensure_started do
    case Agent.start(fn -> fresh(defaults()) end, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
