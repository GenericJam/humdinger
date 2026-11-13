defmodule Humdinger.SpectrumScreen do
  @moduledoc """
  Spectrum (board `09-spectrum`): what the microphone hears, as a heat-map
  of the voice's harmonics over the last 4 s with the pitch Humdinger heard
  drawn on top, so a singer can see why the note jumped to a harmonic.

  Opened from Live's "Spectrum ›" chip; "Notes" goes back. On mount it
  watches the Engine (`Engine.watch/0`) and turns its spectrum relay on
  (`Engine.spectrum(self(), true)`), and off again in `terminate/2` (the
  Engine also drops it when this process ends). After an engine restart it
  watches the new engine and turns the relay on again.

  The trace is the raw sung pitch (Hz → MIDI, before octave and transpose,
  so it sits on the harmonics). A frame's pitch is placed at its own `t`
  when that agrees with the columns' clock (within 250 ms), else at the
  newest column's time plus the time since it arrived (an engine that
  stamps columns with the audio clock). Messages arm a token-guarded 33 ms
  tick that redraws (≤ 30/s); columns older than the window are dropped.
  """

  use Mob.Screen

  import Humdinger.Controls

  alias Humdinger.{Engine, LiveFeed, Music, Style}
  alias Humdinger.Views.Spectrum

  @frame_ms 33
  @window_ms 4_000
  @box {350, 470}
  @mimi {60, 56}
  @rewatch_ms 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok, engine_mon} = Engine.watch()
    :ok = Engine.spectrum(self(), true)

    socket =
      Mob.Socket.assign(socket,
        frame: nil,
        shown: nil,
        columns: [],
        last_column: nil,
        feed: LiveFeed.new(@window_ms + 500),
        tick_token: nil,
        engine_mon: engine_mon,
        ops: Spectrum.ops(%{columns: [], trace: [], now_ms: 0, pitch: nil}, 350, 470),
        mimi_ops: mimi_ops(nil)
      )

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    {box_w, box_h} = @box
    {mimi_w, mimi_h} = @mimi
    shown = assigns.shown
    note = shown && shown.note
    name = if note, do: Music.note_name(note), else: "–"
    color = if note, do: Style.pitch_color(note), else: Style.faint()

    line_color =
      if shown && shown.hz, do: Style.pitch_color(Music.hz_to_midi(shown.hz)), else: Style.faint()

    tabs = [
      %{label: "Notes", tap: {self(), :notes}, selected: false},
      %{label: "Spectrum", tap: {self(), :spectrum}, selected: true}
    ]

    page([
      ~MOB"""
      <Row height={mimi_h} gap={12}>
        <Canvas width={mimi_w} height={mimi_h} draw={assigns.mimi_ops} />
        <Row gap={10} align={:bottom} weight={1}>
          <Text text={name} font={:display} text_size={44} line_height={1.0} text_color={color} />
          <Text text={readout(shown)} font={:mono_semibold} text_size={12} text_color={Style.muted()} />
        </Row>
      </Row>
      """,
      ~MOB"""
      <Row>
        {segmented(tabs, height: 38)}
      </Row>
      """,
      ~MOB(<Canvas width={box_w} height={box_h} draw={assigns.ops} />),
      ~MOB"""
      <Row gap={10}>
        <Canvas width={98} height={10} draw={Spectrum.legend_ops(98, 10)} />
        <Text text="quiet → loud" text_size={12} text_color={Style.text_2()} />
        <Spacer />
        <Box width={16} height={3} corner_radius={2} background={line_color} />
        <Text text="pitch it heard" text_size={12} text_color={Style.text_2()} />
      </Row>
      """,
      ~MOB"""
      <Text
        text="Your voice is a stack of bright lines. The lowest is the note; the ones above (×2, ×3…) are harmonics that give it its colour. If the coloured line jumps to a harmonic, try a softer, rounder vowel like “oo”."
        text_size={12}
        line_height={1.45}
        text_color={Style.muted()}
      />
      """
    ])
  end

  @doc ~S|The line beside the note: "440 Hz · −12¢", or what Mimi is doing.|
  def readout(nil), do: "listening…"

  def readout(%{hz: hz, cents: cents}) when is_number(hz) do
    cents_text =
      case cents && round(cents) do
        nil -> ""
        0 -> " · 0¢"
        c when c > 0 -> " · +#{c}¢"
        c -> " · −#{-c}¢"
      end

    "#{round(hz)} Hz" <> cents_text
  end

  def readout(%{mood: :paused}), do: "paused"
  def readout(%{mood: :no_mic}), do: "no microphone"
  def readout(_frame), do: "listening…"

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:engine, :spectrum, column}, socket) do
    a = socket.assigns
    cut = column.t - @window_ms - 200

    # A column older than the newest is a new listen: start over.
    columns =
      case a.columns do
        [_ | _] = columns ->
          if column.t < List.last(columns).t, do: [], else: columns

        [] ->
          []
      end

    columns = Enum.drop_while(columns ++ [column], &(&1.t < cut))

    socket =
      Mob.Socket.assign(socket,
        columns: columns,
        last_column: {column.t, now_ms()},
        feed: if(columns == [column], do: LiveFeed.new(@window_ms + 500), else: a.feed)
      )

    {:noreply, schedule_tick(socket)}
  end

  def handle_info({:engine, :frame, frame}, socket) do
    a = socket.assigns

    feed =
      case a.last_column do
        {t, at} ->
          estimate = t + (now_ms() - at)
          # Use the frame's own time when the two clocks agree.
          t = if frame.t && abs(frame.t - estimate) < 250, do: frame.t, else: estimate
          t = max(t, a.feed.now || 0)
          pitch = if frame.hz, do: Music.hz_to_midi(frame.hz)
          LiveFeed.push(a.feed, %{t: t, pitch: pitch, note: nil})

        nil ->
          a.feed
      end

    {:noreply, socket |> Mob.Socket.assign(frame: frame, feed: feed) |> schedule_tick()}
  end

  def handle_info({:engine, _kind, _payload}, socket), do: {:noreply, socket}

  # The engine was restarted: watch the new one and ask for the spectrum again.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{assigns: %{engine_mon: mon}} = socket) do
    send(self(), :engine_rewatch)
    {:noreply, Mob.Socket.assign(socket, :engine_mon, nil)}
  end

  def handle_info(:engine_rewatch, %{assigns: %{engine_mon: nil}} = socket) do
    case Engine.watch() do
      {:ok, mon} ->
        :ok = Engine.spectrum(self(), true)
        {:noreply, Mob.Socket.assign(socket, :engine_mon, mon)}

      {:error, :down} ->
        Process.send_after(self(), :engine_rewatch, @rewatch_ms)
        {:noreply, socket}
    end
  end

  def handle_info(:engine_rewatch, socket), do: {:noreply, socket}

  def handle_info({:tick, token}, %{assigns: %{tick_token: token}} = socket) do
    a = socket.assigns
    {w, h} = @box
    pitch = LiveFeed.pitch(a.feed)
    newest = if a.columns == [], do: 0, else: List.last(a.columns).t
    now = max(newest, a.feed.now || 0)

    ops =
      Spectrum.ops(
        %{
          columns: a.columns,
          trace: LiveFeed.trace(a.feed),
          now_ms: now,
          pitch: pitch,
          window_ms: @window_ms
        },
        w,
        h
      )

    {:noreply,
     Mob.Socket.assign(socket,
       tick_token: nil,
       shown: a.frame,
       ops: ops,
       mimi_ops: mimi_ops(a.frame)
     )}
  end

  def handle_info({:tick, _stale}, socket), do: {:noreply, socket}

  def handle_info({:tap, :notes}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info({:tap, :spectrum}, socket), do: {:noreply, socket}
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Engine.spectrum(self(), false)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_tick(%{assigns: %{tick_token: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:tick, token}, @frame_ms)
    Mob.Socket.assign(socket, :tick_token, token)
  end

  defp schedule_tick(socket), do: socket

  defp mimi_ops(frame) do
    {w, h} = @mimi
    mood = if frame, do: frame.mood, else: :listening
    note = frame && frame.note
    Humdinger.Mimi.ops(w / 2, h / 2, w, %{mood: mood, note: note})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
