defmodule Humdinger.FMutate.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Humdinger.FMutate.{Discovery, Dns}
  alias Humdinger.FMutate.Reference.Responder

  @fp :crypto.hash(:sha256, "fmutate cert")
  @fp_text Base.url_encode64(@fp, padding: false)
  @service ["_fmutate", "_tcp", "local"]
  @timeout 200

  defp txt(extra \\ %{}) do
    Map.merge(
      %{
        "v" => "1",
        "inst" => "a",
        "node" => "fmutate_a@192.168.1.23",
        "fp" => @fp_text,
        "port" => "45123",
        "dport" => "45200",
        "fw" => "X0X",
        "dev" => "Pixel 7"
      },
      extra
    )
  end

  defp responder(opts), do: opts |> start_responder() |> target()

  defp target(pid), do: {{127, 0, 0, 1}, Responder.port(pid)}

  defp start_responder(opts) do
    opts =
      Keyword.merge(
        [
          instance: "FMutate A",
          hostname: "fmutate-a.local",
          address: {192, 168, 1, 23},
          srv_port: 45_123,
          txt: txt(),
          bind: {{127, 0, 0, 1}, 0}
        ],
        opts
      )

    start_supervised!({Responder, opts}, id: make_ref())
  end

  defp browse(targets), do: Discovery.browse(targets: targets, timeout: @timeout)

  # A loopback responder that answers each query with `fun.(query)`, a list
  # of datagrams.
  defp fake(fun) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
        send(test, {:fake_port, :inet.port(socket)})
        fake_loop(socket, fun)
      end)

    assert_receive {:fake_port, {:ok, port}}
    on_exit(fn -> Process.exit(pid, :kill) end)
    {{127, 0, 0, 1}, port}
  end

  defp fake_loop(socket, fun) do
    receive do
      {:udp, ^socket, ip, port, data} ->
        {:ok, query} = Dns.decode(data)
        Enum.each(fun.(query), &:gen_udp.send(socket, ip, port, &1))
        fake_loop(socket, fun)
    end
  end

  defp record(name, type, data), do: %{name: name, type: type, ttl: 10, data: data}

  defp answer(instance, txt_map, a? \\ true) do
    name = [instance | @service]

    Dns.encode_response(%{
      answers: [record(@service, :ptr, name)],
      additionals:
        [
          record(name, :srv, %{port: 1, target: ["h", "local"]}),
          record(name, :txt, Dns.txt_strings(txt_map))
        ] ++ if(a?, do: [record(["h", "local"], :a, {10, 0, 0, 9})], else: [])
    })
  end

  test "finds the reference responder and returns the exact candidate" do
    target = responder([])

    assert browse([target]) ==
             {:ok,
              [
                %{
                  name: "FMutate A",
                  inst: "a",
                  node: "fmutate_a@192.168.1.23",
                  host: "192.168.1.23",
                  port: 45_123,
                  dist_port: 45_200,
                  fp: @fp,
                  firmware: "X0X",
                  device: "Pixel 7"
                }
              ]}
  end

  test "optional keys are nil when absent or invalid; v missing counts as 1" do
    txt = txt() |> Map.drop(["v", "fw", "dev", "dport"]) |> Map.put("port", "70000")
    target = responder(txt: txt)

    assert {:ok, [candidate]} = browse([target])
    assert %{port: nil, dist_port: nil, firmware: nil, device: nil, inst: "a"} = candidate
  end

  test "update_txt changes what the next browse sees" do
    pid = start_responder([])
    :ok = Responder.update_txt(pid, Map.delete(txt(), "port"))
    assert {:ok, [%{port: nil}]} = browse([target(pid)])
  end

  test "other services, wrong versions, bad fingerprints and missing keys are dropped" do
    other = responder(service: "_other._tcp.local")
    v2 = responder(instance: "V2", txt: txt(%{"v" => "2"}))
    short_fp = responder(instance: "Short", txt: txt(%{"fp" => Base.url_encode64("x")}))
    bad_fp = responder(instance: "Bad", txt: txt(%{"fp" => "!!!"}))
    no_inst = responder(instance: "NoInst", txt: Map.delete(txt(), "inst"))
    no_node = responder(instance: "NoNode", txt: txt(%{"node" => ""}))

    assert browse([other, v2, short_fp, bad_fp, no_inst, no_node]) == {:ok, []}
  end

  test "malformed datagrams and queries are ignored next to a good answer" do
    target =
      fake(fn _query ->
        [
          <<1, 2, 3>>,
          :binary.copy(<<0xFF>>, 9001),
          <<0::16, 0x8400::16, 1::16, 0::16, 0::16, 0::16, 0b11::2, 12::14, 12::16, 1::16>>,
          Dns.encode_query([%{name: @service, type: :ptr}]),
          answer("FMutate A", txt())
        ]
      end)

    assert {:ok, [%{name: "FMutate A", host: "10.0.0.9"}]} = browse([target])
  end

  test "deduplicates by fp and inst, keeps distinct instances, orders by name" do
    a = responder(instance: "FMutate A")
    a2 = responder(instance: "FMutate A (2)")
    b = responder(instance: "Beta", txt: txt(%{"inst" => "b"}))

    assert {:ok, [%{name: "Beta", inst: "b"}, %{inst: "a"}]} = browse([a, a2, b])
  end

  test "the latest answer for the same fp and inst wins" do
    target =
      fake(fn _query ->
        [answer("Old", txt(%{"fw" => "old"})), answer("New", txt(%{"fw" => "new"}))]
      end)

    assert {:ok, [%{name: "New", firmware: "new"}]} = browse([target])
  end

  test "asks for SRV, TXT and A when the PTR answer comes alone" do
    instance = ["FMutate A" | @service]

    target =
      fake(fn %{questions: questions} ->
        Enum.map(questions, fn
          %{type: :ptr} ->
            Dns.encode_response(%{answers: [record(@service, :ptr, instance)]})

          %{type: :srv} ->
            srv = %{port: 1, target: ["far", "local"]}
            Dns.encode_response(%{answers: [record(instance, :srv, srv)]})

          %{type: :txt} ->
            Dns.encode_response(%{answers: [record(instance, :txt, Dns.txt_strings(txt()))]})

          %{type: :a} ->
            Dns.encode_response(%{answers: [record(["far", "local"], :a, {10, 1, 2, 3})]})
        end)
      end)

    assert {:ok, [%{name: "FMutate A", host: "10.1.2.3", inst: "a"}]} = browse([target])
  end

  test "host falls back to the reply's source address without an A record" do
    target = fake(fn _query -> [answer("FMutate A", txt(), false)] end)
    assert {:ok, [%{host: "127.0.0.1"}]} = browse([target])
  end

  test "returns after the timeout when nothing answers" do
    {:ok, silent} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(silent)
    started = System.monotonic_time(:millisecond)

    assert Discovery.browse(targets: [{{127, 0, 0, 1}, port}], timeout: 100) == {:ok, []}
    # At least the window; the upper bound only says it doesn't hang (a busy
    # host can be slow to schedule the return).
    assert (System.monotonic_time(:millisecond) - started) in 100..1_000
  end
end
