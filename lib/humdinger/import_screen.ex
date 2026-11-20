defmodule Humdinger.ImportScreen do
  @moduledoc """
  Import audio → notes (`design/shots/import_audio.webp`,
  `design/boards/12-import_audio.html`): pick a recording, choose the part
  to use, see the notes Humdinger hears in it, and take them on as a
  phrase.

  States (`stage`):

  - `:choose` — no file yet: Mimi and "Choose an audio file". On the phone
    the picker (`Mob.Files.pick/2`, audio types) opens as the screen opens.
  - `:analysing` — `Humdinger.Audio.impl().analyze_file/3` is decoding the
    file in the background; Mimi listens, with a spinner. Leaving the screen
    or picking another file ("Other file") cancels it
    (`cancel_analysis/1`), so its decoder never outlives the screen.
  - `:ready` — the analysis is kept in assigns and transcribed
    (`Humdinger.Transcribe.take/2`) again on every change, which is cheap:
    the range (drag the `Humdinger.Views.Waveform` box or its handles;
    "using 0:09 – 0:21"), Snap (the detected key, a key chosen in the menu,
    or Chromatic), Quantize (1/8 1/16 Triplet Off) and Ignore notes shorter
    than N ms (20…300, in 20s). It shows "Heard 14 notes · E minor · 84 bpm
    · one voice", a clear chip when the take is clean, and the notes in
    `Humdinger.Views.PianoRoll` with the unsure ones faded.
  - `{:error, text}` — the file couldn't be read (or this build has no
    audio engine); "Other file" tries again.

  `Mob.Files.pick/2` hands over a copy of the file in the app's cache that
  nothing else deletes: the screen removes it once the decoder is done with
  it (the analysis or its error arrived, it was cancelled, or it never
  started), and removes at once the copies it doesn't use (more than one
  file picked, not audio).

  Actions: Edit as a phrase (`Humdinger.Phrase.from_take/2` →
  `Humdinger.PhraseScreen`), Export .mid (the share sheet), Sheet music (the
  review on its Staff tab), Play out (`Humdinger.Player`; stop while
  playing). Every tap target carries `on_press_out={held()}`.

  Params: `notify:` passed on to the review (the Phrases list, reloaded
  after a save).
  """

  use Mob.Screen

  import Humdinger.Controls

  alias Humdinger.{
    Audio,
    Music,
    Phrase,
    PhraseActions,
    PhraseScreen,
    Player,
    Scale,
    Style,
    Transcribe
  }

  alias Humdinger.Views.{PianoRoll, Waveform}

  @wave_w 344
  @wave_h 62
  @roll_w 350
  @roll_h 210
  @min_selection_ms 1000
  @min_ms_range 20..300//20
  @quiet_ms 1000

  @impl true
  def mount(params, _session, socket) do
    {:ok, player} = Player.start_link()
    if device_calls?(), do: send(self(), {:tap, :pick})

    {:ok,
     Mob.Socket.assign(socket,
       stage: :choose,
       file: nil,
       ref: nil,
       analysis: nil,
       selection: nil,
       wave_drag: nil,
       snap: :detected,
       last_scale: :detected,
       detected: nil,
       quantize: :q16,
       min_ms: 60,
       take: nil,
       stats: nil,
       player: player,
       playing: false,
       sheet: nil,
       notice: nil,
       notify: Map.get(params, :notify)
     )}
  end

  defp device_calls?, do: Application.get_env(:humdinger, :device_calls, true)

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    back = {self(), :back}

    other =
      if assigns.stage != :choose,
        do: button("Other file", {self(), :pick}, kind: :header, id: "other_file")

    page([
      header(back, "Audio to notes", subtitle(assigns), other),
      body(assigns),
      sheet_for(assigns)
    ])
  end

  defp subtitle(%{file: nil}), do: nil
  defp subtitle(%{file: file, analysis: nil}), do: file.name
  defp subtitle(%{file: file, analysis: a}), do: "#{file.name} · #{clock(a.duration_ms)}"

  defp body(%{stage: :choose} = assigns) do
    message(
      %{mood: :listening, note: 64},
      "Turn a recording into notes",
      "A voice memo or any recording of one voice: humming, singing, whistling.",
      assigns.notice,
      button("Choose an audio file", {self(), :pick}, kind: :primary, id: "choose")
    )
  end

  defp body(%{stage: :analysing} = assigns) do
    message(
      %{mood: :listening, note: 64, look: {0, -1}},
      "Listening to #{assigns.file.name}…",
      "Finding the notes. Long recordings take a little while.",
      nil,
      ~MOB[<Progress color={Style.fm()} />]
    )
  end

  defp body(%{stage: {:error, text}}) do
    message(
      %{mood: :no_mic},
      "Couldn't read that one",
      text,
      nil,
      button("Choose another file", {self(), :pick}, kind: :primary, id: "choose")
    )
  end

  defp body(%{stage: :ready} = assigns) do
    ~MOB"""
    <Column weight={1} gap={12}>
      {wave_card(assigns)}
      {result_card(assigns)}
      {notes_roll(assigns)}
      {controls(assigns)}
      {notice(assigns.notice)}
      <Spacer />
      {actions(assigns)}
    </Column>
    """
  end

  defp message(mimi_state, title, text, note, action) do
    ~MOB"""
    <Column id="message" weight={1} align={:center} gap={12}>
      <Spacer />
      {mimi(120, 105, 112, mimi_state)}
      <Text
        text={title}
        font={:display}
        text_size={22}
        text_color={Style.text()}
        text_align="center"
      />
      <Text text={text} text_size={13} text_color={Style.text_2()} text_align="center" />
      {notice(note)}
      <Spacer />
      {action}
    </Column>
    """
  end

  defp wave_card(assigns) do
    {from, to} = assigns.selection
    drag = {self(), :wave}

    ~MOB"""
    <Box
      background={Style.surface()}
      corner_radius={16}
      padding_left={3}
      padding_right={3}
      padding_top={6}
      padding_bottom={10}
    >
      <Column gap={4}>
        {wave_canvas(assigns, drag)}
        <Row padding_left={7} padding_right={7} fill_width={true}>
          <Text
            id="using"
            text={"using #{clock(from)} – #{clock(to)}"}
            font={:mono}
            text_size={11}
            text_color={Style.muted()}
          />
          <Spacer />
          <Text
            text="drag to choose the part"
            font={:mono}
            text_size={11}
            text_color={Style.muted()}
          />
        </Row>
      </Column>
    </Box>
    """
  end

  defp wave_canvas(assigns, drag) do
    {w, h} = {@wave_w, @wave_h}
    ops = Waveform.ops(wave_data(assigns), w, h)

    ~MOB"""
    <Canvas id="wave" width={w} height={h} draw={ops} on_drag={drag} />
    """
  end

  defp notes_roll(assigns) do
    {w, h} = {@roll_w, @roll_h}
    ops = PianoRoll.ops(roll_data(assigns), w, h)

    ~MOB"""
    <Canvas id="notes" width={w} height={h} draw={ops} />
    """
  end

  defp result_card(%{stats: stats, take: take}) do
    {chip, chip_bg, chip_fg} =
      if stats.clear,
        do: {"clear", 0xFF24301A, Style.fm()},
        else: {"unclear", 0xFF33291A, Style.warn()}

    note = Enum.find_value(take.notes, & &1.midi)

    ~MOB"""
    <Box
      background={Style.surface()}
      corner_radius={14}
      padding_left={12}
      padding_right={12}
      padding_top={8}
      padding_bottom={8}
    >
      <Row align={:center} gap={10}>
        {mimi(45, 39, 45, %{mood: if(stats.note_count > 0, do: :singing, else: :idle), note: note})}
        <Column weight={1} gap={2}>
          <Text
            id="heard"
            text={heard(stats.note_count)}
            font={:bold}
            text_size={14}
            text_color={Style.text()}
          />
          <Text
            id="stats"
            text={stats_line(stats)}
            font={:mono}
            text_size={11}
            text_color={Style.muted()}
          />
        </Column>
        <Box
          id="clarity"
          fill_width={false}
          corner_radius={8}
          background={chip_bg}
          padding_left={8}
          padding_right={8}
          padding_top={4}
          padding_bottom={4}
        >
          <Text text={chip} font={:semibold} text_size={11} text_color={chip_fg} />
        </Box>
      </Row>
    </Box>
    """
  end

  defp controls(assigns) do
    chromatic = assigns.snap == :chromatic

    snaps = [
      %{
        id: "seg_scale",
        label: scale_label(assigns) <> " ▾",
        tap: {self(), :snap_scale},
        selected: not chromatic
      },
      %{
        id: "seg_chromatic",
        label: "Chromatic",
        tap: {self(), :snap_chromatic},
        selected: chromatic
      }
    ]

    quantizes =
      segments(
        [q8: "1/8", q16: "1/16", triplet: "Triplet", off: "Off"],
        assigns.quantize,
        :quantize
      )

    ignore =
      stepper("ignore", "#{assigns.min_ms} ms", {self(), {:min_ms, -20}}, {self(), {:min_ms, 20}},
        height: 42,
        caption: "notes shorter than"
      )

    ~MOB"""
    <Column gap={8}>
      {labelled("Snap", 74, segmented(snaps, height: 36, text_size: 12))}
      {labelled("Quantize", 74, segmented(quantizes, height: 36, text_size: 12))}
      {labelled("Ignore", 74, ignore)}
    </Column>
    """
  end

  defp actions(assigns) do
    action = fn id, label, tag ->
      button(label, {self(), tag}, kind: :action, id: id, height: 46, text_size: 13)
    end

    buttons = [
      action.("export_mid", "Export .mid", :export_mid),
      action.("sheet_music", "Sheet music", :sheet_music),
      action.("play_out", if(assigns.playing, do: "Stop", else: "Play out"), :play)
    ]

    ~MOB"""
    <Column gap={8}>
      {button("Edit as a phrase", {self(), :edit}, kind: :primary, id: "edit", height: 54)}
      {action_row(buttons)}
    </Column>
    """
  end

  defp sheet_for(%{sheet: :scale} = assigns) do
    current = chosen_scale(assigns)
    dismiss = {self(), :dismiss}

    roots =
      for root <- 0..11 do
        chip(Music.pitch_class_name(root), root == current.root, {self(), {:root, root}},
          kind: :menu,
          id: "root_#{root}"
        )
      end

    modes =
      for mode <- Scale.modes(), mode != :chromatic do
        label =
          Scale.name(Scale.new(current.root, mode)) |> String.split(" ", parts: 2) |> List.last()

        chip(label, mode == current.mode, {self(), {:mode, mode}},
          kind: :menu,
          id: "mode_#{mode}"
        )
      end

    detected =
      if assigns.detected,
        do:
          menu_item(
            "detected",
            "Detected: " <> Scale.name(assigns.detected),
            {self(), :snap_detected}
          )

    sheet("scale", dismiss, [
      sheet_title("Snap to", note: "Notes land on this key's notes."),
      detected,
      ~MOB"""
      <Wrap spacing={6} run_spacing={6} fill_width={true}>
        {roots}
      </Wrap>
      """,
      ~MOB"""
      <Wrap spacing={6} run_spacing={6} fill_width={true}>
        {modes}
      </Wrap>
      """,
      button("Done", dismiss, kind: :primary, id: "done", height: 48)
    ])
  end

  defp sheet_for(_assigns), do: nil

  # ── Data ────────────────────────────────────────────────────────────────

  defp wave_data(assigns) do
    %{
      peaks: assigns.analysis.waveform,
      duration_ms: assigns.analysis.duration_ms,
      selection: assigns.selection
    }
  end

  defp roll_data(%{take: take}) do
    %{
      notes: take.notes,
      trace: take.trace,
      scale: take.scale,
      tempo_bpm: take.tempo_bpm,
      selected: nil,
      duration_ms: take.duration_ms
    }
  end

  defp heard(0), do: "Heard no notes"
  defp heard(1), do: "Heard 1 note"
  defp heard(n), do: "Heard #{n} notes"

  defp stats_line(stats) do
    key = if stats.scale, do: Scale.name(stats.scale), else: "no key"
    tempo = if stats.tempo_bpm, do: "#{stats.tempo_bpm} bpm", else: "free time"
    voices = if stats.voices == :one, do: "one voice", else: "several voices"
    Enum.join([key, tempo, voices], " · ")
  end

  # The scale segment's name: the key in use, or the one Snap goes back to.
  defp scale_label(assigns) do
    case if(assigns.snap == :chromatic, do: assigns.last_scale, else: assigns.snap) do
      %Scale{} = scale -> Scale.name(scale)
      :detected when assigns.detected != nil -> Scale.name(assigns.detected)
      :detected -> "Key"
    end
  end

  # What the scale menu starts from.
  defp chosen_scale(assigns) do
    case assigns.snap do
      %Scale{} = scale -> scale
      _ -> assigns.detected || Scale.new(0, :major)
    end
  end

  @doc "A time in the file as m:ss."
  @spec clock(number()) :: String.t()
  def clock(ms) do
    s = div(round(ms), 1000)
    "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_async(:share, {:ok, {:ok, path, title}}, socket),
    do: {:noreply, PhraseActions.share(socket, path, title)}

  def handle_async(:share, {:ok, {:error, _} = error}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text(error))}

  def handle_async(:share, {:exit, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text({:exit, reason}))}

  @impl true
  def terminate(_reason, socket) do
    cancel_analysis(socket)
    discard_file(socket)
  end

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:mob_share, :error, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :notice, PhraseActions.error_text({:error, reason}))}

  def handle_info({:tap, :back}, socket) do
    stop(socket)
    cancel_analysis(socket)
    {:noreply, socket |> discard_file() |> Mob.Socket.pop_screen()}
  end

  def handle_info({:tap, :pick}, socket) do
    socket = Mob.Socket.assign(socket, :notice, nil)
    {:noreply, if(device_calls?(), do: Mob.Files.pick(socket, types: [:audio]), else: socket)}
  end

  def handle_info({:files, :picked, items}, socket) do
    case Mob.Files.accept(items, [:audio]) do
      [%{path: path, name: name} | _] ->
        discard_unused(items, path)
        {:noreply, analyse(socket, path, name)}

      [] ->
        discard_unused(items, nil)
        {:noreply, Mob.Socket.assign(socket, :notice, "That isn't an audio file.")}
    end
  end

  def handle_info({:hum_audio, ref, {:analysis, analysis}}, %{assigns: %{ref: ref}} = socket) do
    socket =
      Mob.Socket.assign(socket,
        stage: :ready,
        analysis: analysis,
        selection: {0, analysis.duration_ms},
        snap: :detected,
        last_scale: :detected
      )

    {:noreply, socket |> discard_file() |> transcribe()}
  end

  def handle_info({:hum_audio, ref, {:analysis_error, reason}}, %{assigns: %{ref: ref}} = socket) do
    socket = Mob.Socket.assign(socket, stage: {:error, error_text(reason)}, ref: nil)
    {:noreply, discard_file(socket)}
  end

  def handle_info(_msg, %{assigns: %{stage: stage}} = socket) when stage != :ready,
    do: {:noreply, socket}

  def handle_info({:drag, :wave, %{phase: :began} = e}, socket), do: {:noreply, grab(socket, e)}

  def handle_info({:drag, :wave, %{phase: phase} = e}, socket)
      when phase in [:dragging, :ended] do
    socket = if socket.assigns.wave_drag, do: socket, else: grab(socket, e)
    socket = move(socket, e)
    {:noreply, if(phase == :ended, do: release(socket), else: socket)}
  end

  def handle_info({:wave_quiet, token}, %{assigns: %{wave_drag: %{token: token}}} = socket),
    do: {:noreply, release(socket)}

  def handle_info({:tap, :snap_scale}, %{assigns: %{snap: :chromatic}} = socket),
    do: {:noreply, socket |> Mob.Socket.assign(:snap, socket.assigns.last_scale) |> transcribe()}

  def handle_info({:tap, :snap_scale}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, :scale)}

  def handle_info({:tap, :snap_chromatic}, socket) do
    last =
      if socket.assigns.snap == :chromatic,
        do: socket.assigns.last_scale,
        else: socket.assigns.snap

    {:noreply, socket |> Mob.Socket.assign(snap: :chromatic, last_scale: last) |> transcribe()}
  end

  def handle_info({:tap, :snap_detected}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(snap: :detected, sheet: nil) |> transcribe()}

  def handle_info({:tap, {:root, root}}, socket) do
    scale = %{chosen_scale(socket.assigns) | root: root}
    {:noreply, socket |> Mob.Socket.assign(:snap, scale) |> transcribe()}
  end

  def handle_info({:tap, {:mode, mode}}, socket) do
    scale = Scale.new(chosen_scale(socket.assigns).root, mode)
    {:noreply, socket |> Mob.Socket.assign(:snap, scale) |> transcribe()}
  end

  def handle_info({:tap, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:dismiss, :dismiss}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:tap, {:quantize, q}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:quantize, q) |> transcribe()}

  def handle_info({:tap, {:min_ms, delta}}, socket) do
    min_ms =
      (socket.assigns.min_ms + delta) |> max(@min_ms_range.first) |> min(@min_ms_range.last)

    {:noreply, socket |> Mob.Socket.assign(:min_ms, min_ms) |> transcribe()}
  end

  def handle_info({:tap, :edit}, socket) do
    stop(socket)

    {:noreply,
     socket
     |> Mob.Socket.assign(:playing, false)
     |> Mob.Socket.push_screen(PhraseScreen, %{
       phrase: phrase(socket.assigns),
       notify: socket.assigns.notify
     })}
  end

  def handle_info({:tap, :sheet_music}, socket) do
    stop(socket)

    {:noreply,
     socket
     |> Mob.Socket.assign(:playing, false)
     |> Mob.Socket.push_screen(PhraseScreen, %{
       phrase: phrase(socket.assigns),
       tab: :staff,
       notify: socket.assigns.notify
     })}
  end

  def handle_info({:tap, :export_mid}, socket) do
    phrase = phrase(socket.assigns)

    {:noreply,
     socket
     |> Mob.Socket.assign(:notice, nil)
     |> Mob.Socket.start_async(:share, fn -> PhraseActions.write_share(phrase, :mid) end)}
  end

  def handle_info({:tap, :play}, %{assigns: %{playing: true}} = socket) do
    stop(socket)
    {:noreply, Mob.Socket.assign(socket, :playing, false)}
  end

  def handle_info({:tap, :play}, socket) do
    notes = socket.assigns |> phrase() |> Phrase.quantized_notes()
    :ok = Player.play(socket.assigns.player, notes, :take)
    {:noreply, Mob.Socket.assign(socket, :playing, true)}
  end

  def handle_info({:player, :finished, :take}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :playing, false)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Steps ───────────────────────────────────────────────────────────────

  defp analyse(socket, path, name) do
    stop(socket)
    cancel_analysis(socket)

    base =
      socket
      |> discard_file()
      |> Mob.Socket.assign(
        file: %{path: path, name: name},
        analysis: nil,
        take: nil,
        stats: nil,
        playing: false,
        notice: nil
      )

    case start_analysis(path) do
      {:ok, ref} ->
        Mob.Socket.assign(base, stage: :analysing, ref: ref)

      {:error, reason} ->
        base |> Mob.Socket.assign(stage: {:error, error_text(reason)}, ref: nil) |> discard_file()
    end
  end

  defp start_analysis(path) do
    impl = Audio.impl()

    if Code.ensure_loaded?(impl) and function_exported?(impl, :analyze_file, 3),
      do: impl.analyze_file(self(), path, []),
      else: {:error, :no_engine}
  end

  defp error_text(:no_engine), do: "This build has no audio engine, so it can't read audio files."
  defp error_text(:not_supported), do: "This phone can't decode that kind of file."
  defp error_text(:too_long), do: "It's longer than 10 minutes. Trim it and try again."
  defp error_text(:busy), do: "Another file is still being read. Try again in a moment."
  defp error_text(reason) when is_atom(reason), do: "The file couldn't be decoded (#{reason})."
  defp error_text(_reason), do: "The file couldn't be decoded."

  defp transcribe(%{assigns: a} = socket) do
    snap =
      case a.snap do
        :detected -> []
        :chromatic -> [snap: :chromatic]
        %Scale{} = scale -> [snap: scale]
      end

    opts =
      [range: a.selection, quantize: a.quantize, min_ms: a.min_ms, name: a.file.name] ++ snap

    {take, stats} = Transcribe.take(a.analysis, opts)

    detected =
      if a.snap == :detected, do: stats.scale || a.detected, else: a.detected || stats.scale

    Mob.Socket.assign(socket, take: take, stats: stats, detected: detected)
  end

  defp phrase(assigns) do
    name = assigns.file.name |> Path.rootname() |> String.trim()

    Phrase.from_take(assigns.take,
      name: name,
      quantize: assigns.quantize,
      now: DateTime.utc_now()
    )
  end

  # The drag's first point: a handle, the box, or the strip outside it (that
  # edge jumps there and follows the finger).
  defp grab(socket, %{x: x, y: y}) do
    data = wave_data(socket.assigns)
    {from, to} = sel = socket.assigns.selection
    duration = data.duration_ms

    {target, sel} =
      case Waveform.hit(data, @wave_w, @wave_h, x, y) do
        {:handle, edge} ->
          {edge, sel}

        {:range, _ms} ->
          {:range, sel}

        {:outside, ms} when ms < from ->
          {:start, Waveform.drag(sel, :start, ms - from, duration, min_selection(duration))}

        {:outside, ms} ->
          {:end, Waveform.drag(sel, :end, ms - to, duration, min_selection(duration))}

        :none ->
          {nil, sel}
      end

    if target do
      drag = %{target: target, x0: x, sel0: sel, token: nil}
      socket |> Mob.Socket.assign(selection: sel, wave_drag: drag) |> quiet_timer()
    else
      Mob.Socket.assign(socket, :wave_drag, nil)
    end
  end

  defp move(%{assigns: %{wave_drag: nil}} = socket, _e), do: socket

  defp move(%{assigns: %{wave_drag: drag, analysis: a}} = socket, %{x: x}) do
    dx = round((x - drag.x0) * Waveform.ms_per_dp(a.duration_ms, @wave_w))
    sel = Waveform.drag(drag.sel0, drag.target, dx, a.duration_ms, min_selection(a.duration_ms))
    socket |> Mob.Socket.assign(:selection, sel) |> quiet_timer()
  end

  # The drag is over: transcribe the new range.
  defp release(socket), do: socket |> Mob.Socket.assign(:wave_drag, nil) |> transcribe()

  defp min_selection(duration), do: min(@min_selection_ms, duration)

  # MOB-511: a drag whose end is lost ends after a second without events.
  defp quiet_timer(%{assigns: %{wave_drag: %{} = drag}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:wave_quiet, token}, @quiet_ms)
    Mob.Socket.assign(socket, :wave_drag, %{drag | token: token})
  end

  defp stop(socket), do: Player.stop(socket.assigns.player)

  # The decoder thread of the current analysis, if any, stops: on leaving the
  # screen and before another file replaces it.
  defp cancel_analysis(%{assigns: %{ref: ref, stage: :analysing}}) when is_reference(ref) do
    impl = Audio.impl()
    if function_exported?(impl, :cancel_analysis, 1), do: impl.cancel_analysis(ref)
    :ok
  end

  defp cancel_analysis(_socket), do: :ok

  # The picked copy (see the moduledoc) goes once the decoder no longer needs
  # it. A cancelled decoder may still have it open: unlinking is safe then.
  defp discard_file(%{assigns: %{file: %{path: path} = file}} = socket) when is_binary(path) do
    _ = File.rm(path)
    Mob.Socket.assign(socket, :file, %{file | path: nil})
  end

  defp discard_file(socket), do: socket

  defp discard_unused(items, keep) do
    for %{path: path} when is_binary(path) and path != keep <- items, do: File.rm(path)
    :ok
  end
end
