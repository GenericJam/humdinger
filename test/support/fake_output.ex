defmodule Humdinger.Test.FakeOutput do
  @moduledoc """
  An Output double for screen tests: the Engine's `send_events/1` and
  `configure/1`, and the screens' `destinations/0`, `subscribe/1` and
  `set_enabled/2`. Destinations start as Output's defaults (FMutate and the
  port on, FMutate connected as "FMutate A"); subscribers get
  `{:output, :destinations, list}` at once and on every change. Events sent
  are kept for `sent/0`. State lives in a named Agent, so tests using it
  run `async: false`; `reset/0` from a test's setup.
  """

  @doc "Forget everything; `destinations` replaces the default list."
  def reset(destinations \\ defaults()) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{destinations: destinations, subscribers: [], sent: []} end)
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

  def send_events(events), do: update(fn s -> %{s | sent: s.sent ++ events} end)
  def configure(_opts), do: :ok

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

  @doc "Every event sent so far."
  def sent, do: get(& &1.sent)

  defp get(fun) do
    ensure_started()
    Agent.get(__MODULE__, fun)
  end

  defp update(fun) do
    ensure_started()
    Agent.update(__MODULE__, fun)
  end

  defp ensure_started do
    case Agent.start(fn -> %{destinations: defaults(), subscribers: [], sent: []} end,
           name: __MODULE__
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
