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

  alias Humdinger.{Audio, Mimi, Music, Style}
  alias Humdinger.Views.{PianoStrip, QrFrame, RangeBar, Spectrum, TuningMeter, Waveform}

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
    mimi_scenes() ++ live_scenes() ++ spectrum_scenes() ++ import_pair_scenes()
  end

  # Boards 02-live (top) and 05-first_run.
  defp live_scenes do
    strip = %{low: 62, high: 76, active: 69, pitch: 68.78, range: {40, 84}}
    black = %{low: 62, high: 76, active: 66, pitch: 66.2, range: nil}

    [
      {"PianoStrip: A4, a little flat", 334, 129, PianoStrip.ops(strip, 334, 129)},
      {"PianoStrip: F#4 lit", 334, 129, PianoStrip.ops(black, 334, 129)},
      {"TuningMeter: −12¢", 213, 22, TuningMeter.ops(%{cents: -12.0, tolerance: 10}, 213, 22)},
      {"RangeBar: choosing the lowest", 342, 46,
       RangeBar.ops(%{pitch: 40.0, low: 40, high: nil}, 342, 46)}
    ]
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
