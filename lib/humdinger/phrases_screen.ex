defmodule Humdinger.PhrasesScreen do
  @moduledoc """
  Phrases: the saved phrases, newest first (`design/shots/saved.webp`,
  `design/boards/07-saved.html`).

  Header: back, "Phrases", "+ From audio file" (→ `Humdinger.ImportScreen`).
  Each card: a play button (plays the phrase out through the output at its
  tempo, `Humdinger.Player`; lime while it plays, tap again to stop), the
  name and `Humdinger.Phrase.list_summary/3`, the ⋯ menu, and the
  `Humdinger.Views.PhraseThumb` strip. Tapping the name or the strip opens
  the review (`Humdinger.PhraseScreen`). The ⋯ menu: Rename, Sheet music
  (the review on its Staff tab), Export .mid (the share sheet with the
  `.mid`), Share (a .mid, the sheet music PDF or MusicXML), Delete (asks
  first). A note with Mimi at the bottom explains the menu.

  States: `:loading` (the list loads with `start_async/3`), the list, and
  empty (Mimi and a hint). The review sends `:phrases_changed` back after a
  save, rename or delete, and the list reloads. Every tap target carries
  `on_press_out={held()}`: playing re-renders the screen.
  """

  use Mob.Screen

  import Humdinger.Controls

  alias Humdinger.{ImportScreen, Phrase, PhraseActions, Phrases, PhraseScreen, Player, Style}
  alias Humdinger.Views.PhraseThumb

  @thumb_w 326
  @thumb_h 56

  @impl true
  def mount(_params, _session, socket) do
    {:ok, player} = Player.start_link()

    {:ok,
     socket
     |> Mob.Socket.assign(
       phrases: :loading,
       now: DateTime.utc_now(),
       player: player,
       playing: nil,
       sheet: nil,
       notice: nil
     )
     |> load()}
  end

  defp load(socket) do
    Mob.Socket.start_async(socket, :load, fn -> {Phrases.list(), DateTime.utc_now()} end)
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    back = {self(), :back}
    import_tap = {self(), :import}

    import_button =
      button("+ From audio file", import_tap,
        kind: :header,
        id: "import",
        background: Style.raised_hi()
      )

    page([
      header(back, "Phrases", nil, import_button, size: 24),
      notice(assigns.notice),
      body(assigns),
      sheet_for(assigns)
    ])
  end

  defp body(%{phrases: :loading}) do
    ~MOB"""
    <Column weight={1} align={:center}>
      <Spacer />
      <Progress color={Style.fm()} />
      <Spacer />
    </Column>
    """
  end

  defp body(%{phrases: []}) do
    ~MOB"""
    <Column id="empty" weight={1} align={:center} gap={12}>
      <Spacer />
      {mimi(120, 105, 112, %{mood: :listening, note: 64})}
      <Text text="No phrases yet" font={:display} text_size={22} text_color={Style.text()} />
      <Text
        text="Record one on the home screen, or turn a recording into notes with + From audio file."
        text_size={13}
        text_color={Style.text_2()}
        text_align="center"
      />
      <Spacer />
    </Column>
    """
  end

  defp body(assigns) do
    cards = Enum.map(assigns.phrases, &card(&1, assigns))

    list = ~MOB"""
    <LazyList id="phrases" weight={1}>
      {cards}
    </LazyList>
    """

    footer = ~MOB"""
    <Box
      background={Style.surface()}
      corner_radius={14}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
    >
      <Row align={:center} gap={12}>
        {mimi(48, 42, 46, %{mood: :singing, note: 64})}
        <Text
          weight={1}
          text="⋯ menu: rename, sheet music, export .mid, share, delete. Phrases stay on this phone."
          text_size={13}
          text_color={Style.text_2()}
        />
      </Row>
    </Box>
    """

    [list, footer]
  end

  defp card(%Phrase{id: id} = phrase, assigns) do
    play = {self(), {:play, id}}
    open = {self(), {:open, id}}
    more = {self(), {:more, id}}
    summary = Phrase.list_summary(phrase, assigns.now)
    thumb = PhraseThumb.ops(%{notes: phrase.notes}, @thumb_w, @thumb_h)

    ~MOB"""
    <Column id={id} padding_bottom={12}>
      <Box background={Style.surface()} corner_radius={16} padding={12}>
        <Column gap={10}>
          <Row align={:center} gap={10}>
            {play_button("play_#{id}", assigns.playing == id, play)}
            <Column weight={1} gap={2} on_tap={open} on_press_out={held()}>
              <Text
                text={phrase.name}
                font={:bold}
                text_size={15}
                text_color={Style.text()}
                max_lines={1}
              />
              <Text text={summary} font={:mono} text_size={11} text_color={Style.muted()} />
            </Column>
            {more_button("more_#{id}", more)}
          </Row>
          {thumb_canvas(id, thumb, open)}
        </Column>
      </Box>
    </Column>
    """
  end

  defp thumb_canvas(id, ops, open) do
    {w, h} = {@thumb_w, @thumb_h}

    ~MOB"""
    <Canvas id={"thumb_#{id}"} width={w} height={h} draw={ops} on_tap={open} on_press_out={held()} />
    """
  end

  defp sheet_for(%{sheet: nil}), do: nil

  defp sheet_for(%{sheet: {:menu, id}} = assigns) do
    p = find(assigns, id)

    sheet("menu_#{id}", {self(), :dismiss}, [
      sheet_title(p.name),
      menu_item("rename", "Rename", {self(), {:rename, id}}),
      menu_item("sheet_music", "Sheet music", {self(), {:sheet_music, id}}),
      menu_item("export_mid", "Export .mid", {self(), {:export, id, :mid}}),
      menu_item("share", "Share", {self(), {:share, id}}),
      menu_item("delete", "Delete", {self(), {:delete, id}}, :danger)
    ])
  end

  defp sheet_for(%{sheet: {:share, id}} = assigns) do
    p = find(assigns, id)

    sheet("share_#{id}", {self(), :dismiss}, [
      sheet_title("Share “#{p.name}”", note: "As a MIDI file, sheet music or MusicXML."),
      menu_item("share_mid", "MIDI file (.mid)", {self(), {:export, id, :mid}}),
      menu_item("share_pdf", "Sheet music (PDF)", {self(), {:export, id, :pdf}}),
      menu_item("share_musicxml", "MusicXML", {self(), {:export, id, :musicxml}})
    ])
  end

  defp sheet_for(%{sheet: {:rename, id, name}}) do
    change = {self(), :name}
    submit = {self(), :name}

    sheet("rename_#{id}", {self(), :dismiss}, [
      sheet_title("Rename"),
      ~MOB"""
      <TextField
        id="name"
        value={name}
        placeholder={Phrase.default_name()}
        on_change={change}
        on_submit={submit}
        background={Style.raised()}
        text_color={Style.text()}
        text_size={16}
        corner_radius={12}
        padding={12}
        max_length={80}
      />
      """,
      action_row([
        button("Cancel", {self(), :dismiss}, kind: :action, id: "cancel"),
        button("Save", {self(), {:save_name, id}}, kind: :action, id: "save_name")
      ])
    ])
  end

  defp sheet_for(%{sheet: {:delete, id}} = assigns) do
    p = find(assigns, id)

    sheet("delete_#{id}", {self(), :dismiss}, [
      sheet_title("Delete “#{p.name}”?",
        note: "It's only on this phone, so it can't be brought back."
      ),
      action_row([
        button("Cancel", {self(), :dismiss}, kind: :action, id: "cancel"),
        button("Delete", {self(), {:confirm_delete, id}}, kind: :outline, id: "confirm_delete")
      ])
    ])
  end

  defp find(assigns, id), do: Enum.find(assigns.phrases, &(&1.id == id))

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_async(:load, {:ok, {phrases, now}}, socket) do
    playing = socket.assigns.playing

    playing =
      if playing && Enum.any?(phrases, &(&1.id == playing)), do: playing, else: stop(socket)

    {:noreply, Mob.Socket.assign(socket, phrases: phrases, now: now, playing: playing)}
  end

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, phrases: [], notice: "Couldn't read the phrases.")}

  def handle_async(:export, {:ok, result}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text(result))}

  def handle_async(:export, {:exit, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text({:exit, reason}))}

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket) do
    stop(socket)
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:tap, :import}, socket) do
    {:noreply, socket |> leave() |> Mob.Socket.push_screen(ImportScreen, %{notify: self()})}
  end

  def handle_info({:tap, {:play, id}}, socket) do
    case {socket.assigns.playing, find(socket.assigns, id)} do
      {^id, _} ->
        {:noreply, Mob.Socket.assign(socket, :playing, stop(socket))}

      {_, %Phrase{} = phrase} ->
        :ok = Player.play(socket.assigns.player, Phrase.quantized_notes(phrase), id)
        {:noreply, Mob.Socket.assign(socket, :playing, id)}

      {_, nil} ->
        {:noreply, socket}
    end
  end

  def handle_info({:player, :finished, id}, %{assigns: %{playing: id}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :playing, nil)}

  def handle_info({:player, :finished, _stale}, socket), do: {:noreply, socket}

  def handle_info({:tap, {:open, id}}, socket), do: {:noreply, open(socket, id, :roll)}

  def handle_info({:tap, {:more, id}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, sheet: {:menu, id}, notice: nil)}

  def handle_info({:tap, {:rename, id}}, socket) do
    name = find(socket.assigns, id).name
    {:noreply, Mob.Socket.assign(socket, :sheet, {:rename, id, name})}
  end

  def handle_info({:change, :name, value}, %{assigns: %{sheet: {:rename, id, _}}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, {:rename, id, value})}

  def handle_info({:submit, :name}, %{assigns: %{sheet: {:rename, id, _}}} = socket),
    do: save_name(socket, id)

  def handle_info({:tap, {:save_name, id}}, %{assigns: %{sheet: {:rename, id, _}}} = socket),
    do: save_name(socket, id)

  def handle_info({:tap, {:sheet_music, id}}, socket), do: {:noreply, open(socket, id, :staff)}

  def handle_info({:tap, {:export, id, kind}}, socket) do
    phrase = find(socket.assigns, id)

    {:noreply,
     socket
     |> Mob.Socket.assign(sheet: nil, notice: nil)
     |> Mob.Socket.start_async(:export, fn -> PhraseActions.share(phrase, kind) end)}
  end

  def handle_info({:tap, {:share, id}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, {:share, id})}

  def handle_info({:tap, {:delete, id}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, {:delete, id})}

  # Already gone (deleted from another screen) is as good as deleted.
  def handle_info({:tap, {:confirm_delete, id}}, socket) do
    playing = if socket.assigns.playing == id, do: stop(socket), else: socket.assigns.playing
    _ = Phrases.delete(id)
    phrases = Enum.reject(socket.assigns.phrases, &(&1.id == id))
    {:noreply, Mob.Socket.assign(socket, phrases: phrases, sheet: nil, playing: playing)}
  end

  def handle_info({:tap, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:dismiss, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info(:phrases_changed, socket), do: {:noreply, load(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp save_name(socket, id) do
    {:rename, ^id, name} = socket.assigns.sheet

    case Phrases.rename(id, name) do
      {:ok, renamed} ->
        phrases =
          Enum.map(socket.assigns.phrases, fn
            %Phrase{id: ^id} = p -> %{p | name: renamed.name}
            p -> p
          end)

        {:noreply, Mob.Socket.assign(socket, phrases: phrases, sheet: nil)}

      {:error, _} ->
        {:noreply, Mob.Socket.assign(socket, sheet: nil, notice: "Couldn't rename it.")}
    end
  end

  defp open(socket, id, tab) do
    socket
    |> leave()
    |> Mob.Socket.push_screen(PhraseScreen, %{id: id, tab: tab, notify: self()})
  end

  # Leaving for another screen: stop playing, close the sheet.
  defp leave(socket) do
    Mob.Socket.assign(socket, playing: stop(socket), sheet: nil)
  end

  defp stop(socket) do
    Player.stop(socket.assigns.player)
    nil
  end
end
