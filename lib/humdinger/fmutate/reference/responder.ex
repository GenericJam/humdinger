defmodule Humdinger.FMutate.Reference.Responder do
  @moduledoc """
  The reference DNS-SD responder for FMutate: advertises one instance of
  `_fmutate._tcp.local` over multicast DNS. It is the advertising half of
  the discovery protocol written as code; `Humdinger.FMutate.Discovery`
  is the browsing half.

  On Android FMutate advertises with `NsdManager` (the system responder
  owns port 5353) using the same instance name, service type and TXT keys.
  This module is for tests, for hosts standing in for FMutate (a Mac) and
  as the specification.

  ## What is advertised

    * PTR `_fmutate._tcp.local` → `<instance>._fmutate._tcp.local`
      (instance `FMutate A`; a DNS-SD responder may suffix ` (2)` on a
      name conflict; this one does not probe)
    * SRV `<instance>._fmutate._tcp.local` → `:hostname`, `:srv_port`
    * TXT `<instance>._fmutate._tcp.local` with the keys
      `v=1`, `inst` (instance id, `a`), `node` (FMutate's full node name,
      `fmutate_a@192.168.1.23`), `fp` (sha256 of FMutate's TLS certificate,
      base64url without padding), `port` (the pairing port, only while
      pairing is open), `dport` (the distribution port), `fw` (firmware
      name, `X0X`), `dev` (device name, `Pixel 7`)
    * A `:hostname` → `:address`

  A PTR query for the service, or an SRV, TXT, A or ANY query for one of
  its own names, gets all four records: the matching ones as answers, the
  rest as additionals. Responses and queries for other names are ignored.

  ## How it replies (RFC 6762)

    * Query from a port other than 5353 (legacy unicast, §6.7): unicast to
      the query's source address and port, echoing the query id and
      questions, TTL 10, no cache-flush bits.
    * Query with the QU bit (§5.4): unicast to the source, id 0, TTL 120.
    * Otherwise: multicast to `224.0.0.251:5353` on every IPv4 interface,
      TTL 120.

  SRV, TXT and A are unique records (cache-flush bit set in multicast
  replies); PTR is shared.

  ## Options

    * `:instance` – instance label, e.g. `"FMutate A"` (required)
    * `:hostname` – e.g. `"fmutate-a.local"` (required)
    * `:address` – IPv4 tuple for the A record (required)
    * `:srv_port` – SRV port (required)
    * `:txt` – map of TXT keys to values (default `%{}`)
    * `:service` – default `"_fmutate._tcp.local"`
    * `:bind` – `{ip, port}`, default `{{0, 0, 0, 0}, 5353}`. When bound to
      `0.0.0.0` the socket sets `reuseaddr` and `reuseport` (to share 5353
      with the system responder) and joins `224.0.0.251` on every up IPv4
      interface. Tests bind `{{127, 0, 0, 1}, 0}`.
    * `:name` – GenServer name
  """

  use GenServer

  alias Humdinger.FMutate.Dns

  @mdns_group {224, 0, 0, 251}
  @mdns_port 5353
  @ttl 120
  @legacy_ttl 10

  @doc "Starts the responder linked to the caller; see the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The UDP port the responder is bound to."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Replaces the TXT key/value map (e.g. adding `port` when pairing opens)."
  @spec update_txt(GenServer.server(), %{String.t() => String.t()}) :: :ok
  def update_txt(server, txt), do: GenServer.call(server, {:update_txt, txt})

  @doc "Stops the responder."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    service = opts |> Keyword.get(:service, "_fmutate._tcp.local") |> Dns.name()
    {ip, port} = Keyword.get(opts, :bind, {{0, 0, 0, 0}, @mdns_port})
    any? = ip == {0, 0, 0, 0}
    interfaces = if any?, do: interface_addresses(), else: []

    with {:ok, socket} <- :gen_udp.open(port, socket_opts(ip, any?)),
         :ok <- join(socket, interfaces) do
      {:ok,
       %{
         socket: socket,
         interfaces: interfaces,
         service: service,
         instance: [Keyword.fetch!(opts, :instance) | service],
         hostname: opts |> Keyword.fetch!(:hostname) |> Dns.name(),
         address: Keyword.fetch!(opts, :address),
         srv_port: Keyword.fetch!(opts, :srv_port),
         txt: Keyword.get(opts, :txt, %{})
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp socket_opts(ip, true) do
    [:binary, active: true, ip: ip, reuseaddr: true, reuseport: true] ++
      [multicast_loop: true, multicast_ttl: 255]
  end

  defp socket_opts(ip, false), do: [:binary, active: true, ip: ip]

  defp join(socket, interfaces) do
    Enum.reduce_while(interfaces, :ok, fn address, :ok ->
      case :inet.setopts(socket, add_membership: {@mdns_group, address}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp interface_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces,
            :up in Keyword.get(opts, :flags, []),
            :multicast in Keyword.get(opts, :flags, []),
            {:addr, {_, _, _, _} = address} <- opts,
            uniq: true,
            do: address

      {:error, _reason} ->
        []
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:ok, port} = :inet.port(state.socket)
    {:reply, port, state}
  end

  def handle_call({:update_txt, txt}, _from, state), do: {:reply, :ok, %{state | txt: txt}}

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    with {:ok, query} <- Dns.decode(data),
         false <- Dns.response?(query),
         [_ | _] = questions <- Enum.filter(query.questions, &ours?(state, &1)) do
      reply(state, query, questions, ip, port)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ours?(state, %{name: name, type: type}) do
    key = Dns.name_key(name)

    cond do
      key == Dns.name_key(state.service) -> type in [:ptr, :any]
      key == Dns.name_key(state.instance) -> type in [:srv, :txt, :any]
      key == Dns.name_key(state.hostname) -> type in [:a, :any]
      true -> false
    end
  end

  defp reply(state, query, questions, ip, port) when port != @mdns_port do
    {answers, additionals} = records(state, questions, @legacy_ttl, false)

    packet =
      Dns.encode_response(%{
        id: query.id,
        questions: query.questions,
        answers: answers,
        additionals: additionals
      })

    :gen_udp.send(state.socket, ip, port, packet)
  end

  defp reply(state, _query, questions, ip, port) do
    {answers, additionals} = records(state, questions, @ttl, true)
    packet = Dns.encode_response(%{answers: answers, additionals: additionals})

    if Enum.any?(questions, & &1.qu) or state.interfaces == [] do
      :gen_udp.send(state.socket, ip, port, packet)
    else
      Enum.each(state.interfaces, fn address ->
        :inet.setopts(state.socket, multicast_if: address)
        :gen_udp.send(state.socket, @mdns_group, @mdns_port, packet)
      end)
    end
  end

  defp records(state, questions, ttl, flush) do
    all = [
      %{name: state.service, type: :ptr, ttl: ttl, cache_flush: false, data: state.instance},
      %{
        name: state.instance,
        type: :srv,
        ttl: ttl,
        cache_flush: flush,
        data: %{priority: 0, weight: 0, port: state.srv_port, target: state.hostname}
      },
      %{
        name: state.instance,
        type: :txt,
        ttl: ttl,
        cache_flush: flush,
        data: Dns.txt_strings(state.txt)
      },
      %{name: state.hostname, type: :a, ttl: ttl, cache_flush: flush, data: state.address}
    ]

    Enum.split_with(all, fn record ->
      Enum.any?(questions, fn question ->
        Dns.name_key(question.name) == Dns.name_key(record.name) and
          question.type in [record.type, :any]
      end)
    end)
  end
end
