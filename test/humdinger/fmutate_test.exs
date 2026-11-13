defmodule Humdinger.FMutateTest do
  # The link's own behaviour (status, MIDI, backoff, following FMutate to a
  # new address, forget) with a scripted transport; the real distribution is
  # in Humdinger.FMutate.DistTest. The transport script is global.
  use ExUnit.Case, async: false

  alias Humdinger.FMutate
  alias Humdinger.FMutate.{Cert, Record, Store}

  defmodule ScriptedTransport do
    @moduledoc false
    @behaviour Humdinger.FMutate.Transport

    def start(test, connect),
      do: Agent.start_link(fn -> %{test: test, connect: connect} end, name: __MODULE__)

    def script(connect), do: Agent.update(__MODULE__, &%{&1 | connect: connect})
    defp test, do: Agent.get(__MODULE__, & &1.test)

    @impl true
    def connect(record, _owner) do
      send(test(), {:connect, record, System.monotonic_time(:millisecond)})
      Agent.get(__MODULE__, & &1.connect).(record)
    end

    @impl true
    def disconnect(conn), do: send(test(), {:disconnect, conn}) && :ok

    @impl true
    def revoke(node), do: send(test(), {:revoke, node}) && :ok

    @impl true
    def cast(_conn, _inst, payload), do: send(test(), {:cast, payload}) && :ok

    @impl true
    def call(_conn, _inst, {:list_firmware}, _timeout),
      do:
        {:ok,
         {:ok,
          [
            %{id: "dx", name: "DX", status: :installed},
            %{id: "x0x", name: "X0X", status: :running}
          ]}}

    def call(_conn, _inst, payload, _timeout), do: send(test(), {:call, payload}) && {:ok, :ok}

    @impl true
    def self_node, do: "humdinger_scripted@127.0.0.1"
  end

  @conn %{node: :"fmutate_a@192.168.1.23", tunnel: nil}

  setup do
    {:ok, _} = ScriptedTransport.start(self(), fn _ -> {:ok, @conn} end)
    key = "test.link.#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete(key: key) end)
    %{store: {Store, key: key}, key: key}
  end

  defp record(overrides \\ %{}) do
    me = Cert.self_signed("Humdinger")

    struct!(
      Record,
      Map.merge(
        %{
          inst: "a",
          name: "FMutate A",
          device: "Pixel 7",
          node: "fmutate_a@192.168.1.23",
          host: "192.168.1.23",
          dist_port: 45_124,
          dist_proto: :inet_tls,
          fp: :crypto.hash(:sha256, "fmutate"),
          cookie: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          self_node: "humdinger_scripted@127.0.0.1",
          cert: me.cert,
          key: me.key
        },
        overrides
      )
    )
  end

  defp start_link(ctx, opts \\ []) do
    defaults = [
      name: nil,
      store: ctx.store,
      transport: ScriptedTransport,
      discovery: fn _ -> {:ok, []} end,
      grace_ms: 0,
      backoff: [20, 40, 80]
    ]

    link = start_supervised!({FMutate, Keyword.merge(defaults, opts)})
    :ok = FMutate.subscribe(self(), link)
    link
  end

  defp await_status(expected, timeout \\ 2_000) do
    receive do
      {:fmutate, :status, ^expected} -> expected
      {:fmutate, :status, _other} -> await_status(expected, timeout)
    after
      timeout -> flunk("no status #{inspect(expected)}")
    end
  end

  test "unpaired until a pairing is installed; then stored, connected, subscribed to status",
       ctx do
    link = start_link(ctx)
    assert_receive {:fmutate, :status, :unpaired}, 1_000

    r = record()
    assert FMutate.install(r, link) == :ok
    assert_receive {:fmutate, :status, :disconnected}, 1_000

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    assert_receive {:cast, {:subscribe, ^link, [:status]}}, 1_000
    assert {:ok, %Record{firmware: "X0X"} = stored} = Store.load(ctx.store |> elem(1))
    assert %{stored | firmware: nil} == r
  end

  test "a stored pairing connects at start", ctx do
    :ok = Store.save(record(), key: ctx.key)
    link = start_link(ctx)

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    assert FMutate.status(link) ==
             {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
  end

  test "while distribution may still come up (development build), a stored pairing waits for it",
       ctx do
    :ok = Store.save(record(), key: ctx.key)
    started = System.monotonic_time(:millisecond)
    _link = start_link(ctx, grace_ms: 300)
    assert_receive {:connect, _, at}, 2_000
    assert at - started >= 300
  end

  test "MIDI goes out only while connected", ctx do
    ScriptedTransport.script(fn _ -> {:error, :unreachable} end)
    link = start_link(ctx)
    :ok = FMutate.install(record(), link)
    FMutate.send_midi(<<0x90, 60, 100>>, link)
    assert FMutate.status(link) == :disconnected
    refute_receive {:cast, {:midi, _}}, 100

    ScriptedTransport.script(fn _ -> {:ok, @conn} end)

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    FMutate.send_midi(<<0x90, 60, 100>>, link)
    assert_receive {:cast, {:midi, <<0x90, 60, 100>>}}, 1_000
  end

  test "retries with backoff, then follows FMutate to its new address found over mDNS", ctx do
    moved = %{
      name: "FMutate A",
      inst: "a",
      node: "fmutate_a@192.168.1.40",
      host: "192.168.1.40",
      port: nil,
      dist_port: 45_125,
      fp: record().fp,
      firmware: "X0X",
      device: "Pixel 7"
    }

    impostor = %{
      moved
      | host: "192.168.1.66",
        node: "fmutate_a@192.168.1.66",
        fp: :crypto.hash(:sha256, "other")
    }

    test = self()

    discovery = fn _ ->
      send(test, :browsed)
      {:ok, [impostor, moved]}
    end

    ScriptedTransport.script(fn
      %{host: "192.168.1.40"} -> {:ok, @conn}
      _old -> {:error, :unreachable}
    end)

    link = start_link(ctx, discovery: discovery)
    :ok = FMutate.install(record(), link)

    assert_receive {:connect, %{host: "192.168.1.23"}, t1}, 1_000
    assert_receive {:connect, %{host: "192.168.1.23"}, t2}, 1_000
    assert t2 - t1 >= 20
    assert_receive :browsed, 1_000
    # The move is saved (an fsync) before the link connects to it.
    assert_receive {:connect,
                    %{host: "192.168.1.40", node: "fmutate_a@192.168.1.40", dist_port: 45_125},
                    _},
                   2_000

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    assert {:ok, %Record{host: "192.168.1.40", dist_port: 45_125}} = Store.load(key: ctx.key)
    _ = link
  end

  test "spoofed mDNS answers are only tried, never saved, and never loopback or another node",
       ctx do
    fp = record().fp

    spoofs = [
      %{
        name: "FMutate A",
        inst: "a",
        node: "fmutate_a@127.0.0.1",
        host: "127.0.0.1",
        port: nil,
        dist_port: 1,
        fp: fp,
        firmware: nil,
        device: nil
      },
      %{
        name: "FMutate A",
        inst: "a",
        node: "fmutate_x@192.168.1.50",
        host: "192.168.1.50",
        port: nil,
        dist_port: 1,
        fp: fp,
        firmware: nil,
        device: nil
      },
      %{
        name: "FMutate A",
        inst: "a",
        node: "fmutate_a@192.168.1.60",
        host: "192.168.1.60",
        port: nil,
        dist_port: 1,
        fp: fp,
        firmware: nil,
        device: nil
      }
    ]

    ScriptedTransport.script(fn _ -> {:error, :unreachable} end)
    link = start_link(ctx, discovery: fn _ -> {:ok, spoofs} end, backoff: [20])
    :ok = FMutate.install(record(), link)

    hosts = for _ <- 1..8, do: assert_receive({:connect, %{host: host}, _}, 1_000) && host

    assert "192.168.1.60" in hosts
    refute "127.0.0.1" in hosts
    refute "192.168.1.50" in hosts
    # A failed trial is not tried again, and the link goes back to the pairing's address.
    assert Enum.count(hosts, &(&1 == "192.168.1.60")) == 1
    assert List.last(hosts) == "192.168.1.23"

    assert {:ok, %Record{host: "192.168.1.23", node: "fmutate_a@192.168.1.23"}} =
             Store.load(key: ctx.key)
  end

  test "FMutate on the same phone is never looked up over mDNS", ctx do
    test = self()
    ScriptedTransport.script(fn _ -> {:error, :unreachable} end)
    link = start_link(ctx, discovery: fn _ -> send(test, :browsed) && {:ok, []} end)

    :ok =
      FMutate.install(
        record(%{host: "127.0.0.1", node: "fmutate_a@127.0.0.1", dist_proto: :inet_tcp}),
        link
      )

    for _ <- 1..3, do: assert_receive({:connect, _, _}, 1_000)
    refute_received :browsed
  end

  test "FMutate's status events, a dropped connection and the way back", ctx do
    link = start_link(ctx)
    :ok = FMutate.install(record(), link)

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    send(link, {:fmutate, 1, "a", {:status, :booting}})

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: :booting}}
    )

    send(link, {:fmutate, 1, "b", {:status, :crashed}})
    refute_receive {:fmutate, :status, {:connected, %{emulator: :crashed}}}, 50

    send(link, {:nodedown, @conn.node, []})
    await_status(:disconnected)
    assert_receive {:disconnect, @conn}, 1_000

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )
  end

  test "forget tells FMutate, revokes the node, deletes the pairing and stops reconnecting",
       ctx do
    link = start_link(ctx)
    :ok = FMutate.install(record(), link)

    await_status(
      {:connected, %{name: "FMutate A", firmware: "X0X", device: "Pixel 7", emulator: nil}}
    )

    assert_received {:connect, _, _}

    assert FMutate.forget(link) == :ok
    assert_receive {:call, {:unpair, _me}}, 1_000
    assert_receive {:disconnect, @conn}, 1_000
    assert_receive {:revoke, :"fmutate_a@192.168.1.23"}, 1_000
    await_status(:unpaired)
    assert Store.load(key: ctx.key) == :none

    send(link, {:nodedown, @conn.node, []})
    FMutate.reconnect(link)
    refute_receive {:connect, _, _}, 150
    FMutate.send_midi(<<0x90, 60, 1>>, link)
    refute_receive {:cast, {:midi, _}}, 50
  end
end
