defmodule Humdinger.PhraseScreen do
  @moduledoc """
  Review a phrase: the piano roll (`design/shots/record_review.webp`,
  `design/boards/06-record_review.html`) and the staff
  (`design/shots/sheet_music.webp`, `design/boards/10-sheet_music.html`),
  as a Piano roll | Staff segmented control.

  Params: `phrase:` (a `Humdinger.Phrase`, e.g. fresh from a recording or an
  import, not saved yet) or `id:` (a saved one, loaded with
  `start_async/3`); `tab:` `:roll` (default) or `:staff`; `notify:` a pid
  that gets `:phrases_changed` after a save (the Phrases list);
  `return_to:` the Live screen that pushed it, which gets `:hum_again`.

  Header: back, the name (tap to rename) and `Humdinger.Phrase.summary/1`;
  on the roll, "Hum again" (back to Live; Live records again when it pushed
  this screen).

  **Piano roll**: `Humdinger.Views.PianoRoll` of the notes on the phrase's
  grid (as sung when Off). Drag a note up or down to move it by rows
  (`Phrase.move_note/3`), drag its ends to change its length
  (`Phrase.resize_note/4`); the drag starts where the view's hit-test puts
  the `began` point, the note grabbed becomes the selected one, and a drag
  whose end never arrives (MOB-511) ends after 1 s without events. Quantize
  1/4 1/8 1/16 Off, Tempo − / + (1 bpm). Actions: "Play out to <the
  destination>" (stop while playing), Save (`Humdinger.Phrases.save/1`;
  "Saved" until the next edit), Export .mid (the share sheet), Discard
  (asks first when there is something unsaved). The header's back asks the
  same.

  **System Back** (Android's back gesture) can't be intercepted: Mob's
  router pops the screen without asking it (`Mob.Router`, `{:mob, :back}`).
  So a screen that leaves any other way than through Discard, back with
  nothing unsaved, or Hum again saves its phrase as it is in `terminate/2`
  (and tells `notify:`): a new phrase lands in the Phrases list, edits to a
  saved one are kept. Work is never lost silently; Discard stays the way
  to drop it.

  **Staff**: `Humdinger.Views.Staff` of `Humdinger.Notation.layout/2`, Clef
  Auto/Treble/Bass, Rhythm As sung / Simpler (1/4), Note names, the key
  caption. Actions: Share as PDF, MusicXML (share sheet), Print, Play back.

  Playing re-renders the screen, so every tap target carries
  `on_press_out={held()}`.
  """

  use Mob.Screen

  import Humdinger.Controls

  require Logger

  alias Humdinger.{Notation, Phrase, PhraseActions, Phrases, Player, Style}
  alias Humdinger.Views.{Draw, PianoRoll, Staff}

  @roll_w 350
  @roll_h 312
  @staff_w 350
  @quiet_ms 1000

  @impl true
  def mount(params, _session, socket) do
    {:ok, player} = Player.start_link()

    socket =
      Mob.Socket.assign(socket,
        phrase: :loading,
        saved: nil,
        tab: Map.get(params, :tab, :roll),
        selected: nil,
        drag: nil,
        clef: :auto,
        rhythm: :as_sung,
        note_names: true,
        player: player,
        playing: false,
        play_label: PhraseActions.play_label(PhraseActions.destinations()),
        sheet: nil,
        notice: nil,
        notify: Map.get(params, :notify),
        return_to: Map.get(params, :return_to),
        left: false
      )

    socket =
      case params do
        %{phrase: %Phrase{id: nil} = phrase} ->
          Mob.Socket.assign(socket, phrase: phrase)

        %{phrase: %Phrase{} = phrase} ->
          Mob.Socket.assign(socket, phrase: phrase, saved: phrase)

        %{id: id} ->
          Mob.Socket.start_async(socket, :load, fn -> Phrases.get(id) end)
      end

    {:ok, socket}
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(%{phrase: %Phrase{}} = assigns) do
    p = assigns.phrase
    back = {self(), :back}
    rename = {self(), :rename}

    right =
      if assigns.tab == :roll,
        do: button("Hum again", {self(), :hum_again}, kind: :header, id: "hum_again")

    tabs = segments([roll: "Piano roll", staff: "Staff"], assigns.tab, :tab)

    page(
      [
        header(back, p.name, Phrase.summary(p), right, title_tap: rename),
        ~MOB"""
        <Row fill_width={true}>
          {segmented(tabs, height: 38)}
        </Row>
        """,
        tab_body(assigns),
        sheet_for(assigns)
      ],
      gap: 14
    )
  end

  def render(assigns) do
    back = {self(), :leave}

    message =
      if assigns.phrase == :missing, do: "This phrase isn't on the phone any more.", else: nil

    status =
      if message,
        do: ~MOB[<Text id="missing" text={message} text_size={14} text_color={Style.text_2()} />],
        else: ~MOB[<Progress color={Style.fm()} />]

    page([header(back, "Phrase", nil, nil), status], gap: 14)
  end

  defp tab_body(%{tab: :roll} = assigns) do
    p = assigns.phrase
    drag = {self(), :roll}
    roll = PianoRoll.ops(roll_data(p, assigns.selected), @roll_w, @roll_h)

    quantize = segments([q4: "1/4", q8: "1/8", q16: "1/16", off: "Off"], p.quantize, :quantize)

    tempo = "#{p.tempo_bpm} bpm" <> if(p.tempo_detected, do: " · detected", else: "")
    clean = clean?(assigns)

    actions = [
      button(if(clean, do: "Saved", else: "Save"), {self(), :save}, kind: :action, id: "save"),
      button("Export .mid", {self(), {:share, :mid}}, kind: :action, id: "export_mid"),
      button("Discard", {self(), :discard}, kind: :outline, id: "discard")
    ]

    ~MOB"""
    <Column weight={1} gap={14}>
      <Column gap={10}>
        {roll_canvas(roll, drag)}
        <Text
          text="Drag a note up or down to fix it; drag its ends to change length. The faint line is what you actually sang."
          text_size={12}
          text_color={Style.muted()}
        />
      </Column>
      {labelled("Quantize", 64, segmented(quantize, height: 38))}
      {labelled("Tempo", 64, stepper("tempo", tempo, {self(), {:tempo, -1}}, {self(), {:tempo, 1}}))}
      {notice(assigns.notice)}
      <Spacer />
      <Column gap={8}>
        {play_out(assigns.playing, assigns.play_label)}
        {action_row(actions)}
      </Column>
    </Column>
    """
  end

  defp tab_body(%{tab: :staff} = assigns) do
    p = assigns.phrase
    data = staff_data(assigns)
    h = Staff.height(data, @staff_w)

    clefs = segments([auto: "Auto", treble: "Treble", bass: "Bass"], assigns.clef, :clef)

    rhythms =
      segments(
        [as_sung: "As sung (#{grid_label(p.quantize)})", simpler: "Simpler (1/4)"],
        assigns.rhythm,
        :rhythm
      )

    names = {self(), :note_names}

    caption =
      Notation.key_caption(p.scale) <>
        " Transpose on the home screen to move it somewhere easier to play."

    actions = [
      button("MusicXML", {self(), {:share, :musicxml}}, kind: :action, id: "musicxml"),
      button("Print", {self(), :print}, kind: :action, id: "print"),
      button(if(assigns.playing, do: "Stop", else: "Play back"), {self(), :play},
        kind: :action,
        id: "play_back"
      )
    ]

    ~MOB"""
    <Column weight={1} gap={14}>
      <Scroll weight={1}>
        <Column gap={14}>
          {staff_canvas(data, h)}
          <Column gap={8}>
            {labelled("Clef", 70, segmented(clefs, height: 36))}
            {labelled("Rhythm", 70, segmented(rhythms, height: 36))}
            <Row align={:center} gap={12} fill_width={true}>
              <Column weight={1} gap={2}>
                <Text text="Note names" font={:semibold} text_size={14} text_color={Style.text()} />
                <Text
                  text="letters in their pitch colours, for learning"
                  text_size={12}
                  text_color={Style.muted()}
                />
              </Column>
              <Toggle
                id="note_names"
                value={assigns.note_names}
                color={Style.ink()}
                track_color={Style.fm()}
                on_change={names}
              />
            </Row>
            <Text text={caption} text_size={12} text_color={Style.muted()} />
            {notice(assigns.notice)}
          </Column>
        </Column>
      </Scroll>
      <Column gap={8}>
        {button("Share as PDF", {self(), {:share, :pdf}}, kind: :primary, id: "share_pdf")}
        {action_row(actions)}
      </Column>
    </Column>
    """
  end

  defp play_out(playing, label) do
    if playing,
      do: button("Stop", {self(), :play}, kind: :primary, id: "play_out", icon: :stop),
      else: button(label, {self(), :play}, kind: :primary, id: "play_out", icon: :play)
  end

  defp roll_canvas(ops, drag) do
    {w, h} = {@roll_w, @roll_h}

    ~MOB"""
    <Canvas id="roll" width={w} height={h} draw={ops} on_drag={drag} />
    """
  end

  defp staff_canvas(data, h) do
    w = @staff_w
    ops = Staff.ops(data, w, h)

    ~MOB"""
    <Canvas id="staff" width={w} height={h} draw={ops} />
    """
  end

  defp grid_label(:q4), do: "1/4"
  defp grid_label(:q8), do: "1/8"
  defp grid_label(:q16), do: "1/16"
  defp grid_label(:triplet), do: "triplets"
  defp grid_label(:off), do: "1/16"

  defp sheet_for(%{sheet: nil}), do: nil

  defp sheet_for(%{sheet: {:rename, name}}) do
    change = {self(), :name}

    sheet("rename", {self(), :dismiss}, [
      sheet_title("Rename"),
      ~MOB"""
      <TextField
        id="name"
        value={name}
        placeholder={Phrase.default_name()}
        on_change={change}
        on_submit={change}
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
        button("Done", {self(), :save_name}, kind: :action, id: "save_name")
      ])
    ])
  end

  defp sheet_for(%{sheet: :discard, phrase: p}) do
    {title, note} =
      if p.id == nil,
        do: {"Discard this phrase?", "It hasn't been saved, so it will be gone."},
        else: {"Discard your changes?", "The saved phrase stays as it was."}

    sheet("discard", {self(), :dismiss}, [
      sheet_title(title, note: note),
      action_row([
        button("Keep editing", {self(), :dismiss}, kind: :action, id: "keep"),
        button("Discard", {self(), :leave}, kind: :outline, id: "confirm_discard")
      ])
    ])
  end

  # ── Roll and staff data ─────────────────────────────────────────────────

  @doc """
  What the piano roll shows: the notes on the phrase's grid (as sung when
  Off), each with its index into `phrase.notes`, and the roll's data with
  `selected` (a phrase index) mapped onto them.
  """
  @spec roll_data(Phrase.t(), non_neg_integer() | nil) :: map()
  def roll_data(%Phrase{} = p, selected) do
    {notes, indexes} = view_notes(p)
    note_end = notes |> Enum.map(&(&1.start_ms + &1.dur_ms)) |> Enum.max(fn -> 0 end)

    %{
      notes: notes,
      indexes: indexes,
      trace: p.trace,
      scale: p.scale,
      tempo_bpm: p.tempo_bpm,
      selected: Enum.find_index(indexes, &(&1 == selected)),
      duration_ms: max(p.duration_ms, note_end)
    }
  end

  defp view_notes(%Phrase{quantize: :off, notes: notes}),
    do: {notes, Enum.to_list(0..(length(notes) - 1)//1)}

  defp view_notes(%Phrase{} = p) do
    step = Phrase.step_ms(p.tempo_bpm, p.quantize)

    p.notes
    |> Phrase.grid_notes(p.tempo_bpm, p.quantize)
    |> Enum.map(fn g ->
      {%{
         start_ms: g.start * step,
         dur_ms: (g.stop - g.start) * step,
         midi: g.midi,
         unsure: g.unsure
       }, g.index}
    end)
    |> Enum.unzip()
  end

  defp staff_data(assigns) do
    %{
      layout: Notation.layout(assigns.phrase, clef: assigns.clef, rhythm: assigns.rhythm),
      note_names: assigns.note_names
    }
  end

  defp clean?(%{phrase: %Phrase{id: id} = p, saved: saved}), do: id != nil and p == saved

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_async(:load, {:ok, %Phrase{} = phrase}, socket),
    do: {:noreply, Mob.Socket.assign(socket, phrase: phrase, saved: phrase)}

  def handle_async(:load, _missing, socket),
    do: {:noreply, Mob.Socket.assign(socket, :phrase, :missing)}

  def handle_async(:export, {:ok, result}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text(result))}

  def handle_async(:export, {:exit, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text({:exit, reason}))}

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  # Nothing to do until the phrase has loaded, but leaving.
  def handle_info({:tap, :leave}, socket), do: {:noreply, leave(socket)}

  def handle_info(_msg, %{assigns: %{phrase: phrase}} = socket) when not is_struct(phrase),
    do: {:noreply, socket}

  def handle_info({:tap, :back}, socket), do: discard(socket)
  def handle_info({:tap, :discard}, socket), do: discard(socket)

  # Recording again is the user's choice to drop this take: not autosaved.
  def handle_info({:tap, :hum_again}, socket) do
    if pid = socket.assigns.return_to, do: send(pid, :hum_again)
    stop(socket)

    {:noreply,
     socket |> Mob.Socket.assign(:left, true) |> Mob.Socket.pop_to(Humdinger.LiveScreen)}
  end

  def handle_info({:tap, {:tab, tab}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, tab: tab, drag: nil, notice: nil)}

  def handle_info({:tap, {:quantize, q}}, socket),
    do: {:noreply, edit(socket, &Phrase.set_quantize(&1, q))}

  def handle_info({:tap, {:tempo, delta}}, socket),
    do: {:noreply, edit(socket, &Phrase.set_tempo(&1, &1.tempo_bpm + delta))}

  def handle_info({:tap, {:clef, clef}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :clef, clef)}

  def handle_info({:tap, {:rhythm, rhythm}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :rhythm, rhythm)}

  def handle_info({:change, :note_names, on}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :note_names, on == true)}

  def handle_info({:tap, :play}, %{assigns: %{playing: true}} = socket) do
    stop(socket)
    {:noreply, Mob.Socket.assign(socket, :playing, false)}
  end

  def handle_info({:tap, :play}, socket) do
    :ok =
      Player.play(socket.assigns.player, Phrase.quantized_notes(socket.assigns.phrase), :phrase)

    {:noreply,
     Mob.Socket.assign(socket,
       playing: true,
       play_label: PhraseActions.play_label(PhraseActions.destinations())
     )}
  end

  def handle_info({:player, :finished, :phrase}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :playing, false)}

  def handle_info({:tap, :save}, socket) do
    case Phrases.save(socket.assigns.phrase) do
      {:ok, stored} ->
        if pid = socket.assigns.notify, do: send(pid, :phrases_changed)
        {:noreply, Mob.Socket.assign(socket, phrase: stored, saved: stored, notice: nil)}

      {:error, _} ->
        {:noreply, Mob.Socket.assign(socket, :notice, "Couldn't save it.")}
    end
  end

  def handle_info({:tap, {:share, kind}}, socket) do
    phrase = socket.assigns.phrase

    opts = [
      clef: socket.assigns.clef,
      rhythm: socket.assigns.rhythm,
      note_names: socket.assigns.note_names
    ]

    {:noreply,
     socket
     |> Mob.Socket.assign(:notice, nil)
     |> Mob.Socket.start_async(:export, fn -> PhraseActions.share(phrase, kind, opts) end)}
  end

  def handle_info({:tap, :print}, socket) do
    phrase = socket.assigns.phrase

    opts = [
      clef: socket.assigns.clef,
      rhythm: socket.assigns.rhythm,
      note_names: socket.assigns.note_names
    ]

    {:noreply,
     socket
     |> Mob.Socket.assign(:notice, nil)
     |> Mob.Socket.start_async(:export, fn -> PhraseActions.print(phrase, opts) end)}
  end

  def handle_info({:tap, :rename}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, {:rename, socket.assigns.phrase.name})}

  def handle_info({:change, :name, value}, %{assigns: %{sheet: {:rename, _}}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, {:rename, value})}

  def handle_info({:submit, :name}, %{assigns: %{sheet: {:rename, name}}} = socket),
    do: {:noreply, socket |> edit(&Phrase.rename(&1, name)) |> Mob.Socket.assign(:sheet, nil)}

  def handle_info({:tap, :save_name}, %{assigns: %{sheet: {:rename, name}}} = socket),
    do: {:noreply, socket |> edit(&Phrase.rename(&1, name)) |> Mob.Socket.assign(:sheet, nil)}

  def handle_info({:tap, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:dismiss, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:drag, :roll, %{phase: :began} = e}, socket), do: {:noreply, grab(socket, e)}

  def handle_info({:drag, :roll, %{phase: phase} = e}, socket)
      when phase in [:dragging, :ended] do
    socket = if socket.assigns.drag, do: socket, else: grab(socket, e)
    socket = move(socket, e)
    {:noreply, if(phase == :ended, do: Mob.Socket.assign(socket, :drag, nil), else: socket)}
  end

  def handle_info({:drag_quiet, token}, %{assigns: %{drag: %{token: token}}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, :drag, nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Editing ─────────────────────────────────────────────────────────────

  defp edit(socket, fun),
    do: Mob.Socket.assign(socket, phrase: fun.(socket.assigns.phrase), notice: nil)

  # A drag's first point: what it grabbed, on the roll as it was drawn then.
  defp grab(socket, %{x: x, y: y}) do
    phrase = socket.assigns.phrase
    data = roll_data(phrase, socket.assigns.selected)
    layout = PianoRoll.layout(data, @roll_w, @roll_h)

    case PianoRoll.hit(layout, @roll_w, @roll_h, x, y) do
      {:note, view_index, part} ->
        index = Enum.at(data.indexes, view_index)
        midi = Enum.at(data.notes, view_index).midi
        drag = %{index: index, part: part, midi: midi, layout: layout, phrase: phrase, token: nil}
        socket |> Mob.Socket.assign(selected: index, drag: drag) |> quiet_timer()

      {:empty, _} ->
        Mob.Socket.assign(socket, selected: nil, drag: nil)

      :none ->
        Mob.Socket.assign(socket, :drag, nil)
    end
  end

  defp move(%{assigns: %{drag: nil}} = socket, _e), do: socket

  defp move(%{assigns: %{drag: drag}} = socket, %{x: x, y: y}) do
    phrase =
      case drag.part do
        :body ->
          y = Draw.clamp(y, 0, @roll_h - 1)
          target = PianoRoll.midi_at(drag.layout, y) || drag.midi
          Phrase.move_note(drag.phrase, drag.index, target - drag.midi)

        edge ->
          ms = max(PianoRoll.ms_at(drag.layout, x), 0)
          Phrase.resize_note(drag.phrase, drag.index, edge, ms)
      end

    socket |> Mob.Socket.assign(:phrase, phrase) |> quiet_timer()
  end

  # MOB-511: a drag whose end is lost ends after a second without events.
  defp quiet_timer(%{assigns: %{drag: %{} = drag}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:drag_quiet, token}, @quiet_ms)
    Mob.Socket.assign(socket, :drag, %{drag | token: token})
  end

  defp quiet_timer(socket), do: socket

  defp discard(socket) do
    if dirty?(socket.assigns),
      do: {:noreply, Mob.Socket.assign(socket, :sheet, :discard)},
      else: {:noreply, leave(socket)}
  end

  defp dirty?(%{phrase: %Phrase{id: nil}}), do: true
  defp dirty?(assigns), do: not clean?(assigns)

  defp leave(socket) do
    stop(socket)
    socket |> Mob.Socket.assign(sheet: nil, left: true) |> Mob.Socket.pop_screen()
  end

  defp stop(socket), do: Player.stop(socket.assigns.player)

  # Popped by system Back (or the app going away) with unsaved work: keep it.
  @impl true
  def terminate(_reason, %{assigns: %{left: false, phrase: %Phrase{}} = assigns}) do
    if dirty?(assigns), do: autosave(assigns)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp autosave(%{phrase: phrase, notify: notify}) do
    case Phrases.save(phrase) do
      {:ok, _} ->
        if notify, do: send(notify, :phrases_changed)

      {:error, reason} ->
        Logger.warning(
          "Humdinger.PhraseScreen: couldn't keep the phrase on leaving: #{inspect(reason)}"
        )
    end
  end
end
