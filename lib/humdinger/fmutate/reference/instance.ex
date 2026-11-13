defmodule Humdinger.FMutate.Reference.Instance do
  @moduledoc """
  FMutate's instance process as siblings see it (reference for protocol §4):
  registered as `:fmutate_instance` on FMutate's node, taking
  `{:fmutate, 1, inst, payload}` as `GenServer` casts (inputs,
  subscriptions) and calls.

  Implemented here: the inputs of §4.1 (delivered to `:sink`), `:subscribe` /
  `:unsubscribe` with `{:status, status}` events (the current status is sent
  on subscribe), and the calls `{:list_firmware}` and `{:unpair, node}` (a
  sibling forgetting its pairing: answered `:ok`, then revoked). Layout and firmware management (`list_layouts`,
  `put_layout`, `switch_firmware`, …) belong to FMutate itself; this
  reference answers them `{:error, :unsupported}`. Any other instance id
  than its own gets `{:error, :no_such_instance}` (§5).

  Events go to subscribers as plain messages `{:fmutate, 1, inst, event}`.
  The last 64 inputs are kept for inspection (`inputs/1`).
  """

  use GenServer

  alias Humdinger.FMutate.Reference.Pairings

  @history 64
  @topics [:screen, :leds, :midi_out, :status, :layout]

  @doc """
  Options: `:inst` (default `"a"`), `:firmware` (the `list_firmware` entries,
  e.g. `[%{id: "x0x", name: "X0X", version: "1.0", status: :running}]`),
  `:status` (default `:running`), `:sink` (a pid receiving
  `{:fmutate_input, payload}`), `:name` (default `:fmutate_instance`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, :fmutate_instance))

  @doc "Sets the emulator status and tells `:status` subscribers."
  @spec set_status(GenServer.server(), term()) :: :ok
  def set_status(server \\ :fmutate_instance, status),
    do: GenServer.call(server, {:set_status, status})

  @doc "The last inputs received, oldest first."
  @spec inputs(GenServer.server()) :: [term()]
  def inputs(server \\ :fmutate_instance), do: GenServer.call(server, :inputs)

  @doc "Current subscribers and their topics."
  @spec subscribers(GenServer.server()) :: %{pid() => [atom()]}
  def subscribers(server \\ :fmutate_instance), do: GenServer.call(server, :subscribers)

  @impl true
  def init(opts) do
    state = %{
      inst: Keyword.get(opts, :inst, "a"),
      firmware: Keyword.get(opts, :firmware, []),
      status: Keyword.get(opts, :status, :running),
      sink: Keyword.get(opts, :sink),
      subscribers: %{},
      inputs: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:fmutate, 1, inst, payload}, %{inst: inst} = state),
    do: {:noreply, cast(payload, state)}

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  # Reply first: revoking disconnects the caller.
  def handle_call({:fmutate, 1, inst, {:unpair, node}}, _from, %{inst: inst} = state)
      when is_atom(node),
      do: {:reply, :ok, state, {:continue, {:unpair, node}}}

  def handle_call({:fmutate, 1, inst, payload}, _from, %{inst: inst} = state),
    do: {:reply, call(payload, state), state}

  def handle_call({:fmutate, 1, _other, _payload}, _from, state),
    do: {:reply, {:error, :no_such_instance}, state}

  def handle_call({:set_status, status}, _from, state) do
    for {pid, %{topics: topics}} <- state.subscribers,
        :status in topics,
        do: send(pid, {:fmutate, 1, state.inst, {:status, status}})

    {:reply, :ok, %{state | status: status}}
  end

  def handle_call(:inputs, _from, state), do: {:reply, Enum.reverse(state.inputs), state}

  def handle_call(:subscribers, _from, state),
    do: {:reply, Map.new(state.subscribers, fn {pid, %{topics: t}} -> {pid, t} end), state}

  @impl true
  def handle_continue({:unpair, node}, state) do
    if Process.whereis(Pairings), do: Pairings.revoke(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => %{ref: ^ref}} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp cast({:subscribe, pid, topics}, state) when is_pid(pid) and is_list(topics) do
    topics = Enum.filter(topics, &(&1 in @topics))
    state = unsubscribe(pid, state)
    # A subscriber on a node that has gone is noticed through the monitor.
    entry = %{ref: Process.monitor(pid), topics: topics}
    if :status in topics, do: send(pid, {:fmutate, 1, state.inst, {:status, state.status}})
    put_in(state.subscribers[pid], entry)
  end

  defp cast({:unsubscribe, pid}, state), do: unsubscribe(pid, state)

  defp cast(payload, state) do
    if input?(payload) do
      if state.sink, do: send(state.sink, {:fmutate_input, payload})
      %{state | inputs: Enum.take([payload | state.inputs], @history)}
    else
      state
    end
  end

  defp unsubscribe(pid, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {%{ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp call({:list_firmware}, state), do: {:ok, state.firmware}
  defp call(_unsupported, _state), do: {:error, :unsupported}

  defp input?({:key, n, :down, velocity}) when n in 0..26 and velocity in 1..127, do: true
  defp input?({:key, n, :up}) when n in 0..26, do: true
  defp input?({:encoder, id, clicks}) when is_atom(id) and is_integer(clicks), do: true

  defp input?({:pot, :master, value}) when is_number(value) and value >= 0 and value <= 1,
    do: true

  defp input?({:button, id, state}) when is_atom(id) and state in [:down, :up], do: true
  defp input?({:midi, bytes}) when is_binary(bytes), do: true
  defp input?(_), do: false
end
