# Renders the canvases of the Live, Settings, Spectrum and First run screens
# on the host, driven through the screens themselves with the boards' sample
# data (singing up D4 → A4 a little flat, the spectrum board's glide, holding
# E2), to compare with design/shots/{live,settings,spectrum,first_run}.webp:
#
#     mise exec -- mix run --no-start scripts/preview_screens.exs [out_dir]
#
# Writes one PNG sheet per screen (default /tmp/humdinger_screens/).

Code.require_file("canvas_svg.exs", __DIR__)

defmodule PreviewAudio do
  @moduledoc false
  @behaviour Humdinger.Audio
  def listen(_owner, _opts), do: {:ok, make_ref()}
  def set_spectrum(_ref, _on), do: :ok
  def stop(_ref), do: :ok
  def inputs, do: []
  def analyze_file(_owner, _path, _opts), do: {:error, :not_supported}
end

defmodule PreviewOutput do
  @moduledoc false
  def send_events(_events), do: :ok
  def configure(_opts), do: :ok
  def subscribe(_pid), do: :ok

  def destinations,
    do: [
      %{id: :fmutate, name: "FMutate A", detail: "", enabled: true, available: true},
      %{id: :port, name: "Humdinger port", detail: "", enabled: true, available: true}
    ]
end

defmodule Preview do
  @moduledoc false
  alias Humdinger.{Audio, Music}

  def mount(module, params \\ %{}) do
    {:ok, socket} = module.mount(params, %{}, Mob.Socket.new(module))
    drain(module, socket)
  end

  # Delivers what the screen asked for (ticks, engine messages) but no timers far off.
  def drain(module, socket, quiet_ms \\ 60) do
    receive do
      {:tick, _} = msg -> drain(module, info(module, socket, msg), quiet_ms)
      {:engine, _, _} = msg -> drain(module, info(module, socket, msg), quiet_ms)
      {:output, _, _} = msg -> drain(module, info(module, socket, msg), quiet_ms)
    after
      quiet_ms -> socket
    end
  end

  def info(module, socket, msg) do
    {:noreply, socket} = module.handle_info(msg, socket)
    socket
  end

  def frame(t, pitch, note, extra \\ %{}) do
    Map.merge(
      %{
        t: t,
        pitch: pitch,
        note: note,
        cents: if(pitch && note, do: (pitch - note) * 100),
        hz: if(pitch, do: Music.midi_to_hz(pitch)),
        db: if(pitch, do: -28.0, else: -68.0),
        velocity: if(note, do: 92),
        voiced: pitch != nil,
        mood: if(pitch, do: :singing, else: :listening),
        sent: nil
      },
      extra
    )
  end

  def canvases(module, socket) do
    tree = module.render(socket.assigns) |> Mob.Composite.expand(self())

    for node <- Mob.ScreenCase.flatten(tree), node.type == :canvas do
      {"#{node.props.width} × #{node.props.height}", node.props.width, node.props.height,
       node.props.draw}
    end
  end

  # The gallery's trace: the board's sung line from D4 to A4 over 4 s.
  def board_trace(t) do
    points = [
      {0, 61.8},
      {390, 62.1},
      {780, 61.9},
      {885, 63.7},
      {1380, 64.1},
      {1540, 64.9},
      {2090, 65.1},
      {2270, 66.8},
      {2820, 67.1},
      {2980, 68.6},
      {3270, 68.8},
      {3480, 68.88}
    ]

    {a, b} =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [{t0, _}, {t1, _}] -> t >= t0 and t <= t1 end)
      |> case do
        [a, b] -> {a, b}
        nil -> {List.last(points), List.last(points)}
      end

    {t0, p0} = a
    {t1, p1} = b
    if t1 == t0, do: p0, else: p0 + (p1 - p0) * (t - t0) / (t1 - t0)
  end

  def board_note(t) do
    cond do
      t < 830 -> 62
      t < 1450 -> 64
      t < 2150 -> 65
      t < 2900 -> 67
      true -> 69
    end
  end

  # Board 09-spectrum's voice: D4, glide to G4, glide to A4.
  def voice_bins(nil), do: :binary.copy(<<0>>, Audio.spectrum_bins())

  def voice_bins(f0) do
    for i <- 0..(Audio.spectrum_bins() - 1), into: <<>> do
      level =
        Enum.reduce(1..8, 0, fn k, acc ->
          d = (:math.log(Audio.bin_hz(i)) - :math.log(k * f0)) / 0.06
          max(acc, round(220 * :math.exp(-d * d) * :math.pow(k, -0.4)))
        end)

      <<level>>
    end
  end

  def board_f0(t) when t < 0.08, do: nil
  def board_f0(t) when t < 0.38, do: 294.0
  def board_f0(t) when t < 0.45, do: 294 + (t - 0.38) / 0.07 * (392 - 294)
  def board_f0(t) when t < 0.66, do: 392.0
  def board_f0(t) when t < 0.72, do: 392 + (t - 0.66) / 0.06 * (440 - 392)
  def board_f0(_t), do: 440.0
end

alias Humdinger.{Engine, FirstRunScreen, LiveScreen, SpectrumScreen}

out_dir = List.first(System.argv(), "/tmp/humdinger_screens")
File.mkdir_p!(out_dir)

{:ok, _} = Mob.ScreenCase.StateOwner.checkout()
Application.put_env(:humdinger, :device_calls, false)
Application.put_env(:humdinger, :audio, PreviewAudio)
Application.put_env(:humdinger, :output, PreviewOutput)
Mob.State.delete(:settings)
{:ok, _} = Humdinger.Settings.update(%{first_run_done: true, range: {40, 84}})
{:ok, _} = Engine.start_link(audio: PreviewAudio, output: PreviewOutput)

# ── Live: singing up to A4, 12 cents flat ──
live = Preview.mount(LiveScreen)

live =
  Enum.reduce(0..3480//33, live, fn t, socket ->
    p = Preview.board_trace(t)
    note = Preview.board_note(t)
    mood = if t > 3000, do: :flat, else: :singing

    socket =
      Preview.info(
        LiveScreen,
        socket,
        {:engine, :frame, Preview.frame(t + 6_000, p, note, %{mood: mood})}
      )

    # A phone ticks between frames.
    Preview.drain(LiveScreen, socket, 36)
  end)
  |> then(&Preview.drain(LiveScreen, &1))

live_sheet = CanvasSvg.render(Preview.canvases(LiveScreen, live), Path.join(out_dir, "live.png"))

settings =
  live
  |> then(&Preview.info(LiveScreen, &1, {:tap, :settings}))
  |> then(
    &Preview.info(LiveScreen, &1, {:engine, :frame, Preview.frame(9_600, nil, nil, %{db: -66.0})})
  )
  |> then(&Preview.drain(LiveScreen, &1))

settings_sheet =
  CanvasSvg.render(Preview.canvases(LiveScreen, settings), Path.join(out_dir, "settings.png"))

# ── Spectrum: the board's glide ──
spectrum = Preview.mount(SpectrumScreen)

spectrum =
  Enum.reduce(0..119, spectrum, fn c, socket ->
    t = c * 33
    f0 = Preview.board_f0(c / 119)

    socket =
      Preview.info(
        SpectrumScreen,
        socket,
        {:engine, :spectrum, %{t: t, bins: Preview.voice_bins(f0)}}
      )

    pitch = f0 && Humdinger.Music.hz_to_midi(f0)
    frame = Preview.frame(t, pitch, pitch && round(pitch), %{hz: f0})
    Preview.info(SpectrumScreen, socket, {:engine, :frame, frame})
  end)
  |> then(&Preview.drain(SpectrumScreen, &1))

spectrum_sheet =
  CanvasSvg.render(Preview.canvases(SpectrumScreen, spectrum), Path.join(out_dir, "spectrum.png"))

# ── First run: holding E2 for 1.4 s ──
first = Preview.mount(FirstRunScreen, %{step: :range})

first =
  Enum.reduce(0..1400//33, first, fn t, socket ->
    frame = Preview.frame(t, 40.05, 40, %{hz: Humdinger.Music.midi_to_hz(40.05)})
    Preview.info(FirstRunScreen, socket, {:engine, :frame, frame})
  end)
  |> then(&Preview.drain(FirstRunScreen, &1))

first_sheet =
  CanvasSvg.render(Preview.canvases(FirstRunScreen, first), Path.join(out_dir, "first_run.png"))

Enum.each([live_sheet, settings_sheet, spectrum_sheet, first_sheet], &IO.puts/1)
