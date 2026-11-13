defmodule Humdinger.FMutate.Reference do
  @moduledoc """
  The FMutate side of the sibling link, as runnable reference code: what
  FMutate must run for Humdinger (and later siblings) to pair and play. The
  tests run it in a separate BEAM, and a Mac can stand in for FMutate with it
  when trying Humdinger on a phone. FMutate can copy these modules.

    * `Reference.Epmd`: no epmd, a fixed distribution port.
    * `Reference.Pairings`: per-app cookies, pinned client certificates,
      revocation, the TLS distribution options.
    * `Reference.Instance`: `:fmutate_instance`, the messages of protocol §4.
    * `Reference.PairingServer`: the pairing endpoint of §1.5 (code, link,
      SRP, approval, grant), optionally advertised over mDNS with
      `Reference.Responder`.

  FMutate's node itself starts with its boot arguments (`Reference.Epmd`,
  and for other phones `-proto_dist inet_tls -ssl_dist_optfile <file>`
  written by `Pairings.write_ssl_dist_optfile/2`).
  """

  use Supervisor

  @doc """
  Starts the registry and the instance, and the pairing endpoint when
  `pairing:` options are given (see `Reference.PairingServer`; it is
  registered as `Humdinger.FMutate.Reference.PairingServer`). `instance:`
  options go to `Reference.Instance`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Like `start_link/1`, unlinked from the caller (for scripts and `:peer.call/4`)."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    with {:ok, pid} <- start_link(opts) do
      Process.unlink(pid)
      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    pairing =
      case Keyword.get(opts, :pairing) do
        nil ->
          []

        pairing_opts ->
          [
            {Humdinger.FMutate.Reference.PairingServer,
             Keyword.put_new(
               pairing_opts,
               :server_name,
               Humdinger.FMutate.Reference.PairingServer
             )}
          ]
      end

    children =
      [
        Humdinger.FMutate.Reference.Pairings,
        {Humdinger.FMutate.Reference.Instance, Keyword.get(opts, :instance, [])}
      ] ++ pairing

    Supervisor.init(children, strategy: :one_for_one)
  end
end
