defmodule Humdinger.Test.Listener do
  @moduledoc """
  Where the reporting doubles (`Humdinger.Test.FakeOutput`,
  `Humdinger.Test.Share`, `Humdinger.Test.Print`) report: the pid in
  `config :humdinger, :test_listener` (set per test with `listen/0`; tests
  using it run `async: false`).
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

defmodule Humdinger.Test.Share do
  @moduledoc """
  A `Mob.Share` double (`config :humdinger, :share`): reports
  `{:share, path, mime, title}` to `Humdinger.Test.Listener` and returns
  `socket` unchanged.
  """

  alias Humdinger.Test.Listener

  def file(socket, path, opts \\ []) do
    Listener.tell({:share, path, opts[:mime], opts[:title]})
    socket
  end
end

defmodule Humdinger.Test.Print do
  @moduledoc """
  A `MobPrint` double (`config :humdinger, :print`): reports
  `{:print, path, title}` to `Humdinger.Test.Listener` and returns `:ok`
  (or the result configured with `set_result/1`).
  """

  alias Humdinger.Test.Listener

  def pdf(path, opts \\ []) do
    Listener.tell({:print, path, opts[:title]})
    Application.get_env(:humdinger, :test_print_result, :ok)
  end

  @doc "Set the result `pdf/2` returns until the test ends."
  def set_result(result) do
    Application.put_env(:humdinger, :test_print_result, result)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:humdinger, :test_print_result) end)
    :ok
  end
end
