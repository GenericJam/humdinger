defmodule Humdinger.GalleryScreen do
  @moduledoc """
  Development aid: every view and every Mimi mood drawn with sample data,
  one labelled canvas each, so they can be checked on a phone. Compiled in
  dev and test only (`dev/` is outside a release's `elixirc_paths`) and not
  in the app's navigation; open it from `mix mob.connect`:

      Mob.Test.navigate(node, Humdinger.GalleryScreen)

  `scenes/0` is also what `scripts/preview_views.exs` renders on the host.
  """

  use Mob.Screen

  alias Humdinger.{Mimi, Style}

  @typedoc "A labelled canvas: name, width, height, ops."
  @type scene :: {String.t(), number(), number(), [map()]}

  @impl true
  def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :scenes, scenes())}

  @impl true
  def render(assigns) do
    ~MOB"""
    <Scroll background={Style.bg()} fill_width={true} fill_height={true}>
      <Column padding={16} gap={8} fill_width={true}>
        <Text text="Views gallery" font={:display} text_size={24} text_color={Style.text()} />
        <Column :for={{name, w, h, ops} <- @scenes} gap={4}>
          <Text text={name} font={:mono} text_size={11} text_color={Style.muted()} />
          <Canvas width={w} height={h} draw={ops} />
        </Column>
      </Column>
    </Scroll>
    """
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Every scene, in gallery order."
  @spec scenes() :: [scene()]
  def scenes do
    mimi_scenes()
  end

  # The identity board's mood grid: each mood on its board note.
  @mood_notes %{
    idle: 69,
    listening: 69,
    singing: 64,
    aria: 72,
    flat: 57,
    sharp: 81,
    headphones: 69,
    paused: 69,
    no_mic: 69
  }

  defp mimi_scenes do
    moods =
      for mood <- Mimi.moods() do
        {"Mimi :#{mood}", 120, 104,
         Mimi.ops(60, 52, 86.4, %{mood: mood, note: @mood_notes[mood]})}
      end

    rainbow =
      for {note, name} <- [{33, "A1"}, {45, "A2"}, {57, "A3"}, {69, "A4"}, {81, "A5"}, {93, "A6"}] do
        mood = if note == 69, do: :aria, else: :singing
        {"Mimi #{name}", 80, 70, Mimi.ops(40, 35, 76.8, %{mood: mood, note: note})}
      end

    [{"Mimi idle, board size 3.4", 220, 192, Mimi.ops(110, 96, 217.6, %{mood: :idle})}] ++
      moods ++ rainbow ++ [{"App icon", 140, 140, Mimi.icon_ops(140)}]
  end
end
