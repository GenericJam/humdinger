defmodule Humdinger.FMutate.DistTest do
  @moduledoc false
  # End to end against a real second BEAM: FMutate's reference stack runs in
  # a :peer node with no epmd (Reference.Epmd, a fixed port), and this test
  # VM is Humdinger: it pairs over TLS, starts its own hidden node without a
  # listener, and connects with the per-app cookie. These tests start and
  # stop distribution in this VM, so they run alone.
  use ExUnit.Case, async: false

  alias Humdinger.FMutate
  alias Humdinger.FMutate.{Cert, Epmd, Pairing, Record, Store, Transport, Tunnel}
  alias Humdinger.FMutate.Reference
  alias Humdinger.FMutate.Reference.{Instance, Pairings, PairingServer}

  @moduletag :capture_log
  @firmware [%{id: "x0x", name: "X0X", version: "1.0", status: :running}]

  setup do
    :ok = Transport.setup()

    on_exit(fn ->
      if Node.alive?(), do: :net_kernel.stop()
      :application.unset_env(:kernel, :dist_auto_connect)
      :persistent_term.erase({Epmd, :routes})
    end)

    :ok
  end

  defp start_fmutate(proto) do
    port = free_port()
    name = "fmutate_t#{System.unique_integer([:positive])}"
    cert = Cert.self_signed("FMutate A")

    optfile = Path.join(System.tmp_dir!(), "#{name}_ssl_dist.conf")

    if proto == :inet_tls do
      :ok = Pairings.write_ssl_dist_optfile(optfile, cert)
      on_exit(fn -> File.rm(optfile) end)
    end

    boot = Reference.boot_args(dist_port: port, dist_proto: proto, ssl_dist_optfile: optfile)

    args =
      Enum.map(boot, &String.to_charlist/1) ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start(%{
        name: String.to_atom(name),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: args
      })

    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ssl])
    # The player taps Allow (a module the peer can run).
    :peer.call(peer, Code, :compile_string, [
      "defmodule FMutateTestPlayer, do: def(allow(_), do: :allow)"
    ])

    pairing = [
      cert: cert,
      ip: {127, 0, 0, 1},
      host: "127.0.0.1",
      node: Atom.to_string(node),
      dist_port: port,
      dist_proto: proto,
      device: "Studio Mac",
      firmware: "X0X",
      approve: Function.capture(FMutateTestPlayer, :allow, 1)
    ]

    {:ok, _} =
      :peer.call(peer, Reference, :start, [[instance: [firmware: @firmware], pairing: pairing]])

    %{peer: peer, node: node, port: port, cert: cert}
  end

  defp start_humdinger(discovery \\ fn _ -> {:ok, []} end) do
    key = "test.dist.#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete(key: key) end)

    link =
      start_supervised!(
        {FMutate, name: nil, store: {Store, key: key}, grace_ms: 0, backoff: [100, 200, 400]}
      )

    pairing =
      start_supervised!(
        {Pairing,
         name: nil, link: {FMutate, link}, device_name: "Test phone", discovery: discovery}
      )

    :ok = FMutate.subscribe(self(), link)
    assert_receive {:fmutate, :status, :unpaired}
    %{link: link, pairing: pairing, key: key}
  end

  defp await_status(match?, timeout \\ 10_000) do
    receive do
      {:fmutate, :status, status} ->
        if match?.(status), do: status, else: await_status(match?, timeout)
    after
      timeout -> flunk("no matching status within #{timeout} ms")
    end
  end

  defp connected?(status), do: match?({:connected, _}, status)

  defp inputs(peer), do: :peer.call(peer, Instance, :inputs, [])

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "same phone: pair from the link, connect over loopback with the per-app cookie, play, follow FMutate" do
    fmutate = start_fmutate(:inet_tcp)
    humdinger = start_humdinger()

    {:ok, offer} =
      Pairing.parse_link(:peer.call(fmutate.peer, PairingServer, :link, [PairingServer]))

    :ok = Pairing.pair(self(), offer, humdinger.pairing)
    assert_receive {:fmutate_pair, :paired, %{same_phone: true}}, 5_000

    assert {:connected, %{name: "FMutate A", firmware: "X0X", device: "Studio Mac"}} =
             await_status(&connected?/1)

    me = node()

    assert {:ok, %Record{self_node: self_node, dist_proto: :inet_tcp}} =
             Store.load(key: humdinger.key)

    assert Atom.to_string(me) == self_node
    # A hidden connection on both sides.
    assert fmutate.node in Node.list(:hidden)
    refute fmutate.node in Node.list()
    assert me in :peer.call(fmutate.peer, :erlang, :nodes, [:hidden])
    # Neither node is in an epmd.
    assert_no_epmd([me, fmutate.node])

    FMutate.send_midi(<<0x90, 60, 100>>, humdinger.link)
    eventually(fn -> {:midi, <<0x90, 60, 100>>} in inputs(fmutate.peer) end)

    :ok = :peer.call(fmutate.peer, Instance, :set_status, [:crashed])

    assert {:connected, %{emulator: :crashed}} =
             await_status(&match?({:connected, %{emulator: :crashed}}, &1))

    # FMutate drops the connection (e.g. it restarted): the link comes back.
    true = :peer.call(fmutate.peer, :erlang, :disconnect_node, [me])
    assert :disconnected = await_status(&(&1 == :disconnected))
    assert {:connected, _} = await_status(&connected?/1)
    FMutate.send_midi(<<0x80, 60, 0>>, humdinger.link)
    eventually(fn -> {:midi, <<0x80, 60, 0>>} in inputs(fmutate.peer) end)

    # The player taps Disconnect on FMutate: the cookie is gone, so the link
    # can't get back in.
    :ok = :peer.call(fmutate.peer, Pairings, :revoke, [me])
    assert :disconnected = await_status(&(&1 == :disconnected))
    refute_receive {:fmutate, :status, {:connected, _}}, 1_000
    assert FMutate.status(humdinger.link) == :disconnected
  end

  test "another phone: pair by code, TLS distribution through the tunnel, forget revokes both sides" do
    fmutate = start_fmutate(:inet_tls)

    {:ok, code} =
      Humdinger.FMutate.Code.normalize(
        :peer.call(fmutate.peer, PairingServer, :code, [PairingServer])
      )

    port = :peer.call(fmutate.peer, PairingServer, :port, [PairingServer])

    candidate = %{
      name: "FMutate A",
      inst: "a",
      node: Atom.to_string(fmutate.node),
      host: "127.0.0.1",
      port: port,
      dist_port: fmutate.port,
      fp: fmutate.cert.fp,
      firmware: "X0X",
      device: "Studio Mac"
    }

    humdinger = start_humdinger(fn _ -> {:ok, [candidate]} end)
    :ok = Pairing.pair(self(), %{code: code}, humdinger.pairing)
    assert_receive {:fmutate_pair, :matched, ^candidate}, 5_000
    assert_receive {:fmutate_pair, :paired, _}, 5_000
    assert {:connected, %{firmware: "X0X"}} = await_status(&connected?/1)

    assert {:ok, %Record{dist_proto: :inet_tls} = record} = Store.load(key: humdinger.key)
    me = node()
    assert fmutate.node in Node.list(:hidden)
    assert_no_epmd([me, fmutate.node])

    FMutate.send_midi(<<0x90, 64, 90>>, humdinger.link)
    big = :crypto.strong_rand_bytes(100_000)
    FMutate.send_midi(big, humdinger.link)
    eventually(fn -> {:midi, big} in inputs(fmutate.peer) end)
    assert {:midi, <<0x90, 64, 90>>} in inputs(fmutate.peer)

    # TLS distribution only admits the client certificate FMutate pinned (TLS
    # 1.3 checks it after the client's handshake, so FMutate aborts the
    # session), and Humdinger's tunnel only talks to FMutate's certificate.
    intruder = Cert.self_signed("Intruder")

    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", fmutate.port, intruder_options(record, intruder), 5_000)

    assert {:error, _} = :ssl.recv(socket, 0, 5_000)
    assert {:error, {:tls, _}} = Tunnel.open(%{record | fp: intruder.fp}, self())

    assert :ok = FMutate.forget(humdinger.link)
    assert :unpaired = await_status(&(&1 == :unpaired))
    assert Store.load(key: humdinger.key) == :none
    refute fmutate.node in Node.list(:connected)
    eventually(fn -> :peer.call(fmutate.peer, Pairings, :list, []) == [] end)
  end

  defp intruder_options(record, intruder) do
    [
      verify: :verify_peer,
      cacerts: [],
      verify_fun: Cert.verify_fun(record.fp),
      certs_keys: [Cert.ssl_cert_key(intruder.cert, intruder.key)],
      versions: [:"tlsv1.3"],
      active: false
    ]
  end

  test "FMutate refuses distribution under any unpaired name, even with its default cookie" do
    fmutate = start_fmutate(:inet_tcp)
    default_cookie = :peer.call(fmutate.peer, :erlang, :get_cookie, [])

    {:ok, intruder, _} =
      :peer.start(%{
        name: :"intruder_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args:
          [
            ~c"-setcookie",
            Atom.to_charlist(default_cookie),
            ~c"-epmd_module",
            ~c"Elixir.Humdinger.FMutate.Epmd"
          ] ++
            Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    on_exit(fn -> if Process.alive?(intruder), do: :peer.stop(intruder) end)
    :ok = :peer.call(intruder, Epmd, :put_route, [fmutate.node, {{127, 0, 0, 1}, fmutate.port}])

    refute :peer.call(intruder, :net_kernel, :connect_node, [fmutate.node])
    # FMutate's plain listener (and so every socket on its port) is on loopback only.
    on_port = tcp_sockets(fmutate.peer) |> Enum.filter(&match?({_, p} when p == fmutate.port, &1))
    assert on_port != []
    assert Enum.all?(on_port, &match?({{127, 0, 0, 1}, _}, &1))
  end

  defp tcp_sockets(peer) do
    for port <- :peer.call(peer, :erlang, :ports, []),
        :peer.call(peer, :erlang, :port_info, [port, :name]) == {:name, ~c"tcp_inet"},
        {:ok, address} <- [:peer.call(peer, :inet, :sockname, [port])],
        do: address
  end

  defp assert_no_epmd(nodes) do
    case :erl_epmd.names(~c"127.0.0.1") do
      {:ok, names} ->
        registered = for {name, _port} <- names, do: List.to_string(name)
        for node <- nodes, do: refute(hd(String.split(Atom.to_string(node), "@")) in registered)

      {:error, _no_epmd} ->
        :ok
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
