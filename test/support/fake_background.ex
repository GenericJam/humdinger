defmodule Humdinger.Test.FakeBackground do
  @moduledoc """
  The `MobBackground` double (`background:` / `config :humdinger, :background`):
  tracks the active session (`%{owner, mode, notification}`) in a named
  GenServer, stops it if the owner exits, and lets tests drive button taps
  (`tap/1`), async refusals (`refuse/1`), and synchronous start failures
  (`set_start_result/1`).

  One service per VM, like the phone: tests using it run `async: false` and
  call `reset/0` in setup.
  """

  use GenServer

  # ── MobBackground API ───────────────────────────────────────────────────

  @doc "Start a session owned by `self()`."
  def start(opts) when is_list(opts), do: start(self(), opts)

  @doc "Start (or retarget) the background session owned by `owner`."
  def start(owner, opts) when is_pid(owner) and is_list(opts) do
    mode = Keyword.fetch!(opts, :mode)
    notification = Keyword.fetch!(opts, :notification)
    call({:start, owner, mode, notification})
  end

  @doc "Update the active session's notification."
  def update(notification) when is_map(notification), do: call({:update, notification})

  @doc "Stop the active session. Idempotent."
  def stop, do: call(:stop)

  @doc "`:idle` or `{:running, mode}`."
  def status, do: call(:status)

  # ── Test helpers ────────────────────────────────────────────────────────

  @doc "`%{owner, mode, notification}` while running, else `nil`."
  def current, do: call(:current)

  @doc """
  Simulate tapping notification action `id`: sends
  `{:mob_background, {:action, id}}` to the owner, or returns
  `{:error, :not_running}` when idle.
  """
  def tap(id) when is_atom(id), do: call({:tap, id})

  @doc """
  Simulate Android ending the foreground service asynchronously (default
  `:foreground_refused`, or `:timeout`): sends
  `{:mob_background, {:error, reason}}` to the owner and ends the session.
  """
  def refuse(reason \\ :foreground_refused) when is_atom(reason), do: call({:refuse, reason})

  @doc "Configure what `start/2` returns (`:ok` or `{:error, reason}`)."
  def set_start_result(result), do: call({:set_start_result, result})

  @doc "Stop any running session and restore default start behaviour."
  def reset, do: call(:reset)

  # ── Server ──────────────────────────────────────────────────────────────

  defp call(request) do
    pid =
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, request)
  end

  defp fresh, do: %{session: nil, monitor: nil, start_result: :ok}

  @impl GenServer
  def init(nil), do: {:ok, fresh()}

  @impl GenServer
  def handle_call(
        {:start, _owner, _mode, _notification},
        _from,
        %{start_result: {:error, _} = err} = s
      ),
      do: {:reply, err, s}

  def handle_call({:start, owner, mode, notification}, _from, s) do
    s = stop_session(s)

    if Process.alive?(owner) do
      session = %{owner: owner, mode: mode, notification: notification}
      {:reply, :ok, %{s | session: session, monitor: Process.monitor(owner)}}
    else
      {:reply, {:error, :owner_dead}, s}
    end
  end

  def handle_call({:update, _notification}, _from, %{session: nil} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:update, notification}, _from, s),
    do: {:reply, :ok, put_in(s.session.notification, notification)}

  def handle_call(:stop, _from, s), do: {:reply, :ok, stop_session(s)}

  def handle_call(:status, _from, %{session: nil} = s), do: {:reply, :idle, s}

  def handle_call(:status, _from, %{session: %{mode: mode}} = s),
    do: {:reply, {:running, mode}, s}

  def handle_call(:current, _from, s), do: {:reply, s.session, s}

  def handle_call({:tap, _id}, _from, %{session: nil} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:tap, id}, _from, s) do
    send(s.session.owner, {:mob_background, {:action, id}})
    {:reply, :ok, s}
  end

  def handle_call({:refuse, _reason}, _from, %{session: nil} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:refuse, reason}, _from, s) do
    owner = s.session.owner
    s = stop_session(s)
    send(owner, {:mob_background, {:error, reason}})
    {:reply, :ok, s}
  end

  def handle_call({:set_start_result, result}, _from, s),
    do: {:reply, :ok, %{s | start_result: result}}

  def handle_call(:reset, _from, s) do
    _ = stop_session(s)
    {:reply, :ok, fresh()}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = s),
    do: {:noreply, stop_session(s)}

  def handle_info(_msg, s), do: {:noreply, s}

  defp stop_session(%{monitor: nil} = s), do: %{s | session: nil}

  defp stop_session(s) do
    Process.demonitor(s.monitor, [:flush])
    %{s | session: nil, monitor: nil}
  end
end
