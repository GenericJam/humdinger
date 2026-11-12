defmodule Humdinger.LiveScreen do
  @moduledoc "Live (home): hum into the phone, see the note, send MIDI. Design: `design/shots/live.webp`."

  use Mob.Screen

  alias Humdinger.Style

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(_assigns) do
    ~MOB"""
    <Column background={Style.bg()} fill_width={true} fill_height={true} padding={16}>
      <Text text="Humdinger" font={:display} text_size={32} text_color={Style.text()} />
    </Column>
    """
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
