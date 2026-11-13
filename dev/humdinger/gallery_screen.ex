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

  alias Humdinger.{Audio, Mimi, Music, Scale, Style}

  alias Humdinger.Views.{
    PhraseThumb,
    PianoRoll,
    PianoStrip,
    PitchRoll,
    QrFrame,
    RangeBar,
    Spectrum,
    TuningMeter,
    Waveform
  }

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
    mimi_scenes() ++ live_scenes() ++ spectrum_scenes() ++ phrase_scenes() ++ import_pair_scenes()
  end

  # Boards 02-live (top) and 05-first_run.
  defp live_scenes do
    strip = %{low: 62, high: 76, active: 69, pitch: 68.78, range: {40, 84}}
    black = %{low: 62, high: 76, active: 66, pitch: 66.2, range: nil}

    [
      {"PianoStrip: A4, a little flat", 334, 129, PianoStrip.ops(strip, 334, 129)},
      {"PianoStrip: F#4 lit", 334, 129, PianoStrip.ops(black, 334, 129)},
      {"TuningMeter: −12¢", 213, 22, TuningMeter.ops(%{cents: -12.0, tolerance: 10}, 213, 22)},
      {"PitchRoll: D Dorian, singing up to A4", 350, 256,
       PitchRoll.ops(pitch_roll_sample(), 350, 256)},
      {"RangeBar: choosing the lowest", 342, 46,
       RangeBar.ops(%{pitch: 40.0, low: 40, high: nil}, 342, 46)}
    ]
  end

  # The board's trace and sent notes, from its pixel positions: the playhead
  # (x 306) is now, 4 s span 306 px; row r is MIDI 72 − r.
  defp pitch_roll_sample do
    now = 10_000
    t = fn x -> round(now - (306 - x) * 4000 / 306) end

    trace =
      for {x, row} <- [
            {40, 10.2},
            {70, 9.9},
            {100, 10.1},
            {108, 8.3},
            {146, 7.9},
            {158, 7.1},
            {200, 6.9},
            {214, 5.2},
            {256, 4.9},
            {268, 3.4},
            {290, 3.2},
            {306, 3.12}
          ],
          do: {t.(x), 72 - row}

    notes =
      for {x, row, w} <- [{40, 10, 60}, {104, 8, 46}, {154, 7, 52}, {210, 5, 50}, {264, 3, nil}] do
        %{start_ms: t.(x), end_ms: w && t.(x + w), midi: 72 - row}
      end

    %{now_ms: now, trace: trace, notes: notes, scale: Scale.new("D", :dorian), center_midi: 67}
  end

  # Boards 06-record_review, 12-import_audio (the editor) and 07-saved (thumbs).
  defp phrase_scenes do
    eighth = 60_000 / 96 / 2

    review = %{
      notes:
        for {s, d, m} <- [
              {0, 2, 62},
              {2, 1, 64},
              {3, 1, 65},
              {4, 3, 69},
              {8, 2, 65},
              {10, 2, 64},
              {12, 2, 62},
              {14, 2, 60}
            ] do
          %{start_ms: s * eighth, dur_ms: d * eighth, midi: m}
        end,
      trace: [
        {100, 62.2},
        {500, 62.0},
        {900, 63.1},
        {1200, 64.4},
        {1500, 65.2},
        {1700, 67.0},
        {2400, 69.1},
        {3000, 69.0},
        {3300, 66.6},
        {3800, 65.0},
        {4000, 64.2},
        {4500, 63.8},
        {4700, 62.2},
        {4900, 61.0}
      ],
      scale: Scale.new("D", :dorian),
      tempo_bpm: 96,
      selected: 4
    }

    sixteenth = 60_000 / 84 / 4

    heard =
      for {s, d, m, unsure} <- [
            {0, 2, 64, false},
            {2, 1, 67, false},
            {3, 1, 69, false},
            {4, 3, 71, false},
            {7, 1, 72, false},
            {8, 2, 71, false},
            {10, 2, 69, false},
            {12, 1, 67, false},
            {13, 1, 66, true},
            {14, 4, 64, false},
            {18, 2, 62, false},
            {20, 2, 64, false},
            {22, 1, 59, true},
            {23, 5, 64, false}
          ] do
        %{start_ms: s * sixteenth, dur_ms: d * sixteenth, midi: m, unsure: unsure}
      end

    sung =
      Enum.flat_map(Enum.with_index(heard), fn {n, i} ->
        wobble = if rem(i, 2) == 0, do: 0.15, else: -0.12
        [{n.start_ms + 20, n.midi + wobble}, {n.start_ms + n.dur_ms - 20, n.midi - wobble}]
      end)

    import = %{
      notes: heard,
      trace: sung,
      scale: Scale.new("E", :minor),
      tempo_bpm: 84,
      selected: nil
    }

    [
      {"PianoRoll: review, F4 selected", 350, 312, PianoRoll.ops(review, 350, 312)},
      {"PianoRoll: import, 2 unsure", 350, 210, PianoRoll.ops(import, 350, 210)},
      {"PhraseThumb: Bus stop riff", 326, 56,
       PhraseThumb.ops(
         %{
           notes:
             thumb_notes([{62, 2}, {64, 1}, {65, 1}, {69, 3}, {65, 2}, {64, 2}, {62, 2}, {60, 2}])
         },
         326,
         56
       )},
      {"PhraseThumb: Whistled hook", 326, 56,
       PhraseThumb.ops(
         %{notes: thumb_notes([{84, 1}, {86, 1}, {88, 2}, {86, 1}, {84, 1}, {79, 2}])},
         326,
         56
       )}
    ]
  end

  defp thumb_notes(seq) do
    {notes, _end} =
      Enum.map_reduce(seq, 0, fn {midi, beats}, at ->
        {%{start_ms: at * 250, dur_ms: beats * 250, midi: midi}, at + beats}
      end)

    notes
  end

  # Board 09-spectrum: D4, a glide to G4, a glide to A4, after a breath.
  defp spectrum_scenes do
    period = 33
    f0s = for c <- 0..119, do: board_f0(c / 119)

    columns =
      for {f0, c} <- Enum.with_index(f0s) do
        %{t: c * period, bins: voice_bins(f0)}
      end

    trace = for {f0, c} <- Enum.with_index(f0s), do: {c * period + 16, f0 && Music.hz_to_midi(f0)}

    data = %{
      columns: columns,
      trace: trace,
      now_ms: 119 * period,
      window_ms: 120 * period,
      pitch: 69.0
    }

    [
      {"Spectrum", 350, 470, Spectrum.ops(data, 350, 470)},
      {"Spectrum legend", 100, 12, Spectrum.legend_ops(100, 12)}
    ]
  end

  defp board_f0(t) when t < 0.08, do: nil
  defp board_f0(t) when t < 0.38, do: 294.0
  defp board_f0(t) when t < 0.45, do: 294 + (t - 0.38) / 0.07 * (392 - 294)
  defp board_f0(t) when t < 0.66, do: 392.0
  defp board_f0(t) when t < 0.72, do: 392 + (t - 0.66) / 0.06 * (440 - 392)
  defp board_f0(_t), do: 440.0

  # A sung vowel: harmonics k·f0 falling off as k^−0.4, each a narrow bump.
  defp voice_bins(nil), do: :binary.copy(<<0>>, Audio.spectrum_bins())

  defp voice_bins(f0) do
    for i <- 0..(Audio.spectrum_bins() - 1), into: <<>> do
      level =
        Enum.reduce(1..8, 0, fn k, acc ->
          d = (:math.log(Audio.bin_hz(i)) - :math.log(k * f0)) / 0.06
          max(acc, round(220 * :math.exp(-d * d) * :math.pow(k, -0.4)))
        end)

      <<level>>
    end
  end

  # Boards 12-import_audio (waveform) and 11-pair (viewfinder).
  defp import_pair_scenes do
    peaks =
      for i <- 0..759, into: <<>> do
        <<if(rem(div(i, 7), 9) < 6, do: 120 + rem(i * 37, 100), else: 20 + rem(i * 13, 30))>>
      end

    wave = %{peaks: peaks, duration_ms: 38_000, selection: {9_000, 21_000}}

    [
      {"Waveform: using 0:09 – 0:21", 344, 62, Waveform.ops(wave, 344, 62)},
      {"QrFrame: scanning", 350, 300, QrFrame.ops(%{state: :scanning}, 350, 300)},
      {"QrFrame: found", 350, 300, QrFrame.ops(%{state: :found}, 350, 300)}
    ]
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
