defmodule Humdinger.FMutate.Discovery do
  @moduledoc """
  Finds FMutate instances on the local network: a one-shot DNS-SD browse
  for `_fmutate._tcp.local` over multicast DNS.

  ## Why one-shot legacy unicast

  The query goes out as an RFC 6762 §5.1 *one-shot* query from an ephemeral
  UDP port, not 5353. A compliant responder (Android's mdnsd behind
  `NsdManager`, macOS mDNSResponder, `Humdinger.FMutate.Reference.Responder`)
  treats a query from a port other than 5353 as a *legacy unicast* query
  (§6.7) and answers by unicast straight to the sending socket, echoing the
  query id. Humdinger therefore never receives multicast: on Android it
  needs no `WifiManager.MulticastLock` and does not share port 5353 with the
  system responder. Sending multicast needs neither.

  By default one socket is opened per up, non-loopback, multicast-capable
  IPv4 interface, bound to that interface's address, with `multicast_if`
  set to it and a multicast TTL of 255; the query goes to
  `224.0.0.251:5353` on each. It is sent at 0, 250 and 750 ms (those before
  the timeout) to survive packet loss. When a PTR answer arrives without
  the instance's SRV or TXT record, or an SRV without the A record of its
  target, the missing records are asked for at once (macOS includes them
  as additionals; Android's mdnsd may not).

  ## Candidates

  The TXT keys FMutate advertises:

    * `v` – `1` (instances with another version are dropped; missing means 1)
    * `inst` – instance id, e.g. `a` (required)
    * `node` – FMutate's full node name, e.g. `fmutate_a@192.168.1.23`
      (required)
    * `fp` – sha256 of FMutate's TLS certificate, base64url without padding
      (required; decoded to 32 bytes)
    * `port` – the pairing port, present only while FMutate's Pair screen is
      open
    * `dport` – the distribution port
    * `fw` – firmware name, e.g. `X0X`
    * `dev` – device name, e.g. `Pixel 7`

  The instance name is the DNS-SD instance label (`FMutate A`, possibly
  suffixed ` (2)` by the responder). `host` is the A record of the SRV
  target, or the source address of the reply when that is missing.
  Candidates are deduplicated by `{fp, inst}` (the latest answer wins) and
  ordered by name. Every string is the binary from the packet; no atoms are
  created from network data. Malformed packets are ignored (see
  `Humdinger.FMutate.Dns`).
  """

  alias Humdinger.FMutate.Dns

  @service "_fmutate._tcp.local"
  @mdns {{224, 0, 0, 251}, 5353}
  @timeout 1_500
  @resends [0, 250, 750]
  @recv_max 9000
  @max_instances 64

  @type candidate :: %{
          name: String.t(),
          inst: String.t(),
          node: String.t(),
          host: String.t(),
          port: :inet.port_number() | nil,
          dist_port: :inet.port_number() | nil,
          fp: <<_::256>>,
          firmware: String.t() | nil,
          device: String.t() | nil
        }

  @type target :: {:inet.ip4_address(), :inet.port_number()}

  @doc """
  Browses for FMutate instances for `:timeout` ms (default 1500) and returns
  what answered.

  Options:

    * `:timeout` – how long to collect replies, in ms
    * `:targets` – `[{ip, port}]` to query instead of the mDNS group on every
      interface, sent from one socket bound to loopback (when every target is
      loopback) or to `0.0.0.0`
    * `:service` – the service to browse (default `"_fmutate._tcp.local"`)

  Returns `{:error, :no_interface}` when no IPv4 multicast interface is up,
  or the socket error when no socket could be opened.
  """
  @spec browse(keyword()) :: {:ok, [candidate()]} | {:error, term()}
  def browse(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    service = opts |> Keyword.get(:service, @service) |> Dns.name()

    with {:ok, sockets} <- open_sockets(Keyword.get(opts, :targets)) do
      now = now()

      state = %{
        sockets: Map.new(sockets),
        service: service,
        service_key: Dns.name_key(service),
        deadline: now + timeout,
        resends: Enum.map(Enum.filter(@resends, &(&1 < timeout)), &(&1 + now)),
        query: Dns.encode_query([%{name: service, type: :ptr}], :rand.uniform(0xFFFF)),
        seq: 0,
        instances: %{},
        srv: %{},
        txt: %{},
        a: %{},
        asked: MapSet.new()
      }

      candidates = state |> collect() |> candidates()
      Enum.each(sockets, fn {socket, _targets} -> close(socket) end)
      {:ok, candidates}
    end
  end

  defp open_sockets(nil) do
    case interface_addresses() do
      [] ->
        {:error, :no_interface}

      addresses ->
        opened =
          for address <- addresses,
              {:ok, socket} <- [open(address, multicast_if: address)],
              do: {socket, [@mdns]}

        if opened == [], do: {:error, :no_socket}, else: {:ok, opened}
    end
  end

  defp open_sockets(targets) do
    bind =
      if Enum.all?(targets, fn {ip, _port} -> elem(ip, 0) == 127 end),
        do: {127, 0, 0, 1},
        else: {0, 0, 0, 0}

    with {:ok, socket} <- open(bind, []), do: {:ok, [{socket, targets}]}
  end

  defp open(address, extra) do
    :gen_udp.open(
      0,
      [:binary, active: true, ip: address, multicast_ttl: 255, recbuf: 65_536] ++ extra
    )
  end

  defp close(socket) do
    :gen_udp.close(socket)
    flush(socket)
  end

  defp flush(socket) do
    receive do
      {:udp, ^socket, _ip, _port, _data} -> flush(socket)
    after
      0 -> :ok
    end
  end

  defp interface_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces,
            flags = Keyword.get(opts, :flags, []),
            :up in flags and :multicast in flags and :loopback not in flags,
            {:addr, {_, _, _, _} = address} <- opts,
            elem(address, 0) != 127,
            uniq: true,
            do: address

      {:error, _reason} ->
        []
    end
  end

  defp collect(state) do
    now = now()

    case state.resends do
      [at | rest] when at <= now ->
        send_all(state, state.query)
        collect(%{state | resends: rest})

      resends ->
        wake = Enum.min([state.deadline | resends])
        wait = max(wake - now, 0)

        if now >= state.deadline, do: state, else: receive_reply(state, wait)
    end
  end

  defp receive_reply(state, wait) do
    sockets = state.sockets

    receive do
      {:udp, socket, ip, _port, data} when is_map_key(sockets, socket) ->
        state |> handle_reply(socket, ip, data) |> collect()
    after
      wait -> collect(state)
    end
  end

  defp send_all(state, packet) do
    Enum.each(state.sockets, fn {socket, targets} -> send_to(socket, targets, packet) end)
  end

  defp send_to(socket, targets, packet) do
    Enum.each(targets, fn {ip, port} -> :gen_udp.send(socket, ip, port, packet) end)
  end

  defp handle_reply(state, _socket, _ip, data) when byte_size(data) > @recv_max, do: state

  defp handle_reply(state, socket, ip, data) do
    with {:ok, message} <- Dns.decode(data),
         true <- Dns.response?(message) do
      records = message.answers ++ message.additionals
      state = %{state | seq: state.seq + 1}

      state
      |> take_ptrs(records, ip)
      |> take_instance_records(records, ip)
      |> take_addresses(records)
      |> follow_up(socket)
    else
      _ -> state
    end
  end

  defp take_ptrs(state, records, ip) do
    Enum.reduce(records, state, fn
      %{type: :ptr, name: name, data: [_label | rest] = instance}, state ->
        if Dns.name_key(name) == state.service_key and Dns.name_key(rest) == state.service_key,
          do: touch_instance(state, instance, ip),
          else: state

      _record, state ->
        state
    end)
  end

  defp touch_instance(state, [label | _] = instance, ip) do
    key = Dns.name_key(instance)

    if is_map_key(state.instances, key) or map_size(state.instances) < @max_instances do
      entry = %{name: label, ip: ip, seq: state.seq}
      %{state | instances: Map.put(state.instances, key, entry)}
    else
      state
    end
  end

  defp take_instance_records(state, records, ip) do
    Enum.reduce(records, state, fn
      %{type: type, name: name, data: data}, state when type in [:srv, :txt] ->
        key = Dns.name_key(name)

        case state.instances do
          %{^key => entry} ->
            entry = %{entry | ip: ip, seq: state.seq}
            state = %{state | instances: Map.put(state.instances, key, entry)}
            Map.update!(state, type, &Map.put(&1, key, data))

          _ ->
            state
        end

      _record, state ->
        state
    end)
  end

  defp take_addresses(state, records) do
    targets = MapSet.new(state.srv, fn {_key, srv} -> Dns.name_key(srv.target) end)

    Enum.reduce(records, state, fn
      %{type: :a, name: name, data: address}, state ->
        key = Dns.name_key(name)

        if MapSet.member?(targets, key),
          do: %{state | a: Map.put(state.a, key, address)},
          else: state

      _record, state ->
        state
    end)
  end

  defp follow_up(state, socket) do
    questions =
      state.instances
      |> Enum.flat_map(fn {key, %{name: label}} ->
        instance_questions(state, key, [label | state.service]) ++ address_question(state, key)
      end)
      |> Enum.reject(fn {asked, _question} -> MapSet.member?(state.asked, asked) end)

    if questions == [] do
      state
    else
      packet = Dns.encode_query(Enum.map(questions, &elem(&1, 1)), :rand.uniform(0xFFFF))
      send_to(socket, Map.fetch!(state.sockets, socket), packet)
      asked = Enum.reduce(questions, state.asked, &MapSet.put(&2, elem(&1, 0)))
      %{state | asked: asked}
    end
  end

  defp instance_questions(state, key, instance) do
    for type <- [:srv, :txt], not is_map_key(Map.fetch!(state, type), key) do
      {{type, key}, %{name: instance, type: type}}
    end
  end

  defp address_question(state, key) do
    case state.srv do
      %{^key => %{target: target}} ->
        target_key = Dns.name_key(target)

        if is_map_key(state.a, target_key),
          do: [],
          else: [{{:a, target_key}, %{name: target, type: :a}}]

      _ ->
        []
    end
  end

  defp candidates(state) do
    state.instances
    |> Enum.flat_map(fn {key, entry} ->
      case candidate(state, key, entry) do
        {:ok, candidate} -> [{entry.seq, candidate}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {seq, _candidate} -> seq end)
    |> Map.new(fn {_seq, candidate} -> {{candidate.fp, candidate.inst}, candidate} end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp candidate(state, key, entry) do
    txt = state.txt |> Map.get(key, []) |> Dns.txt_map()

    with "1" <- Map.get(txt, "v", "1"),
         {:ok, inst} <- required(txt, "inst"),
         {:ok, node} <- required(txt, "node"),
         {:ok, fp_text} <- required(txt, "fp"),
         {:ok, <<_::256>> = fp} <- Base.url_decode64(fp_text, padding: false) do
      {:ok,
       %{
         name: entry.name,
         inst: inst,
         node: node,
         host: host(state, key, entry),
         port: port(txt["port"]),
         dist_port: port(txt["dport"]),
         fp: fp,
         firmware: txt["fw"],
         device: txt["dev"]
       }}
    else
      _ -> :error
    end
  end

  defp required(txt, key) do
    case txt do
      %{^key => value} when value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp host(state, key, entry) do
    address =
      case state.srv do
        %{^key => %{target: target}} -> Map.get(state.a, Dns.name_key(target), entry.ip)
        _ -> entry.ip
      end

    address |> :inet.ntoa() |> to_string()
  end

  defp port(nil), do: nil

  defp port(text) do
    case Integer.parse(text) do
      {port, ""} when port in 1..65_535 -> port
      _ -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
