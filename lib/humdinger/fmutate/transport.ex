defmodule Humdinger.FMutate.Transport do
  @moduledoc """
  Erlang distribution to a paired FMutate: Humdinger's node, the per-app
  cookie, the route to FMutate's port, and the connection.

  ## Humdinger's node

  Humdinger only ever connects out, so a node it starts itself is hidden and
  has no listener (`dist_listen: false`): nothing on the phone or the Wi-Fi can
  connect in, in development or release builds, and there is no epmd
  (`Humdinger.FMutate.Epmd` routes FMutate). Auto-connect is off
  (`dist_auto_connect: never`), so a message to a dropped FMutate can't
  reconnect behind the link's back. Its default cookie is random; FMutate's
  node gets the pairing's cookie with `:erlang.set_cookie/2`.

  In a development build on Android, `Mob.Dist` starts a listening loopback
  node for `mix mob.connect` a few seconds after boot. Both can't exist in one
  BEAM, so the link uses that node when it is up (`self_node/0` is then its
  name, and FMutate accepts it because the pairing declared that name), and
  otherwise starts its own node under the same development name.

  The connection to FMutate is hidden too (`:net_kernel.hidden_connect_node/1`):
  `global` doesn't mesh Humdinger with FMutate's other peers, and messages go
  to the locally registered `:fmutate_instance` on FMutate's node.

  ## Carriers

  `dist_proto` from the pairing: `:inet_tcp` is plain distribution to
  FMutate's loopback port (same phone); `:inet_tls` goes through
  `Humdinger.FMutate.Tunnel` (mutual TLS, both certificates pinned).

  ## Atoms

  Node names and cookies are atoms. They are made only from the stored
  pairing (validated by `Humdinger.FMutate.Record`), and for TLS only after the
  tunnel has verified FMutate's certificate, so a peer on the network can't
  make Humdinger create atoms.
  """

  alias Humdinger.FMutate.{Epmd, Record, Tunnel}

  @type conn :: %{node: node(), tunnel: pid() | nil}

  @callback connect(Record.t(), owner :: pid()) :: {:ok, conn()} | {:error, term()}
  @callback disconnect(conn()) :: :ok
  @callback revoke(node() | nil) :: :ok
  @callback cast(conn(), String.t(), term()) :: :ok | :dropped
  @callback call(conn(), String.t(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  @callback self_node() :: String.t()

  @behaviour __MODULE__

  @doc """
  Makes `Humdinger.FMutate.Epmd` the node's port mapper. Call before
  distribution starts (`App.on_start`, ahead of `Mob.Dist`); it also works
  later for outgoing connections, which look the module up each time.

  `dev_node:` is the base name `Mob.Dist` is given in development builds.
  """
  @spec setup(keyword()) :: :ok | {:error, term()}
  def setup(opts \\ []) do
    if dev_node = opts[:dev_node],
      do: Application.put_env(:humdinger, :fmutate_dev_node, dev_node)

    case {:init.get_argument(:epmd_module), :application.get_env(:kernel, :epmd_module)} do
      {{:ok, _}, _} -> {:error, :epmd_module_argument}
      {_, {:ok, Epmd}} -> :ok
      {_, {:ok, other}} -> {:error, {:epmd_module, other}}
      {_, :undefined} -> :application.set_env(:kernel, :epmd_module, Epmd)
    end
  end

  @doc """
  The node name Humdinger declares when pairing: the running node's, the
  `Mob.Dist` development name on an Android development build, otherwise a
  fresh `humdinger_<random>@127.0.0.1` (unique per pairing, so two phones
  paired with one FMutate don't collide; the host part is only a label, as
  nothing ever resolves it).
  """
  @impl true
  def self_node do
    cond do
      Node.alive?() -> Atom.to_string(node())
      dev = dev_node() -> Atom.to_string(dev)
      true -> "humdinger_#{random_id()}@127.0.0.1"
    end
  end

  @doc """
  Connects to the paired FMutate. `owner` owns the TLS tunnel (it closes
  when `owner` exits).
  """
  @impl true
  def connect(%Record{} = record, owner) do
    with :ok <- ensure_node(record.self_node),
         {:ok, route, tunnel} <- open_route(record, owner) do
      node = String.to_atom(record.node)
      true = :erlang.set_cookie(node, String.to_atom(record.cookie))
      :ok = Epmd.put_route(node, route)

      if :net_kernel.hidden_connect_node(node) == true do
        {:ok, %{node: node, tunnel: tunnel}}
      else
        disconnect(%{node: node, tunnel: tunnel})
        {:error, if(tunnel, do: :rejected, else: :unreachable)}
      end
    end
  end

  @doc "Drops the connection (the pairing stays)."
  @impl true
  def disconnect(%{node: node, tunnel: tunnel}) do
    :erlang.disconnect_node(node)
    if tunnel, do: Tunnel.close(tunnel)
    Epmd.delete_route(node)
  end

  @doc "Disconnects `node` and replaces its cookie with a random one."
  @impl true
  def revoke(nil), do: :ok

  def revoke(node) when is_atom(node) do
    :erlang.disconnect_node(node)
    if Node.alive?(), do: :erlang.set_cookie(node, random_cookie())
    Epmd.delete_route(node)
  end

  @doc """
  Sends `{:fmutate, 1, inst, payload}` as a cast to `:fmutate_instance` on
  FMutate's node. Never connects and never blocks: `:dropped` when the
  connection is gone or its buffer is full.
  """
  @impl true
  def cast(%{node: node}, inst, payload) do
    message = {:"$gen_cast", {:fmutate, 1, inst, payload}}

    case :erlang.send({:fmutate_instance, node}, message, [:noconnect, :nosuspend]) do
      :ok -> :ok
      _noconnect_or_nosuspend -> :dropped
    end
  end

  @doc "Calls `:fmutate_instance` with `{:fmutate, 1, inst, payload}`."
  @impl true
  def call(%{node: node}, inst, payload, timeout) do
    {:ok, GenServer.call({:fmutate_instance, node}, {:fmutate, 1, inst, payload}, timeout)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp ensure_node(name) do
    cond do
      Node.alive?() and Atom.to_string(node()) == name -> :ok
      Node.alive?() -> {:error, {:node_name, node()}}
      true -> start_node(name)
    end
  end

  defp start_node(name) do
    with :ok <- setup() do
      # auth reads or creates $HOME/.config/erlang/.erlang.cookie when the
      # node starts (Android has no such directory until made).
      if System.get_env("MOB_BEAMS_DIR") && System.get_env("HOME"),
        do: File.mkdir_p(Path.join([System.get_env("HOME"), ".config", "erlang"]))

      :application.set_env(:kernel, :dist_auto_connect, :never)
      options = %{name_domain: :longnames, dist_listen: false, hidden: true}

      case :net_kernel.start(String.to_atom(name), options) do
        {:ok, _} ->
          :erlang.set_cookie(random_cookie())
          :ok

        {:error, {:already_started, _}} ->
          ensure_node(name)

        {:error, reason} ->
          {:error, {:distribution, reason}}
      end
    end
  end

  defp open_route(%Record{dist_proto: :inet_tcp} = record, _owner) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(record.host))
    {:ok, {ip, record.dist_port}, nil}
  end

  defp open_route(%Record{dist_proto: :inet_tls} = record, owner) do
    with {:ok, tunnel, port} <- Tunnel.open(record, owner) do
      {:ok, {{127, 0, 0, 1}, port}, tunnel}
    end
  end

  defp dev_node do
    with base when is_atom(base) and not is_nil(base) <-
           Application.get_env(:humdinger, :fmutate_dev_node),
         dir when dir not in [nil, ""] <- System.get_env("MOB_BEAMS_DIR"),
         false <- Mob.Dist.release_mode?() do
      {suffix, _port} = Mob.Dist.android_settings([])
      Mob.Dist.apply_suffix(base, suffix)
    else
      _ -> nil
    end
  end

  defp random_id,
    do: 5 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  # One fresh atom per call; called once per node start and once per revoke.
  defp random_cookie,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false) |> String.to_atom()
end
