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
  router pops the screen without asking it (`Mob.Router`, `{:mob, :back}`),
  and when the app stops nothing orders the screens before the database.
  So unsaved work is kept as a draft (`Humdinger.PhraseDraft`, in
  `Mob.State`, not the database) from the moment it exists: a new phrase
  at mount, each edit half a second after it settles. Leaving any way
  other than Discard, back with nothing unsaved, or Hum again,
  `terminate/2` writes the draft once more and then tries to save the
  phrase (a new one lands in the Phrases list, edits to a saved one are
  kept, `notify:` hears); if the database is already gone it keeps the
  draft, and `Humdinger.PhraseDraft.recover/0` saves it at the next start.
  Saving and Discard delete the draft. Work is never lost silently;
  Discard stays the way to drop it.

  **Staff**: `Humdinger.Views.Staff` of `Humdinger.Notation.layout/2`, Clef
  Auto/Treble/Bass, Rhythm As sung / Simpler (1/4), Note names, the key
  caption. Actions: Share as PDF, MusicXML (share sheet), Print, Play back.

  Playing re-renders the screen, so every tap target carries
  `on_press_out={held()}`.
  """

  use Mob.Screen

  import Humdinger.Controls

  require Logger

  alias Humdinger.{Notation, Phrase, PhraseActions, PhraseDraft, Phrases, Player, Style}
  alias Humdinger.Views.{Draw, PianoRoll, Staff}

  @roll_w 350
  @roll_h 312
  @staff_w 350
  @quiet_ms 1000
  @draft_ms 500

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
        piano_tag: nil,
        piano_timeline: [],
        playhead_ms: nil,
        play_label: PhraseActions.play_label(PhraseActions.destinations()),
        sheet: nil,
        notice: nil,
        notify: Map.get(params, :notify),
        return_to: Map.get(params, :return_to),
        left: false,
        draft_key: PhraseDraft.new_key(),
        draft_token: nil
      )

    socket =
      case params do
        %{phrase: %Phrase{id: nil} = phrase} ->
          # A new phrase is unsaved work from the start: keep it at once.
          socket = Mob.Socket.assign(socket, phrase: phrase)
          PhraseDraft.put(socket.assigns.draft_key, phrase)
          socket

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
    active = active_index(assigns.piano_timeline, assigns.playhead_ms)

    roll =
      PianoRoll.ops(
        roll_data(p, assigns.selected, assigns.playhead_ms, active),
        @roll_w,
        @roll_h
      )

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
        <Row gap={8} fill_width={true}>
          {play_out(assigns.playing, assigns.play_label, weight: 2)}
          {play_piano(assigns.piano_tag != nil, kind: :action, height: 56, radius: 16, weight: 1)}
        </Row>
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
        <Column gap={14} padding_bottom={12}>
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
            <Text
              text={caption}
              text_size={12}
              line_height={1.4}
              fill_width={true}
              text_color={Style.muted()}
            />
            {notice(assigns.notice)}
          </Column>
        </Column>
      </Scroll>
      <Column gap={8}>
        <Row gap={8} fill_width={true}>
          {button("Share as PDF", {self(), {:share, :pdf}}, kind: :primary, id: "share_pdf", weight: 2)}
          {play_piano(assigns.piano_tag != nil, kind: :action, height: 56, radius: 16, weight: 1)}
        </Row>
        {action_row(actions)}
      </Column>
    </Column>
    """
  end

  defp play_out(playing, label, opts) do
    if playing do
      button("Stop", {self(), :play}, [
        {:kind, :primary},
        {:id, "play_out"},
        {:icon, :stop} | opts
      ])
    else
      button(label, {self(), :play}, [
        {:kind, :primary},
        {:id, "play_out"},
        {:icon, :play} | opts
      ])
    end
  end

  defp play_piano(playing?, opts) do
    if playing? do
      button("Stop piano", {self(), :play_piano}, [{:id, "play_piano"}, {:icon, :stop} | opts])
    else
      button("Piano", {self(), :play_piano}, [{:id, "play_piano"}, {:icon, :play} | opts])
    end
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
  `selected` and `active` (phrase indexes) mapped onto them.
  """
  @spec roll_data(
          Phrase.t(),
          non_neg_integer() | nil,
          number() | nil,
          non_neg_integer() | nil
        ) :: map()
  def roll_data(%Phrase{} = p, selected, playhead_ms \\ nil, active_index \\ nil) do
    {notes, indexes} = view_notes(p)
    note_end = notes |> Enum.map(&(&1.start_ms + &1.dur_ms)) |> Enum.max(fn -> 0 end)

    %{
      notes: notes,
      indexes: indexes,
      trace: p.trace,
      scale: p.scale,
      tempo_bpm: p.tempo_bpm,
      selected: Enum.find_index(indexes, &(&1 == selected)),
      active: Enum.find_index(indexes, &(&1 == active_index)),
      duration_ms: max(p.duration_ms, note_end),
      playhead_ms: playhead_ms
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
      note_names: assigns.note_names,
      tempo_bpm: assigns.phrase.tempo_bpm,
      playhead_ms: assigns.playhead_ms,
      active_index: active_index(assigns.piano_timeline, assigns.playhead_ms)
    }
  end

  defp active_index(timeline, ms) when is_list(timeline) and is_number(ms) do
    case Enum.find(timeline, fn {start_ms, end_ms, _i} -> start_ms <= ms and ms < end_ms end) do
      {_, _, i} -> i
      nil -> nil
    end
  end

  defp active_index(_timeline, _ms), do: nil

  defp piano_preview(%Phrase{quantize: :off} = p) do
    tagged =
      p.notes
      |> Enum.with_index(fn n, i -> Map.put(n, :index, i) end)
      |> Phrase.quantize_notes(p.tempo_bpm, :off)

    notes = Enum.map(tagged, &Map.delete(&1, :index))
    timeline = Enum.map(tagged, fn n -> {n.start_ms, n.start_ms + n.dur_ms, n.index} end)
    {notes, timeline}
  end

  defp piano_preview(%Phrase{} = p) do
    notes = Phrase.quantized_notes(p)

    timeline =
      notes
      |> Enum.zip(Phrase.grid_notes(p.notes, p.tempo_bpm, p.quantize))
      |> Enum.map(fn {n, g} -> {n.start_ms, n.start_ms + n.dur_ms, g.index} end)

    {notes, timeline}
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
    socket = stop_playback(socket)
    PhraseDraft.delete(socket.assigns.draft_key)

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

  def handle_info({:tap, :play}, %{assigns: %{playing: true}} = socket),
    do: {:noreply, stop_playback(socket)}

  def handle_info({:tap, :play}, socket) do
    notes = Phrase.quantized_notes(socket.assigns.phrase)

    case Player.play(socket.assigns.player, notes, :phrase) do
      :ok ->
        {:noreply,
         Mob.Socket.assign(socket,
           playing: true,
           piano_tag: nil,
           piano_timeline: [],
           playhead_ms: nil,
           play_label: PhraseActions.play_label(PhraseActions.destinations())
         )}

      {:error, reason} ->
        {:noreply,
         Mob.Socket.assign(socket,
           playing: false,
           piano_tag: nil,
           piano_timeline: [],
           playhead_ms: nil,
           notice: play_error_text(reason)
         )}
    end
  end

  def handle_info({:tap, :play_piano}, %{assigns: %{piano_tag: tag}} = socket) when tag != nil,
    do: {:noreply, stop_playback(socket)}

  def handle_info({:tap, :play_piano}, socket) do
    tag = make_ref()
    {notes, timeline} = piano_preview(socket.assigns.phrase)

    case Player.play(socket.assigns.player, notes, tag, mode: :piano) do
      :ok ->
        {:noreply,
         Mob.Socket.assign(socket,
           playing: false,
           piano_tag: tag,
           piano_timeline: timeline,
           playhead_ms: nil,
           notice: nil
         )}

      {:error, reason} ->
        {:noreply,
         Mob.Socket.assign(socket,
           playing: false,
           piano_tag: nil,
           piano_timeline: [],
           playhead_ms: nil,
           notice: piano_error_text(reason)
         )}
    end
  end

  def handle_info({:player, :finished, :phrase}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :playing, false)}

  def handle_info({:player, :position, tag, ms}, %{assigns: %{piano_tag: tag}} = socket)
      when is_reference(tag) and is_number(ms),
      do: {:noreply, Mob.Socket.assign(socket, :playhead_ms, ms)}

  def handle_info({:player, :finished, tag}, %{assigns: %{piano_tag: tag}} = socket)
      when is_reference(tag) do
    {:noreply, Mob.Socket.assign(socket, piano_tag: nil, piano_timeline: [], playhead_ms: nil)}
  end

  def handle_info({:player, :error, tag, reason}, %{assigns: %{piano_tag: tag}} = socket)
      when is_reference(tag) do
    {:noreply,
     Mob.Socket.assign(socket,
       piano_tag: nil,
       piano_timeline: [],
       playhead_ms: nil,
       notice: piano_error_text(reason)
     )}
  end

  def handle_info({:tap, :save}, socket) do
    case Phrases.save(socket.assigns.phrase) do
      {:ok, stored} ->
        if pid = socket.assigns.notify, do: send(pid, :phrases_changed)
        PhraseDraft.delete(socket.assigns.draft_key)

        {:noreply,
         Mob.Socket.assign(socket, phrase: stored, saved: stored, notice: nil, draft_token: nil)}

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

  # The edit has settled: keep it as the draft (or drop the draft if the
  # phrase is back to what is saved).
  def handle_info({:write_draft, token}, %{assigns: %{draft_token: token}} = socket) do
    if dirty?(socket.assigns),
      do: PhraseDraft.put(socket.assigns.draft_key, socket.assigns.phrase),
      else: PhraseDraft.delete(socket.assigns.draft_key)

    {:noreply, Mob.Socket.assign(socket, :draft_token, nil)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Editing ─────────────────────────────────────────────────────────────

  defp edit(socket, fun) do
    # Clear the old notice first: stopping may leave a newer one.
    socket
    |> Mob.Socket.assign(:notice, nil)
    |> stop_playback()
    |> put_phrase(fun.(socket.assigns.phrase))
  end

  # Every change to the phrase goes through here: the draft follows it once
  # it settles (a drag sends ~60 a second).
  defp put_phrase(socket, phrase) do
    token = make_ref()
    Process.send_after(self(), {:write_draft, token}, @draft_ms)
    Mob.Socket.assign(socket, phrase: phrase, draft_token: token)
  end

  # A drag's first point: what it grabbed, on the roll as it was drawn then.
  defp grab(socket, %{x: x, y: y}) do
    socket = stop_playback(socket)
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

    socket |> put_phrase(phrase) |> quiet_timer()
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
    socket = stop_playback(socket)
    PhraseDraft.delete(socket.assigns.draft_key)
    socket |> Mob.Socket.assign(sheet: nil, left: true) |> Mob.Socket.pop_screen()
  end

  defp stop_playback(%{assigns: %{playing: false, piano_tag: nil}} = socket), do: socket

  defp stop_playback(socket) do
    res = stop(socket)

    socket =
      Mob.Socket.assign(socket,
        playing: false,
        piano_tag: nil,
        piano_timeline: [],
        playhead_ms: nil
      )

    case res do
      {:error, reason} -> Mob.Socket.assign(socket, :notice, piano_error_text(reason))
      _ -> socket
    end
  end

  defp stop(socket), do: safe_stop(socket.assigns.player)

  defp safe_stop(player) when is_pid(player) do
    Player.stop(player)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop(_), do: :ok

  defp play_error_text(:stream_stuck), do: "The piano preview couldn't be stopped."
  defp play_error_text(_reason), do: "Couldn't play it."

  defp piano_error_text(reason) when reason in [:unavailable, :unsupported],
    do: "Piano sound isn't available on this device."

  defp piano_error_text(:too_long), do: "This phrase is too long for piano preview."
  defp piano_error_text(:stream_stuck), do: "The piano preview couldn't be stopped."
  defp piano_error_text(_reason), do: "Couldn't play the piano preview."

  # Popped by system Back, or the app stopping, with unsaved work: keep the
  # draft first (nothing here may depend on the database still running),
  # then try to save; a failed save leaves the draft for `PhraseDraft.recover/0`.
  @impl true
  def terminate(_reason, %{assigns: %{left: false, phrase: %Phrase{}} = assigns}) do
    safe_stop(Map.get(assigns, :player))
    if dirty?(assigns), do: keep(assigns)
    :ok
  end

  def terminate(_reason, %{assigns: assigns}) do
    safe_stop(Map.get(assigns, :player))
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp keep(%{phrase: phrase, notify: notify, draft_key: key}) do
    PhraseDraft.put(key, phrase)

    case PhraseDraft.save(phrase) do
      {:ok, _} ->
        PhraseDraft.delete(key)
        if notify, do: send(notify, :phrases_changed)

      {:error, reason} ->
        Logger.warning(
          "Humdinger.PhraseScreen: kept the phrase as a draft, couldn't save it: #{inspect(reason)}"
        )
    end
  end
end
