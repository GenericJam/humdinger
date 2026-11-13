defmodule Humdinger.Realtime do
  @moduledoc """
  Supervises the real-time path: `Humdinger.Output`, then
  `Humdinger.Engine`, `rest_for_one`. A crashed engine is restarted on its
  own (its `terminate/2` has turned its note off); a crashed Output takes
  the engine with it, so the new engine sends to the new Output and the
  note-offs of the old one were sent before it went. Started from
  `Humdinger.App.on_start/0`; FMutate keeps its own supervisor.

  `start_link(children: [...])` replaces the two children (tests).
  """

  use Supervisor

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    children = Keyword.get(opts, :children, [Humdinger.Output, Humdinger.Engine])
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
