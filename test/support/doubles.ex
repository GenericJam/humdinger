defmodule Humdinger.Test.Listener do
  @moduledoc """
  Where the reporting doubles (`Humdinger.Test.FakeOutput`,
  `Humdinger.Test.FileShare`) report: the pid in `config :humdinger,
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

defmodule Humdinger.Test.FileShare do
  @moduledoc "A `Humdinger.Export.Native` double: reports `{:share, path, mime, title}` and `{:print, path, title}`."

  @behaviour Humdinger.Export.Native

  alias Humdinger.Test.Listener

  @impl true
  def share_file(path, mime, title), do: Listener.tell({:share, path, mime, title})

  @impl true
  def print_pdf(path, title), do: Listener.tell({:print, path, title})
end
