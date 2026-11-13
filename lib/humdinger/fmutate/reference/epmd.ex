defmodule Humdinger.FMutate.Reference.Epmd do
  @moduledoc """
  FMutate's port mapper (reference): no epmd, one fixed distribution port.

  FMutate runs its own BEAM and must not depend on an epmd another app
  started (protocol §2). Start its node with `Humdinger.FMutate.Reference.boot_args/1`:

      -start_epmd false -epmd_module Elixir.Humdinger.FMutate.Reference.Epmd
      -kernel erl_epmd_node_listen_port <dist_port>
      -proto_dist inet_tls -ssl_dist_optfile <file>          (siblings on other phones)
      -kernel inet_dist_use_interface {127,0,0,1}            (plain: same phone only) It listens on that
  port, registers nowhere, and never looks other nodes up: siblings connect
  to FMutate, not the other way round, so a message to a sibling that has
  gone stays undelivered instead of starting a connection.
  """

  @doc false
  def start_link, do: :ignore

  @doc false
  def register_node(_name, _port), do: {:ok, -1}

  @doc false
  def register_node(_name, _port, _family), do: {:ok, -1}

  @doc false
  def listen_port_please(_name, _host) do
    case :application.get_env(:kernel, :erl_epmd_node_listen_port) do
      {:ok, port} when is_integer(port) and port > 0 -> {:ok, port}
      _ -> {:ok, 0}
    end
  end

  @doc false
  def port_please(_name, _host), do: :noport

  @doc false
  def port_please(_name, _host, _timeout), do: :noport

  @doc false
  def address_please(_name, host, family), do: :inet.getaddr(host, family)

  @doc false
  def names(_host), do: {:error, :address}
end
