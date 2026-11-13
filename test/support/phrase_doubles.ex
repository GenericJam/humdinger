defmodule Humdinger.Test.Listener do
  @moduledoc """
  Where the phrase-screen doubles report: the pid in `config :humdinger,
  :test_listener` (set per test with `listen/0`; tests using it run
  `async: false`).
  """

  @doc "Make the calling process the listener until the test ends."
  def listen do
    Application.put_env(:humdinger, :test_listener, self())
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:humdinger, :test_listener) end)
    :ok
  end

  @doc "Send `message` to the listener, if there is one."
  def tell(message) do
    case Application.get_env(:humdinger, :test_listener) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end

defmodule Humdinger.Test.Output do
  @moduledoc """
  An output double: `send_events/1` reports `{:output, events}`;
  `destinations/0` answers `config :humdinger, :test_destinations` (default:
  FMutate A, connected and on).
  """

  alias Humdinger.Test.Listener

  def send_events(events), do: Listener.tell({:output, events})

  def destinations do
    Application.get_env(:humdinger, :test_destinations, [
      %{id: :fmutate, name: "FMutate A", detail: "", enabled: true, available: true},
      %{id: :port, name: "Humdinger port", detail: "", enabled: true, available: true}
    ])
  end
end

defmodule Humdinger.Test.FileShare do
  @moduledoc "A `Humdinger.Export.Native` double: reports `{:share, path, mime, title}` and `{:print, path, title}`."

  @behaviour Humdinger.Export.Native

  alias Humdinger.Test.Listener

  @impl true
  def share_file(path, mime, title), do: Listener.tell({:share, path, mime, title})

  @impl true
  def print_pdf(path, title), do: Listener.tell({:print, path, title})
end

defmodule Humdinger.Test.FileAudio do
  @moduledoc """
  An audio double for file analysis: `analyze_file/3` answers `{:ok, ref}`
  and reports `{:analyze, owner, path, ref}`; the test then sends the
  analysis itself as `{:hum_audio, ref, {:analysis, analysis}}`.
  """

  alias Humdinger.Test.Listener

  def analyze_file(owner, path, _opts) do
    ref = make_ref()
    Listener.tell({:analyze, owner, path, ref})
    {:ok, ref}
  end
end
