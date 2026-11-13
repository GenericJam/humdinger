defmodule Humdinger.Test.ScreenHelpers do
  @moduledoc "Queries shared by the phrase screens' tests."

  import Mob.ScreenCase, only: [flatten: 1, find: 3]

  @doc """
  The tag of every tappable node and whether it also takes the press-out that
  keeps its tap alive across re-renders (MOB-509).
  """
  def taps(view) do
    for %{props: %{on_tap: {_pid, tag}} = props} <- flatten(view),
        do: {tag, match?({_, :held}, props[:on_press_out])}
  end

  @doc "Tags of tap targets missing `on_press_out={held()}`."
  def unguarded(view), do: for({tag, false} <- taps(view), do: tag)

  @doc "The nav action the last event recorded (`{:push, dest, params}`, `{:pop}`, …)."
  def nav(view), do: Map.get(view.socket.__mob__, :nav_action)

  @doc "The node with `id`, any type."
  def by_id(view, id), do: Enum.find(flatten(view), &(&1.props[:id] == id))

  @doc "The text of the `<Text>` with `id`."
  def text_of(view, id), do: find(view, :text, id: id).props.text

  @doc "Every Text string on screen, in order."
  def texts(view), do: for(%{type: :text, props: %{text: t}} <- flatten(view), do: t)

  @doc "The open sheet node, or nil."
  def sheet(view), do: Enum.find(flatten(view), &(&1.type == :sheet))
end
