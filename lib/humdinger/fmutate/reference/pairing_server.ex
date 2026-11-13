defmodule Humdinger.FMutate.Reference.PairingServer do
  @moduledoc """
  FMutate's pairing endpoint (reference for protocol §1.1–1.5): what runs
  while FMutate's "Pair an app" screen is open.

  It holds one pairing secret, shown as a code (`code/1`, `KQ7M-X2PD`) and a
  link (`link/1`, the QR payload), both single use, valid for 5 minutes and
  invalidated after 5 failed attempts (wrong codes and wrong tokens count
  alike); `renew/1` is "New code". It listens with TLS 1.3 presenting
  FMutate's certificate, runs the exchange of §1.5 with each sibling (token
  or SRP-6a), asks the player (`:approve`), and on Allow registers the
  sibling in `Humdinger.FMutate.Reference.Pairings` and returns the grant.
  With `:advertise` it also announces itself over mDNS
  (`Humdinger.FMutate.Reference.Responder`) with the TXT keys of §1.5.

  Stopping the server stops pairing and advertising. Siblings that connect
  from loopback are granted `127.0.0.1` as the distribution host; others get
  `:dist_host`.

  The approval hook is `:approve`: a function of the request returning
  `:allow` or `:deny` (it runs in the connection's process and may block), or
  `{:ask, pid}`, which sends `pid`
  `{:fmutate_pair_request, server, ref, request}` and waits for
  `decide(server, ref, :allow | :deny)`; if the sibling hangs up first,
  `pid` gets `{:fmutate_pair_withdrawn, server, ref}`. The request is
  `%{app_id, app_name, device_name, node, client_fp, remote_ip}`.
  """

  use GenServer

  alias Humdinger.FMutate.{Cert, Code, PairLink, Record, Srp, Wire}
  alias Humdinger.FMutate.Reference.{Pairings, Responder}

  @ttl 300_000
  @max_attempts 5
  @step_timeout 30_000
  @decision_timeout 120_000

  @doc """
  Options: `:cert` (FMutate's `Humdinger.FMutate.Cert`, required),
  `:dist_port` (required), `:dist_proto` (`:inet_tcp` default, or
  `:inet_tls`), `:dist_host` (default `:host`), `:inst` (`"a"`), `:name`
  (`"FMutate A"`), `:device`, `:firmware`, `:node` (FMutate's node name,
  default `node()`), `:ip` / `:port` to listen on (`{0, 0, 0, 0}`, 0),
  `:host` (the address put in the link; default the first non-loopback IPv4
  address), `:ttl` (ms), `:max_attempts`, `:approve`, `:advertise` (Responder
  options such as `:bind`, or `false`), `:server_name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :server_name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "The code to show, `KQ7M-X2PD`."
  @spec code(GenServer.server()) :: String.t()
  def code(server), do: GenServer.call(server, :code)

  @doc "The link to show as a QR code and under Copy link."
  @spec link(GenServer.server()) :: String.t()
  def link(server), do: GenServer.call(server, :link)

  @doc "The pairing port."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "The mDNS responder advertising this endpoint (`:advertise`), or nil."
  @spec responder(GenServer.server()) :: pid() | nil
  def responder(server), do: GenServer.call(server, :responder)

  @doc "New code: a fresh secret, attempts reset."
  @spec renew(GenServer.server()) :: :ok
  def renew(server), do: GenServer.call(server, :renew)

  @doc "The player's answer to a `{:fmutate_pair_request, server, ref, request}`."
  @spec decide(GenServer.server(), reference(), :allow | :deny) :: :ok
  def decide(server, ref, decision) when decision in [:allow, :deny],
    do: GenServer.call(server, {:decide, ref, decision})

  @impl true
  def init(opts) do
    cert = Keyword.fetch!(opts, :cert)
    host = Keyword.get_lazy(opts, :host, &default_host/0)
    {:ok, _} = Application.ensure_all_started(:ssl)

    listen_options =
      [
        certs_keys: [Cert.ssl_cert_key(cert.cert, cert.key)],
        ip: Keyword.get(opts, :ip, {0, 0, 0, 0}),
        reuseaddr: true
      ] ++ Wire.socket_options()

    {:ok, listen} = :ssl.listen(Keyword.get(opts, :port, 0), listen_options)
    {:ok, {_, port}} = :ssl.sockname(listen)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(server, listen) end)

    config = %{
      cert: cert,
      inst: Keyword.get(opts, :inst, "a"),
      name: Keyword.get(opts, :name, "FMutate A"),
      device: Keyword.get_lazy(opts, :device, &hostname/0),
      firmware: Keyword.get(opts, :firmware),
      node: Keyword.get_lazy(opts, :node, fn -> Atom.to_string(node()) end),
      host: host,
      port: port,
      dist_host: Keyword.get(opts, :dist_host, host),
      dist_port: Keyword.fetch!(opts, :dist_port),
      dist_proto: Keyword.get(opts, :dist_proto, :inet_tcp),
      approve: Keyword.get(opts, :approve, fn _request -> :deny end)
    }

    state = %{
      config: config,
      listen: listen,
      acceptor: acceptor,
      ttl: Keyword.get(opts, :ttl, @ttl),
      max_attempts: Keyword.get(opts, :max_attempts, @max_attempts),
      secret: nil,
      asks: %{},
      responder: nil
    }

    state = renew_secret(state)
    {:ok, advertise(state, Keyword.get(opts, :advertise, false))}
  end

  @impl true
  def handle_call(:code, _from, state), do: {:reply, Code.format(state.secret.code), state}

  def handle_call(:link, _from, %{config: c} = state) do
    link =
      PairLink.build(%{
        inst: c.inst,
        node: short_name(c.node),
        host: c.host,
        port: c.port,
        fp: c.cert.fp,
        token: state.secret.token
      })

    {:reply, link, state}
  end

  def handle_call(:port, _from, state), do: {:reply, state.config.port, state}
  def handle_call(:responder, _from, state), do: {:reply, state.responder, state}
  def handle_call(:renew, _from, state), do: {:reply, :ok, renew_secret(state)}
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call({:check_token, token}, _from, state) do
    case usable(state) do
      :ok ->
        if Srp.same?(token, state.secret.token),
          do: {:reply, :ok, consume(state)},
          else: failed(state, "invalid_token")

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:srp_params, _from, state) do
    case usable(state) do
      :ok ->
        salt = Srp.salt()
        {:reply, {:ok, salt, Srp.verifier(state.secret.code, salt)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:srp_result, proof_ok?}, _from, state) do
    case usable(state) do
      :ok -> if proof_ok?, do: {:reply, :ok, consume(state)}, else: failed(state, "wrong_code")
      error -> {:reply, error, state}
    end
  end

  def handle_call({:ask, request}, {handler, _}, %{config: %{approve: {:ask, pid}}} = state) do
    ref = make_ref()
    send(pid, {:fmutate_pair_request, self(), ref, request})
    {:reply, {:ok, ref}, put_in(state.asks[ref], handler)}
  end

  def handle_call({:decide, ref, decision}, _from, state) do
    {handler, asks} = Map.pop(state.asks, ref)
    if handler, do: send(handler, {:decision, ref, decision})
    {:reply, :ok, %{state | asks: asks}}
  end

  def handle_call({:withdraw, ref}, _from, %{config: %{approve: {:ask, pid}}} = state) do
    {handler, asks} = Map.pop(state.asks, ref)
    if handler, do: send(pid, {:fmutate_pair_withdrawn, self(), ref})
    {:reply, :ok, %{state | asks: asks}}
  end

  @impl true
  def terminate(_reason, state) do
    :ssl.close(state.listen)
    if state.responder, do: Responder.stop(state.responder)
  end

  # The secret: usable while open and unexpired.
  defp renew_secret(state) do
    secret = %{
      code: Code.generate(),
      token: :crypto.strong_rand_bytes(16),
      expires_at: System.monotonic_time(:millisecond) + state.ttl,
      attempts: 0,
      status: :open
    }

    %{state | secret: secret}
  end

  defp usable(%{secret: %{status: :invalid}}), do: {:error, "too_many_attempts"}
  defp usable(%{secret: %{status: :used}}), do: {:error, "expired"}

  defp usable(%{secret: secret}) do
    if System.monotonic_time(:millisecond) < secret.expires_at, do: :ok, else: {:error, "expired"}
  end

  defp consume(state), do: put_in(state.secret.status, :used)

  defp failed(state, reason) do
    attempts = state.secret.attempts + 1
    left = state.max_attempts - attempts

    secret = %{
      state.secret
      | attempts: attempts,
        status: if(left <= 0, do: :invalid, else: :open)
    }

    reply =
      cond do
        left <= 0 -> {:error, "too_many_attempts"}
        reason == "wrong_code" -> {:error, "wrong_code", left}
        true -> {:error, reason}
      end

    {:reply, reply, %{state | secret: secret}}
  end

  defp advertise(state, false), do: state

  defp advertise(%{config: c} = state, opts) do
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(c.host))

    txt =
      %{
        "v" => "1",
        "inst" => c.inst,
        "node" => c.node,
        "fp" => Wire.b64(c.cert.fp),
        "port" => Integer.to_string(c.port),
        "dport" => Integer.to_string(c.dist_port),
        "fw" => c.firmware,
        "dev" => c.device
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    responder_opts =
      Keyword.merge(
        [
          instance: c.name,
          hostname: "fmutate-#{c.inst}.local",
          address: address,
          srv_port: c.port,
          txt: txt
        ],
        opts
      )

    {:ok, responder} = Responder.start_link(responder_opts)
    %{state | responder: responder}
  end

  defp accept_loop(server, listen) do
    case :ssl.transport_accept(listen) do
      {:ok, socket} ->
        handler =
          spawn(fn ->
            receive do
              :go -> handle_connection(server, socket)
            end
          end)

        case :ssl.controlling_process(socket, handler) do
          :ok -> send(handler, :go)
          {:error, _} -> Process.exit(handler, :kill)
        end

        accept_loop(server, listen)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(server, listen)
    end
  end

  # One sibling's exchange, in its own process.
  defp handle_connection(server, transport_socket) do
    with {:ok, socket} <- :ssl.handshake(transport_socket, @step_timeout) do
      config = GenServer.call(server, :config)

      case exchange(server, socket, config) do
        :ok -> :ok
        {:error, message} -> Wire.send(socket, message)
      end

      :ssl.close(socket)
    end
  end

  defp exchange(server, socket, config) do
    with {:ok, hello} <- recv(socket),
         :ok <- check_hello(hello, config),
         :ok <- authenticate(server, socket, config, hello),
         {:ok, request} <- recv_request(socket),
         {:ok, request} <- describe(socket, request),
         :ok <- Wire.send(socket, %{"type" => "pending"}),
         :allow <- decide(server, socket, config, request) do
      grant(socket, config, request)
    else
      :deny -> {:error, Wire.error("denied")}
      {:error, %{"type" => "error"}} = error -> error
      {:error, :timeout} -> {:error, Wire.error("timeout")}
      {:error, _closed_or_bad} -> {:error, Wire.error("bad_message")}
    end
  end

  defp check_hello(%{"type" => "hello", "v" => 1, "inst" => inst}, %{inst: inst}), do: :ok

  defp check_hello(%{"type" => "hello", "v" => 1}, _config),
    do: {:error, Wire.error("no_such_instance")}

  defp check_hello(%{"type" => "hello"}, _config), do: {:error, Wire.error("unsupported_version")}
  defp check_hello(_message, _config), do: {:error, Wire.error("bad_message")}

  defp authenticate(server, socket, _config, %{"auth" => "token", "token" => token}) do
    with {:ok, token} <- decode(token, size: 16),
         :ok <- secret_call(server, {:check_token, token}) do
      Wire.send(socket, %{"type" => "welcome"})
    end
  end

  defp authenticate(server, socket, config, %{"auth" => "srp", "A" => a}) do
    with {:ok, a_pub} <- decode(a, max: 256),
         true <- Srp.valid_public?(a_pub) || {:error, Wire.error("bad_message")},
         {:ok, salt, verifier} <- secret_call(server, :srp_params),
         {b_pub, _} = keys = Srp.server_keys(verifier),
         :ok <-
           Wire.send(socket, %{
             "type" => "challenge",
             "salt" => Wire.b64(salt),
             "B" => Wire.b64(b_pub)
           }),
         {:ok, %{"type" => "proof", "M1" => m1}} <- recv(socket),
         {:ok, m1} <- decode(m1, size: 32),
         {:ok, key} <- Srp.server_key(verifier, a_pub, keys),
         {:ok, binding} <- Wire.channel_binding(socket),
         expected = Srp.client_proof(key, config.cert.fp, binding, a_pub, b_pub),
         :ok <- secret_call(server, {:srp_result, Srp.same?(m1, expected)}) do
      m2 = Srp.server_proof(key, config.cert.fp, binding, a_pub, b_pub, m1)
      Wire.send(socket, %{"type" => "welcome", "M2" => Wire.b64(m2)})
    else
      {:error, _} = error -> error
      _ -> {:error, Wire.error("bad_message")}
    end
  end

  defp authenticate(_server, _socket, _config, _hello), do: {:error, Wire.error("bad_message")}

  defp secret_call(server, request) do
    case GenServer.call(server, request) do
      {:error, "wrong_code", left} ->
        {:error, Wire.error("wrong_code", %{"attempts_left" => left})}

      {:error, reason} ->
        {:error, Wire.error(reason)}

      other ->
        other
    end
  end

  defp recv_request(socket) do
    with {:ok, %{"type" => "request"} = m} <- recv(socket),
         true <-
           text?(m["app_id"], 1, 200) and text?(m["app_name"], 1, 100) and
             text?(m["device_name"], 0, 100),
         true <- Record.self_node?(m["node"]),
         {:ok, cert} <- decode(m["client_cert"], max: 4096) do
      {:ok,
       %{
         app_id: m["app_id"],
         app_name: m["app_name"],
         device_name: m["device_name"],
         node: m["node"],
         client_fp: Cert.fingerprint(cert)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, Wire.error("bad_message")}
    end
  end

  defp describe(socket, request) do
    {:ok, {ip, _}} = :ssl.peername(socket)
    {:ok, Map.put(request, :remote_ip, ip)}
  end

  defp decide(_server, _socket, %{approve: fun}, request) when is_function(fun, 1),
    do: fun.(request)

  defp decide(server, socket, %{approve: {:ask, _pid}}, request) do
    {:ok, ref} = GenServer.call(server, {:ask, request})
    :ok = :ssl.setopts(socket, active: :once)

    receive do
      {:decision, ^ref, decision} ->
        decision

      {closed, ^socket} when closed in [:ssl_closed, :ssl_error] ->
        GenServer.call(server, {:withdraw, ref})
        {:error, :closed}
    after
      @decision_timeout ->
        GenServer.call(server, {:withdraw, ref})
        {:error, :timeout}
    end
  end

  defp grant(socket, config, request) do
    {:ok, pairing} =
      Pairings.add(Map.take(request, [:node, :app_id, :app_name, :device_name, :client_fp]))

    loopback? = match?({127, _, _, _}, request.remote_ip)

    Wire.send(socket, %{
      "type" => "granted",
      "inst" => config.inst,
      "name" => config.name,
      "device" => config.device,
      "firmware" => config.firmware,
      "node" => config.node,
      "dist_host" => if(loopback?, do: "127.0.0.1", else: config.dist_host),
      "dist_port" => config.dist_port,
      "dist_proto" => Atom.to_string(config.dist_proto),
      "cookie" => pairing.cookie
    })
  end

  defp recv(socket) do
    case Wire.recv(socket, @step_timeout) do
      {:ok, %{"type" => "error"}} -> {:error, :closed}
      other -> other
    end
  end

  defp decode(value, opts) do
    case Wire.unb64(value, opts) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, Wire.error("bad_message")}
    end
  end

  defp text?(value, min, max), do: is_binary(value) and String.length(value) in min..max

  defp short_name(node), do: node |> String.split("@") |> hd()

  defp default_host do
    {:ok, addresses} = :inet.getifaddrs()

    addresses
    |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
    |> Enum.find(&match?({a, _, _, _} when a != 127, &1))
    |> case do
      nil -> "127.0.0.1"
      ip -> ip |> :inet.ntoa() |> List.to_string()
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
