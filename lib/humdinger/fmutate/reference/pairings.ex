defmodule Humdinger.FMutate.Reference.Pairings do
  @moduledoc """
  FMutate's paired sibling apps (reference): per-app cookies, pinned client
  certificates, revocation (protocol §1.3–1.4).

  On Allow, `add/1` makes a cookie (32 random bytes, base64url), sets it for
  exactly the node name the sibling declared, and pins the sibling's
  certificate for TLS distribution. `revoke/1` (the I/O screen's Disconnect,
  or a sibling's `{:unpair, node}`) disconnects the node, replaces its cookie
  with a random one and unpins its certificate, so neither the old cookie nor
  the certificate opens a connection again.

  TLS distribution checks client certificates with `verify_client/4`; write
  the `-ssl_dist_optfile` with `write_ssl_dist_optfile/2`. The registry is in
  memory here; FMutate keeps it in its own secure storage and calls `add/1`
  for each stored pairing at boot.
  """

  use GenServer

  alias Humdinger.FMutate.Cert

  @table __MODULE__

  @type pairing :: %{
          node: String.t(),
          app_id: String.t(),
          app_name: String.t(),
          device_name: String.t(),
          client_fp: <<_::256>>,
          cookie: String.t(),
          paired_at: integer()
        }

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the registry (one per node)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Adds (or replaces) the pairing for `request.node` and returns it with its
  new cookie. `request`: `%{node, app_id, app_name, device_name, client_fp}`;
  a `cookie` in it is reused (restoring stored pairings at boot).
  """
  @spec add(map()) :: {:ok, pairing()}
  def add(request), do: GenServer.call(__MODULE__, {:add, request})

  @doc "Revokes the pairing of `node` (a string or atom)."
  @spec revoke(node() | String.t()) :: :ok
  def revoke(node), do: GenServer.call(__MODULE__, {:revoke, to_string(node)})

  @doc "All pairings."
  @spec list() :: [pairing()]
  def list, do: for({_node, _atom, pairing} <- :ets.tab2list(@table), do: pairing)

  @doc "Whether a client certificate fingerprint belongs to a paired sibling."
  @spec pinned?(binary()) :: boolean()
  def pinned?(fp), do: :ets.match_object(@table, {:_, :_, %{client_fp: fp}}) != []

  @doc """
  `ssl` verify fun for FMutate's TLS distribution listener: accepts a client
  certificate only if a pairing pinned it.
  """
  @spec verify_client(term(), binary(), term(), term()) ::
          {:valid, term()} | {:fail, term()} | {:unknown, term()}
  def verify_client(otp_cert, der, event, state) do
    {fun, _} = Cert.verify_fun(&pinned?/1)
    fun.(otp_cert, der, event, state)
  end

  @doc """
  Writes the `-ssl_dist_optfile` for FMutate's TLS distribution: FMutate's
  certificate and key, mutual TLS 1.3, clients checked by `verify_client/4`.
  """
  @spec write_ssl_dist_optfile(Path.t(), Cert.t()) :: :ok | {:error, File.posix()}
  def write_ssl_dist_optfile(path, %{cert: cert, key: key}) do
    File.write(path, """
    [{server,
      [{certs_keys, [\#{cert => #{erlang_binary(cert)}, key => {'ECPrivateKey', #{erlang_binary(key)}}}]},
       {verify, verify_peer},
       {cacerts, []},
       {fail_if_no_peer_cert, true},
       {verify_fun, {fun '#{__MODULE__}':verify_client/4, []}},
       {versions, ['tlsv1.3']}]},
     {client,
      [{verify, verify_peer},
       {cacerts, []},
       {verify_fun, {fun '#{__MODULE__}':verify_client/4, []}},
       {versions, ['tlsv1.3']}]}].
    """)
  end

  defp erlang_binary(bytes), do: "<<" <> Enum.join(:binary.bin_to_list(bytes), ",") <> ">>"

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:add, request}, _from, state) do
    cookie =
      request[:cookie] ||
        32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    # The atoms are the node the player allowed and its cookie: one pair per
    # pairing, never made from an unapproved request.
    atom = String.to_atom(request.node)
    if Node.alive?(), do: :erlang.set_cookie(atom, String.to_atom(cookie))

    pairing =
      request
      |> Map.take([:node, :app_id, :app_name, :device_name, :client_fp])
      |> Map.merge(%{cookie: cookie, paired_at: System.os_time(:second)})

    :ets.insert(@table, {request.node, atom, pairing})
    {:reply, {:ok, pairing}, state}
  end

  def handle_call({:revoke, node}, _from, state) do
    case :ets.take(@table, node) do
      [{^node, atom, _pairing}] ->
        if Node.alive?() do
          :erlang.disconnect_node(atom)
          random = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
          :erlang.set_cookie(atom, String.to_atom(random))
        end

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end
end
