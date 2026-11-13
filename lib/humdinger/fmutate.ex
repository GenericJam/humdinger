defmodule Humdinger.FMutate do
  @moduledoc """
  The link to the paired FMutate: keeps the distribution connection up and
  carries Humdinger's MIDI to it (`design/fmutate/protocol.md`).

  Long-lived (started from `App.on_start`), so it keeps going while the singer
  plays FMutate in the foreground. On start it loads the pairing
  (`Humdinger.FMutate.Store`) and connects (`Humdinger.FMutate.Transport`).
  Once connected it subscribes to FMutate's `:status` and asks for its
  firmware list (`{:list_firmware}`) for the name the boards show ("X0X").

  When the connection drops or can't be made it retries with backoff (1, 2,
  5, 10, then every 30 s). For an FMutate on another phone it also looks it
  up over mDNS from the second failed attempt, and tries a new address (the
  same certificate fingerprint, instance and node name, a unicast non-loopback
  host) without pairing again; the new address is saved only after it has
  connected, since mDNS answers are unauthenticated.

  ## API

    * `status/0`: `:unpaired | :disconnected | {:connected, %{name, firmware,
      device, emulator}}`. `emulator` is FMutate's last `:status` event
      (`:booting | :running | :crashed | :safe_mode | {:slow, pct}`, or nil
      before the first).
    * `subscribe(pid)`: `pid` (monitored) gets `{:fmutate, :status, status}`
      now and on every change.
    * `send_midi(bytes)`: raw MIDI into FMutate's firmware (`{:midi, bytes}`);
      dropped while not connected, and when the connection's buffer is full
      (late notes are worse than lost ones).
    * `forget/0`: tells FMutate (when connected), drops the connection,
      revokes the cookie on this side and deletes the pairing.
    * `install/1`: the hand-off from `Humdinger.FMutate.Pairing`: store a new
      pairing and connect to it.
    * `reconnect/0`: retry now (e.g. when the app returns to the foreground).

  Every function takes the server as an optional last argument (tests run
  their own).
  """

  use GenServer

  alias Humdinger.FMutate.{Discovery, Record, Store, Transport}

  require Logger

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]
  # Mob.Dist starts the development node 3 s after boot and waits up to 10 s
  # for the Mac's epmd; the link waits that long (or until the node is up)
  # before starting its own.
  @dev_grace 15_000
  @call_timeout 5_000

  @type info :: %{
          name: String.t() | nil,
          firmware: String.t() | nil,
          device: String.t() | nil,
          emulator: term()
        }
  @type status :: :unpaired | :disconnected | {:connected, info()}

  @doc """
  Options (for tests): `:name`, `:store` (`{module, opts}`, default
  `{Humdinger.FMutate.Store, []}`), `:transport` (default
  `Humdinger.FMutate.Transport`), `:discovery` (a function of browse options,
  default `Humdinger.FMutate.Discovery.browse/1`), `:backoff` (ms list, the
  last repeats), `:grace_ms` (delay before the first connection when the link
  would start distribution itself).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The link's status."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Sends `{:fmutate, :status, status}` to `pid` now and on every change."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid \\ self(), server \\ __MODULE__),
    do: GenServer.call(server, {:subscribe, pid})

  @doc "Stops status messages to `pid`."
  @spec unsubscribe(pid(), GenServer.server()) :: :ok
  def unsubscribe(pid \\ self(), server \\ __MODULE__),
    do: GenServer.call(server, {:unsubscribe, pid})

  @doc "Sends raw MIDI to FMutate; dropped while not connected."
  @spec send_midi(binary(), GenServer.server()) :: :ok
  def send_midi(bytes, server \\ __MODULE__) when is_binary(bytes),
    do: GenServer.cast(server, {:midi, bytes})

  @doc "Forgets the pairing (see the moduledoc). `{:error, reason}` if the store couldn't delete it."
  @spec forget(GenServer.server()) :: :ok | {:error, term()}
  def forget(server \\ __MODULE__), do: GenServer.call(server, :forget)

  @doc "Stores a new pairing and connects to it."
  @spec install(Record.t(), GenServer.server()) :: :ok | {:error, term()}
  def install(%Record{} = record, server \\ __MODULE__),
    do: GenServer.call(server, {:install, record})

  @doc "Retries the connection now if paired and not connected."
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server \\ __MODULE__), do: GenServer.cast(server, :reconnect)

  @impl true
  def init(opts) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)

    state = %{
      store: Keyword.get(opts, :store, {Store, []}),
      transport: Keyword.get(opts, :transport, Transport),
      discovery: Keyword.get(opts, :discovery, &Discovery.browse/1),
      backoff: Keyword.get(opts, :backoff, @backoff),
      record: nil,
      conn: nil,
      # FMutate's node atom once connected, kept after a disconnect so
      # forget/0 can revoke its cookie.
      node: nil,
      info: nil,
      subscribers: %{},
      connecting: nil,
      looking: nil,
      # A new address from mDNS on trial: saved only once it connects.
      trying: nil,
      # Hosts from mDNS that failed since the last connection.
      tried: MapSet.new(),
      attempt: 0,
      timer: nil
    }

    {:ok, state, {:continue, {:load, Keyword.get_lazy(opts, :grace_ms, &default_grace/0)}}}
  end

  @impl true
  def handle_continue({:load, grace}, %{store: {store, store_opts}} = state) do
    case store.load(store_opts) do
      {:ok, record} ->
        state = %{state | record: record}

        if grace > 0 and not Node.alive?(),
          do: {:noreply, await_node(state, now() + grace)},
          else: {:noreply, connect(state)}

      :none ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("FMutate: can't read the pairing: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid),
        do: state,
        else: put_in(state.subscribers[pid], Process.monitor(pid))

    send(pid, {:fmutate, :status, status_of(state)})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:forget, _from, %{store: {store, store_opts}} = state) do
    # A call, so FMutate has dropped the pairing before the connection goes
    # (its answer may be cut off by that revocation: either is fine).
    if state.conn,
      do: state.transport.call(state.conn, state.record.inst, {:unpair, node()}, @call_timeout)

    state = drop(state)
    state.transport.revoke(state.node)
    reply = store.delete(store_opts)

    {:reply, reply,
     notify(%{state | record: nil, conn: nil, node: nil, info: nil, attempt: 0}, state)}
  end

  def handle_call({:install, record}, _from, %{store: {store, store_opts}} = state) do
    case store.save(record, store_opts) do
      :ok ->
        old = state
        state = drop(state)

        if state.node && Atom.to_string(state.node) != record.node,
          do: state.transport.revoke(state.node)

        state = %{state | record: record, conn: nil, info: nil, attempt: 0}
        {:reply, :ok, state |> connect() |> notify(old)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:midi, bytes}, %{conn: conn} = state) when conn != nil do
    state.transport.cast(conn, state.record.inst, {:midi, bytes})
    {:noreply, state}
  end

  def handle_cast({:midi, _bytes}, state), do: {:noreply, state}

  def handle_cast(:reconnect, %{record: record, conn: nil, connecting: nil} = state)
      when record != nil do
    {:noreply, state |> cancel_timer() |> connect()}
  end

  def handle_cast(:reconnect, state), do: {:noreply, state}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(%{state | timer: nil})}

  def handle_info({:await_node, deadline}, state) do
    if Node.alive?() or now() >= deadline,
      do: {:noreply, connect(%{state | timer: nil})},
      else: {:noreply, await_node(state, deadline)}
  end

  def handle_info({:connected, pid, conn, firmware}, %{connecting: {pid, _}} = state) do
    old = state
    state = adopt(state)
    record = remember_firmware(state, firmware)
    # Subscribed only now, so FMutate's first status event can't overtake this.
    state.transport.cast(conn, record.inst, {:subscribe, self(), [:status]})
    info = %{name: record.name, firmware: record.firmware, device: record.device, emulator: nil}

    state = %{
      state
      | record: record,
        conn: conn,
        node: conn.node,
        info: info,
        connecting: nil,
        attempt: 0,
        tried: MapSet.new()
    }

    {:noreply, notify(state, old)}
  end

  def handle_info({:connect_failed, pid, reason}, %{connecting: {pid, _}} = state) do
    Logger.debug("FMutate: connect failed: #{inspect(reason)}")
    {:noreply, state |> reject_trial() |> Map.put(:connecting, nil) |> retry()}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{connecting: {pid, _}} = state) do
    Logger.warning("FMutate: connect crashed: #{inspect(reason)}")
    {:noreply, retry(%{state | connecting: nil})}
  end

  def handle_info({:found, pid, candidates}, %{looking: pid} = state) do
    {:noreply, follow(%{state | looking: nil}, candidates)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{looking: pid} = state) do
    {:noreply, %{state | looking: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.subscribers, pid) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info({:nodedown, node, _info}, %{conn: %{node: node}} = state) do
    old = state
    state.transport.disconnect(state.conn)
    state = %{state | conn: nil, info: nil}
    {:noreply, state |> notify(old) |> retry()}
  end

  def handle_info(
        {:fmutate, 1, inst, {:status, emulator}},
        %{conn: conn, record: %{inst: inst}} = state
      )
      when conn != nil do
    old = state
    if emulator == :running, do: refresh_firmware(state)
    {:noreply, notify(put_in(state.info.emulator, emulator), old)}
  end

  def handle_info({:firmware, conn, firmware}, %{conn: conn} = state) when firmware != nil do
    old = state
    record = remember_firmware(state, firmware)

    {:noreply,
     notify(%{state | record: record, info: %{state.info | firmware: record.firmware}}, old)}
  end

  # Node events for other nodes, FMutate events for an old connection,
  # results of replaced attempts.
  def handle_info(_other, state), do: {:noreply, state}

  defp connect(%{record: nil} = state), do: state
  defp connect(%{connecting: {_, _}} = state), do: state
  defp connect(%{conn: conn} = state) when conn != nil, do: state

  defp connect(state) do
    link = self()
    record = state.trying || state.record
    transport = state.transport

    {pid, ref} =
      spawn_monitor(fn ->
        case transport.connect(record, link) do
          {:ok, conn} ->
            send(link, {:connected, self(), conn, firmware(transport, conn, record.inst)})

          {:error, reason} ->
            send(link, {:connect_failed, self(), reason})
        end
      end)

    %{state | connecting: {pid, ref}}
  end

  defp retry(%{record: nil} = state), do: state

  defp retry(state) do
    attempt = state.attempt + 1
    delay = Enum.at(state.backoff, attempt - 1, List.last(state.backoff))
    state = schedule(%{state | attempt: attempt}, delay)
    if attempt >= 2 and not Record.loopback?(state.record), do: look_up(state), else: state
  end

  defp schedule(state, delay) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :connect, delay)}
  end

  # Development build: wait for Mob.Dist's node (checked each 500 ms) until
  # the deadline, then start one.
  defp await_node(state, deadline) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), {:await_node, deadline}, 500)}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # An FMutate on another phone may have a new address: ask mDNS.
  defp look_up(%{looking: pid} = state) when is_pid(pid), do: state

  defp look_up(state) do
    link = self()
    browse = state.discovery

    {pid, _ref} =
      spawn_monitor(fn ->
        case browse.([]) do
          {:ok, candidates} -> send(link, {:found, self(), candidates})
          {:error, _} -> :ok
        end
      end)

    %{state | looking: pid}
  end

  # Tries a candidate with the pairing's certificate, instance and node name
  # at a new address. mDNS is unauthenticated, so the candidate is only
  # tried: it replaces the stored record once it has connected (TLS pinned to
  # the pairing's certificate, then the cookie handshake). Loopback and other
  # non-unicast addresses are never taken from mDNS, nor a node name other
  # than the pairing's at the new host. Nothing moves while FMutate's current
  # address is still among the answers. Each `{host, dist_port}` is tried once
  # per outage, so a forged answer for the right host can't use up the
  # genuine one's trial.
  defp follow(%{record: record, conn: nil, trying: nil} = state, candidates) when record != nil do
    ours = Enum.filter(candidates, &(&1.fp == record.fp and &1.inst == record.inst))

    with false <- Enum.any?(ours, &(&1.host == record.host)),
         %{} = found <- Enum.find(ours, &movable?(state, &1)),
         {:ok, moved} <-
           Record.validate(%{
             record
             | host: found.host,
               node: found.node,
               dist_port: found.dist_port || record.dist_port
           }) do
      Logger.info("FMutate: trying #{moved.host}")
      %{state | trying: moved} |> cancel_timer() |> connect()
    else
      _ -> state
    end
  end

  defp follow(state, _candidates), do: state

  defp movable?(%{record: record, tried: tried}, candidate) do
    [name, _host] = String.split(record.node, "@", parts: 2)
    trial = {candidate.host, candidate.dist_port || record.dist_port}

    Record.remote_unicast?(candidate.host) and not MapSet.member?(tried, trial) and
      candidate.node == "#{name}@#{candidate.host}"
  end

  # The trial connected: it becomes the pairing.
  defp adopt(%{trying: nil} = state), do: state

  defp adopt(%{trying: moved, store: {store, store_opts}} = state) do
    store.save(moved, store_opts)
    Logger.info("FMutate: moved to #{moved.host}")
    %{state | record: moved, trying: nil}
  end

  defp reject_trial(%{trying: nil} = state), do: state

  defp reject_trial(%{trying: moved} = state),
    do: %{state | trying: nil, tried: MapSet.put(state.tried, {moved.host, moved.dist_port})}

  defp firmware(transport, conn, inst) do
    case transport.call(conn, inst, {:list_firmware}, @call_timeout) do
      {:ok, {:ok, list}} when is_list(list) -> active_firmware(list)
      _ -> nil
    end
  end

  defp refresh_firmware(%{conn: conn, transport: transport, record: record}) do
    link = self()
    spawn(fn -> send(link, {:firmware, conn, firmware(transport, conn, record.inst)}) end)
  end

  # The running firmware's name: the entry whose status says so, else the first.
  defp active_firmware(list) do
    entries = Enum.filter(list, &(is_map(&1) and is_binary(Map.get(&1, :name))))
    running = Enum.find(entries, &(Map.get(&1, :status) in [:running, :active]))

    case running || List.first(entries) do
      %{name: name} -> name
      nil -> nil
    end
  end

  defp remember_firmware(%{record: record}, firmware) when firmware in [nil, record.firmware],
    do: record

  defp remember_firmware(%{record: record, store: {store, store_opts}}, firmware) do
    record = %{record | firmware: firmware}
    store.save(record, store_opts)
    record
  end

  # Cancels pending attempts and closes the connection.
  defp drop(state) do
    if state.connecting, do: Process.exit(elem(state.connecting, 0), :kill)
    if state.looking, do: Process.exit(state.looking, :kill)
    if state.conn, do: state.transport.disconnect(state.conn)
    %{cancel_timer(state) | connecting: nil, looking: nil, trying: nil, tried: MapSet.new()}
  end

  defp status_of(%{record: nil}), do: :unpaired
  defp status_of(%{conn: nil}), do: :disconnected
  defp status_of(%{info: info}), do: {:connected, info}

  defp notify(state, old) do
    status = status_of(state)

    if status != status_of(old) do
      for pid <- Map.keys(state.subscribers), do: send(pid, {:fmutate, :status, status})
    end

    state
  end

  defp default_grace do
    if Application.get_env(:humdinger, :fmutate_dev_node) && System.get_env("MOB_BEAMS_DIR") &&
         not Mob.Dist.release_mode?(),
       do: @dev_grace,
       else: 0
  end
end
