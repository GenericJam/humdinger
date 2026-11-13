defmodule Humdinger.FMutate.Pairing do
  @moduledoc """
  Pairing Humdinger with FMutate, for the Pair screen.

  Three ways in, all ending in the same exchange (`Pairing.Client`, protocol
  §1.5): a scanned QR code or a pasted link (`parse_link/1`, then `pair/2`
  with the parsed link), or the 8-character code typed in (`pair/2` with
  `%{code: code}`), which finds FMutate over mDNS and tries each FMutate that
  is pairing.

  One owner (the screen) at a time. Messages to the owner:

    * `{:fmutate_pair, :found, [candidate]}` while `discover/1` runs: each
      time the list of FMutates nearby changes (`Humdinger.FMutate.Discovery`
      candidates: `%{name, inst, node, host, port, dist_port, fp, firmware,
      device}`; `port` is nil when that FMutate isn't showing its Pair screen).
    * `{:fmutate_pair, :matched, candidate}`: FMutate proved itself and took
      the token or code ("code matches" on the board).
    * `{:fmutate_pair, :waiting}`: FMutate is asking the player (Allow).
    * `{:fmutate_pair, :paired, info}`: the pairing is stored and the link is
      connecting; `info` is `%{name, device, firmware, inst, same_phone}`.
    * `{:fmutate_pair, :failed, reason}`: see `Pairing.Client.pair/4`, plus
      `:not_found` (no FMutate showing its code nearby) and
      `{:store, reason}` (the secure store refused the pairing).

  `cancel/0` stops discovery and any pairing in progress (closing the
  connection withdraws the request on FMutate).
  """

  use GenServer

  alias Humdinger.FMutate.{Cert, Code, Discovery, PairLink, Record, Transport}
  alias Humdinger.FMutate.Pairing.Client

  require Logger

  @app_id "com.genericjam.humdinger"
  @app_name "Humdinger"
  @discovery_interval 2_000
  @fresh_candidates_ms 5_000

  @typedoc "What `pair/2` takes: a parsed link, or a typed code (optionally for one candidate)."
  @type offer :: PairLink.t() | %{required(:code) => String.t(), optional(:candidate) => map()}

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts the pairing service. Options (for tests): `:name`, `:link` (the
  module or `{module, server}` receiving the record, default
  `Humdinger.FMutate`), `:discovery` (a function of browse options returning
  `{:ok, candidates}`, default `Humdinger.FMutate.Discovery.browse/1`),
  `:discovery_opts`, `:self_node` (a function returning the node name to
  declare), `:device_name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Parses a scanned or pasted pairing link (see `Humdinger.FMutate.PairLink`)."
  @spec parse_link(String.t()) :: {:ok, PairLink.t()} | {:error, term()}
  def parse_link(link), do: PairLink.parse(link)

  @doc """
  The display form of a typed code (`{:ok, "KQ7M-X2PD"}`) or
  `{:error, :invalid_code}`. Case, spaces and dashes don't matter; `I`/`L`
  read as `1` and `O` as `0` (see `Humdinger.FMutate.Code`).
  """
  @spec normalize_code(String.t()) :: {:ok, String.t()} | {:error, :invalid_code}
  def normalize_code(input) do
    case Code.normalize(input) do
      {:ok, code} -> {:ok, Code.format(code)}
      :error -> {:error, :invalid_code}
    end
  end

  @doc "Looks for FMutates nearby until `cancel/0` (or the owner exits)."
  @spec discover(pid(), GenServer.server()) :: :ok
  def discover(owner \\ self(), server \\ __MODULE__),
    do: GenServer.call(server, {:discover, owner})

  @doc "Pairs using `offer`, replacing any pairing in progress."
  @spec pair(pid(), offer(), GenServer.server()) :: :ok | {:error, :invalid_code}
  def pair(owner \\ self(), offer, server \\ __MODULE__),
    do: GenServer.call(server, {:pair, owner, offer})

  @doc "Stops discovery and the pairing in progress."
  @spec cancel(GenServer.server()) :: :ok
  def cancel(server \\ __MODULE__), do: GenServer.call(server, :cancel)

  @impl true
  def init(opts) do
    state = %{
      link: Keyword.get(opts, :link, Humdinger.FMutate),
      discovery: Keyword.get(opts, :discovery, &Discovery.browse/1),
      discovery_opts: Keyword.get(opts, :discovery_opts, []),
      self_node: Keyword.get(opts, :self_node, &Transport.self_node/0),
      device_name: Keyword.get_lazy(opts, :device_name, &device_name/0),
      owner: nil,
      owner_ref: nil,
      discoverer: nil,
      pairer: nil,
      candidates: [],
      found_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:discover, owner}, _from, state) do
    state = state |> own(owner) |> stop_discovery()
    {:reply, :ok, start_discovery(state)}
  end

  def handle_call({:pair, owner, offer}, _from, state) do
    case target(offer) do
      {:ok, candidates_and_auth} ->
        state = state |> own(owner) |> stop_pairing()
        {:reply, :ok, start_pairing(state, candidates_and_auth)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, state |> stop_discovery() |> stop_pairing() |> disown()}
  end

  @impl true
  def handle_info({:found, pid, candidates}, %{discoverer: pid} = state) do
    if candidates != state.candidates, do: send(state.owner, {:fmutate_pair, :found, candidates})
    {:noreply, %{state | candidates: candidates, found_at: now()}}
  end

  def handle_info({:paired, pid, record, candidate}, %{pairer: pid} = state) do
    message =
      case install(state.link, record) do
        :ok -> {:fmutate_pair, :paired, info(record, candidate)}
        {:error, reason} -> {:fmutate_pair, :failed, {:store, reason}}
      end

    send(state.owner, message)
    {:noreply, stop_discovery(%{state | pairer: nil})}
  end

  def handle_info({:pair_failed, pid, reason}, %{pairer: pid} = state) do
    send(state.owner, {:fmutate_pair, :failed, reason})
    {:noreply, %{state | pairer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    {:noreply, state |> stop_discovery() |> stop_pairing() |> disown()}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pairer: pid} = state) do
    send(state.owner, {:fmutate_pair, :failed, {:crashed, reason}})
    {:noreply, %{state | pairer: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{discoverer: pid} = state) do
    {:noreply, %{state | discoverer: nil}}
  end

  # Results and exits of discoverers and pairers that were replaced or cancelled.
  def handle_info(_stale, state), do: {:noreply, state}

  defp target(%{via: :link} = link) do
    {:ok, {[candidate_from_link(link)], {:token, link.token}}}
  end

  defp target(%{code: code} = offer) do
    case Code.normalize(code) do
      {:ok, code} -> {:ok, {chosen(offer), {:code, code}}}
      :error -> {:error, :invalid_code}
    end
  end

  defp target(_), do: {:error, :invalid_offer}

  # nil: look the candidates up when pairing starts.
  defp chosen(%{candidate: candidate}) when is_map(candidate), do: [candidate]
  defp chosen(_offer), do: nil

  defp candidate_from_link(link) do
    %{
      name: "FMutate " <> String.upcase(link.inst),
      inst: link.inst,
      node: link.node,
      host: link.host,
      port: link.port,
      dist_port: nil,
      fp: link.fp,
      firmware: nil,
      device: nil
    }
  end

  defp own(%{owner: owner} = state, owner), do: state

  defp own(state, owner) do
    state = state |> stop_discovery() |> stop_pairing() |> disown()
    %{state | owner: owner, owner_ref: Process.monitor(owner)}
  end

  defp disown(%{owner_ref: nil} = state), do: state

  defp disown(state) do
    Process.demonitor(state.owner_ref, [:flush])
    %{state | owner: nil, owner_ref: nil}
  end

  defp start_discovery(state) do
    server = self()
    browse = state.discovery
    opts = state.discovery_opts

    {pid, _ref} =
      spawn_monitor(fn -> discovery_loop(server, browse, opts) end)

    %{state | discoverer: pid}
  end

  defp discovery_loop(server, browse, opts) do
    case browse.(opts) do
      {:ok, candidates} -> send(server, {:found, self(), candidates})
      {:error, reason} -> Logger.debug("FMutate discovery: #{inspect(reason)}")
    end

    Process.sleep(@discovery_interval)
    discovery_loop(server, browse, opts)
  end

  defp stop_discovery(%{discoverer: nil} = state), do: state

  defp stop_discovery(state) do
    Process.exit(state.discoverer, :kill)
    %{state | discoverer: nil}
  end

  defp start_pairing(state, {candidates, auth}) do
    server = self()

    context = %{
      owner: state.owner,
      identity: %{
        app_id: @app_id,
        app_name: @app_name,
        device_name: state.device_name,
        node: state.self_node.(),
        cert: Cert.self_signed(@app_name)
      },
      candidates: candidates || fresh_candidates(state),
      browse: fn -> browse(state) end
    }

    {pid, _ref} = spawn_monitor(fn -> run_pairing(server, context, auth) end)
    %{state | pairer: pid}
  end

  defp stop_pairing(%{pairer: nil} = state), do: state

  defp stop_pairing(state) do
    Process.exit(state.pairer, :kill)
    %{state | pairer: nil}
  end

  defp fresh_candidates(%{found_at: nil}), do: nil
  defp fresh_candidates(%{candidates: []}), do: nil

  defp fresh_candidates(%{found_at: found_at, candidates: candidates}) do
    if now() - found_at < @fresh_candidates_ms, do: candidates
  end

  defp browse(state) do
    case state.discovery.(state.discovery_opts) do
      {:ok, candidates} -> candidates
      {:error, _} -> []
    end
  end

  # Runs in its own process: tries each candidate in turn until one pairs.
  defp run_pairing(server, context, auth) do
    candidates = Enum.filter(context.candidates || context.browse.(), & &1.port)

    case try_candidates(candidates, context, auth, :not_found) do
      {:ok, record, candidate} -> send(server, {:paired, self(), record, candidate})
      {:error, reason} -> send(server, {:pair_failed, self(), reason})
    end
  end

  defp try_candidates([], _context, _auth, reason), do: {:error, reason}

  defp try_candidates([candidate | rest], context, auth, best) do
    target = %{
      host: candidate.host,
      port: candidate.port,
      inst: candidate.inst,
      fp: link_fp(auth, candidate)
    }

    notify = fn
      :authenticated -> send(context.owner, {:fmutate_pair, :matched, candidate})
      :pending -> send(context.owner, {:fmutate_pair, :waiting})
    end

    case Client.pair(target, auth, context.identity, notify) do
      {:ok, record} ->
        {:ok, record, candidate}

      {:error, reason} = error ->
        # A typed code may belong to another FMutate nearby: keep looking
        # unless this one got far enough to be the right one.
        if match?({:code, _}, auth) and retry_elsewhere?(reason),
          do: try_candidates(rest, context, auth, better(best, reason)),
          else: error
    end
  end

  # Only a link carries the fingerprint to pin; a code proves it via SRP.
  defp link_fp({:token, _}, candidate), do: candidate.fp
  defp link_fp({:code, _}, _candidate), do: nil

  defp retry_elsewhere?({:wrong_code, _}), do: true

  defp retry_elsewhere?(reason),
    do: reason in [:unreachable, :not_pairing, :busy, :expired, :too_many_attempts]

  # The error to report when no candidate pairs: a wrong code says the most.
  defp better({:wrong_code, _} = best, _reason), do: best
  defp better(_best, reason), do: reason

  defp install({module, server}, record), do: module.install(record, server)
  defp install(module, record), do: module.install(record)

  defp info(record, candidate) do
    %{
      name: record.name || candidate.name,
      device: record.device || candidate.device,
      firmware: record.firmware || candidate.firmware,
      inst: record.inst,
      same_phone: Record.loopback?(record)
    }
  end

  defp device_name do
    if System.get_env("MOB_BEAMS_DIR") do
      Mob.Device.model()
    else
      {:ok, host} = :inet.gethostname()
      List.to_string(host)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
