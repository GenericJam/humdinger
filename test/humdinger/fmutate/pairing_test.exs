defmodule Humdinger.FMutate.PairingTest do
  # Reference.Pairings is a named singleton (as on FMutate's node).
  use ExUnit.Case, async: false

  alias Humdinger.FMutate.{Cert, Discovery, Pairing}
  alias Humdinger.FMutate.Pairing.Client
  alias Humdinger.FMutate.Reference.{Pairings, PairingServer, Responder}

  defmodule Link do
    @moduledoc false
    # Stands in for Humdinger.FMutate: the record goes to the test process.
    def install(record, test), do: send(test, {:installed, record}) && :ok
  end

  @self_node "humdinger_test@127.0.0.1"

  setup do
    start_supervised!(Pairings)
    :ok
  end

  defp start_server(opts) do
    defaults = [
      cert: Cert.self_signed("FMutate A"),
      ip: {127, 0, 0, 1},
      host: "127.0.0.1",
      node: "fmutate_a@127.0.0.1",
      dist_port: 45_124,
      device: "Studio Mac",
      firmware: "X0X",
      approve: fn _request -> :allow end
    ]

    opts = Keyword.merge(defaults, opts)
    server = start_supervised!({PairingServer, opts}, id: make_ref())
    {server, opts[:cert]}
  end

  defp start_pairing(opts \\ []) do
    defaults = [
      name: nil,
      link: {Link, self()},
      self_node: fn -> @self_node end,
      device_name: "Test phone",
      discovery: fn _ -> {:ok, []} end
    ]

    start_supervised!({Pairing, Keyword.merge(defaults, opts)}, id: make_ref())
  end

  defp target(server, fp \\ nil),
    do: %{host: "127.0.0.1", port: PairingServer.port(server), inst: "a", fp: fp}

  defp identity do
    %{
      app_id: "com.genericjam.humdinger",
      app_name: "Humdinger",
      device_name: "Test phone",
      node: @self_node,
      cert: Cert.self_signed("Humdinger")
    }
  end

  defp code(server) do
    {:ok, code} = Humdinger.FMutate.Code.normalize(PairingServer.code(server))
    code
  end

  test "pairs from the QR link: pinned TLS, token, Allow, a record FMutate recognises" do
    {server, fmutate} = start_server(dist_proto: :inet_tcp)
    pairing = start_pairing()
    {:ok, offer} = Pairing.parse_link(PairingServer.link(server))

    :ok = Pairing.pair(self(), offer, pairing)

    assert_receive {:fmutate_pair, :matched, %{name: "FMutate A", fp: fp}}
    assert fp == fmutate.fp
    assert_receive {:fmutate_pair, :waiting}
    assert_receive {:installed, record}

    assert_receive {:fmutate_pair, :paired,
                    %{name: "FMutate A", device: "Studio Mac", firmware: "X0X", same_phone: true}}

    assert record.fp == fmutate.fp
    assert record.node == "fmutate_a@127.0.0.1"
    assert {record.host, record.dist_port, record.dist_proto} == {"127.0.0.1", 45_124, :inet_tcp}
    assert record.self_node == @self_node

    assert [paired] = Pairings.list()
    assert paired.node == @self_node
    assert paired.cookie == record.cookie
    assert paired.client_fp == Cert.fingerprint(record.cert)
    assert paired.device_name == "Test phone"
  end

  test "pairs by typed code with an FMutate found over mDNS" do
    {server, fmutate} = start_server(advertise: [bind: {{127, 0, 0, 1}, 0}])
    mdns = {{127, 0, 0, 1}, Responder.port(PairingServer.responder(server))}

    pairing =
      start_pairing(
        discovery: &Discovery.browse/1,
        discovery_opts: [targets: [mdns], timeout: 300]
      )

    :ok = Pairing.discover(self(), pairing)
    assert_receive {:fmutate_pair, :found, [candidate]}, 2_000

    assert %{
             name: "FMutate A",
             inst: "a",
             firmware: "X0X",
             device: "Studio Mac",
             node: "fmutate_a@127.0.0.1"
           } = candidate

    assert candidate.fp == fmutate.fp
    assert candidate.port == PairingServer.port(server)

    :ok = Pairing.pair(self(), %{code: String.downcase(PairingServer.code(server))}, pairing)

    assert_receive {:fmutate_pair, :matched, ^candidate}, 2_000
    assert_receive {:fmutate_pair, :waiting}
    assert_receive {:installed, %{fp: fp}}
    assert fp == fmutate.fp
    assert_receive {:fmutate_pair, :paired, %{name: "FMutate A"}}
  end

  test "a typed code tries each FMutate nearby until one knows it" do
    {other, _} = start_server([])
    {server, fmutate} = start_server([])
    candidates = for s <- [other, server], do: candidate(s)
    pairing = start_pairing(discovery: fn _ -> {:ok, candidates} end)

    :ok = Pairing.pair(self(), %{code: PairingServer.code(server)}, pairing)

    assert_receive {:installed, record}, 5_000
    assert record.fp == fmutate.fp
    assert_receive {:fmutate_pair, :paired, _}
    # The other FMutate counted a wrong attempt.
    assert {:error, {:wrong_code, 3}} =
             Client.pair(target(other), {:code, "00000000"}, identity())
  end

  test "five wrong codes invalidate the code and the link; New code starts over" do
    {server, _} = start_server([])
    {:ok, link} = Pairing.parse_link(PairingServer.link(server))

    results = for _ <- 1..5, do: Client.pair(target(server), {:code, "00000000"}, identity())

    assert results == [
             {:error, {:wrong_code, 4}},
             {:error, {:wrong_code, 3}},
             {:error, {:wrong_code, 2}},
             {:error, {:wrong_code, 1}},
             {:error, :too_many_attempts}
           ]

    assert Client.pair(target(server), {:code, code(server)}, identity()) ==
             {:error, :too_many_attempts}

    assert Client.pair(target(server, link.fp), {:token, link.token}, identity()) ==
             {:error, :too_many_attempts}

    :ok = PairingServer.renew(server)
    assert {:ok, _} = Client.pair(target(server), {:code, code(server)}, identity())
  end

  test "a wrong token counts as a failed attempt" do
    {server, fmutate} = start_server([])

    assert Client.pair(target(server, fmutate.fp), {:token, <<0::128>>}, identity()) ==
             {:error, :invalid_token}

    assert {:error, {:wrong_code, 3}} =
             Client.pair(target(server), {:code, "00000000"}, identity())
  end

  test "the secret is single use and expires" do
    {server, _} = start_server(ttl: 200)
    {:ok, link} = Pairing.parse_link(PairingServer.link(server))
    code = code(server)

    assert {:ok, _} = Client.pair(target(server, link.fp), {:token, link.token}, identity())

    assert Client.pair(target(server, link.fp), {:token, link.token}, identity()) ==
             {:error, :expired}

    assert Client.pair(target(server), {:code, code}, identity()) == {:error, :expired}

    :ok = PairingServer.renew(server)
    {:ok, link} = Pairing.parse_link(PairingServer.link(server))
    Process.sleep(250)

    assert Client.pair(target(server, link.fp), {:token, link.token}, identity()) ==
             {:error, :expired}
  end

  test "a link whose fingerprint isn't FMutate's certificate is refused before anything is sent" do
    {server, _} = start_server([])
    {:ok, link} = Pairing.parse_link(PairingServer.link(server))
    impostor = Cert.self_signed("Impostor").fp

    assert Client.pair(target(server, impostor), {:token, link.token}, identity()) ==
             {:error, :fingerprint_mismatch}

    # Nothing reached FMutate: the token is still good.
    assert {:ok, _} = Client.pair(target(server, link.fp), {:token, link.token}, identity())
  end

  test "the player's Deny and Allow" do
    {server, _} = start_server(approve: {:ask, self()})
    pairing = start_pairing()
    {:ok, offer} = Pairing.parse_link(PairingServer.link(server))

    :ok = Pairing.pair(self(), offer, pairing)
    assert_receive {:fmutate_pair_request, ^server, ref, request}

    assert %{
             app_id: "com.genericjam.humdinger",
             app_name: "Humdinger",
             device_name: "Test phone",
             node: @self_node
           } = request

    assert request.remote_ip == {127, 0, 0, 1}
    :ok = PairingServer.decide(server, ref, :deny)
    assert_receive {:fmutate_pair, :failed, :denied}
    refute_received {:installed, _}
    assert Pairings.list() == []

    :ok = PairingServer.renew(server)
    {:ok, offer} = Pairing.parse_link(PairingServer.link(server))
    :ok = Pairing.pair(self(), offer, pairing)
    assert_receive {:fmutate_pair_request, ^server, ref, _}
    :ok = PairingServer.decide(server, ref, :allow)
    assert_receive {:fmutate_pair, :paired, _}
    assert [%{node: @self_node}] = Pairings.list()
  end

  test "cancelling withdraws the request on FMutate" do
    {server, _} = start_server(approve: {:ask, self()})
    pairing = start_pairing()
    {:ok, offer} = Pairing.parse_link(PairingServer.link(server))

    :ok = Pairing.pair(self(), offer, pairing)
    assert_receive {:fmutate_pair, :waiting}
    assert_receive {:fmutate_pair_request, ^server, ref, _}

    :ok = Pairing.cancel(pairing)
    assert_receive {:fmutate_pair_withdrawn, ^server, ^ref}, 2_000
    refute_received {:fmutate_pair, :failed, _}
  end

  test "a typed code with no FMutate showing its code nearby" do
    pairing = start_pairing(discovery: fn _ -> {:ok, [%{candidate(nil) | port: nil}]} end)
    :ok = Pairing.pair(self(), %{code: "KQ7M-X2PD"}, pairing)
    assert_receive {:fmutate_pair, :failed, :not_found}
    assert Pairing.pair(self(), %{code: "KQ7M"}, pairing) == {:error, :invalid_code}
  end

  describe "carriers" do
    test "a sibling on another phone is always granted TLS distribution" do
      lan = lan_ip()
      {server, fmutate} = start_server(ip: {0, 0, 0, 0}, host: lan, dist_proto: :inet_tls)
      {:ok, link} = Pairing.parse_link(PairingServer.link(server))

      assert {:ok, record} =
               Client.pair(
                 %{target(server, fmutate.fp) | host: lan},
                 {:token, link.token},
                 identity()
               )

      assert {record.dist_proto, record.host} == {:inet_tls, lan}
    end

    test "an FMutate with plain distribution pairs only apps on its own phone" do
      lan = lan_ip()
      {server, fmutate} = start_server(ip: {0, 0, 0, 0}, host: lan, dist_proto: :inet_tcp)
      {:ok, link} = Pairing.parse_link(PairingServer.link(server))
      remote = %{target(server, fmutate.fp) | host: lan}

      assert Client.pair(remote, {:token, link.token}, identity()) == {:error, :loopback_only}
      # Turned away before authenticating: the token is still good on loopback.
      assert {:ok, record} =
               Client.pair(target(server, fmutate.fp), {:token, link.token}, identity())

      assert {record.dist_proto, record.host} == {:inet_tcp, "127.0.0.1"}
    end

    test "plain distribution on a network address refuses to start" do
      opts = [
        cert: Cert.self_signed("FMutate A"),
        ip: {127, 0, 0, 1},
        dist_port: 1,
        dist_proto: :inet_tcp,
        dist_host: "192.168.1.23"
      ]

      assert {:error, {:plain_distribution_off_loopback, _}} =
               start_supervised({PairingServer, opts})
    end
  end

  describe "requests" do
    test "a sibling can't take FMutate's node name or any fmutate_ name" do
      {server, _} = start_server([])

      for node <- ["fmutate_a@127.0.0.1", "fmutate_b@10.0.0.1"] do
        :ok = PairingServer.renew(server)

        assert Client.pair(target(server), {:code, code(server)}, %{identity() | node: node}) ==
                 {:error, :bad_node}
      end

      assert Pairings.list() == []
    end

    test "the Allow sheet gets clean names and is told when a pairing would be replaced" do
      {server, _} = start_server(approve: {:ask, self()})
      sneaky = %{identity() | device_name: "Pixel\n7\u202E", app_name: "Hum\u200Bdinger"}
      test = self()

      spawn(fn ->
        send(test, {:first, Client.pair(target(server), {:code, code(server)}, sneaky)})
      end)

      assert_receive {:fmutate_pair_request, ^server, ref, request}

      assert {request.app_name, request.device_name, request.replaces} ==
               {"Humdinger", "Pixel7", nil}

      :ok = PairingServer.decide(server, ref, :allow)
      assert_receive {:first, {:ok, _}}

      :ok = PairingServer.renew(server)
      spawn(fn -> Client.pair(target(server), {:code, code(server)}, identity()) end)
      assert_receive {:fmutate_pair_request, ^server, ref, request}
      assert %{app_name: "Humdinger", device_name: "Pixel7"} = request.replaces
      :ok = PairingServer.decide(server, ref, :deny)
    end

    test "the code and token stay out of the server's status and crash reports" do
      {server, _} = start_server([])
      {:ok, link} = Pairing.parse_link(PairingServer.link(server))
      shown = inspect(:sys.get_status(server), limit: :infinity, printable_limit: :infinity)
      refute shown =~ code(server)
      refute shown =~ inspect(link.token, limit: :infinity)
    end
  end

  test "the TLS distribution option file (FMutate's private key) is private to its owner" do
    path = Path.join(System.tmp_dir!(), "optfile_#{System.unique_integer([:positive])}.conf")
    on_exit(fn -> File.rm(path) end)
    assert Pairings.write_ssl_dist_optfile(path, Cert.self_signed("FMutate A")) == :ok
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  defp lan_ip do
    {:ok, interfaces} = :inet.getifaddrs()

    ip =
      Enum.find_value(interfaces, fn {_name, opts} ->
        Enum.find(Keyword.get_values(opts, :addr), &match?({a, _, _, _} when a != 127, &1))
      end) || flunk("needs a non-loopback IPv4 address")

    ip |> :inet.ntoa() |> List.to_string()
  end

  defp candidate(nil),
    do: %{
      name: "FMutate A",
      inst: "a",
      node: "fmutate_a@127.0.0.1",
      host: "127.0.0.1",
      port: 1,
      dist_port: nil,
      fp: <<0::256>>,
      firmware: nil,
      device: nil
    }

  defp candidate(server), do: %{candidate(nil) | port: PairingServer.port(server)}
end
