defmodule Humdinger.SpectrumScreenTest do
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.{Audio, Engine, Music, SpectrumScreen}
  alias Humdinger.Test.FakeAudio
  alias Humdinger.Views.Spectrum

  setup do
    start_engine(%{first_run_done: true})
    :ok = Engine.listen()
    :ok
  end

  # A column with one loud bin at the note's fundamental.
  defp column(t, midi) do
    hz = Music.midi_to_hz(midi)
    peak = Enum.min_by(0..(Audio.spectrum_bins() - 1), &abs(Audio.bin_hz(&1) - hz))

    bins =
      for i <- 0..(Audio.spectrum_bins() - 1), into: <<>>, do: <<if(i == peak, do: 230, else: 0)>>

    %{t: t, bins: bins}
  end

  test "turns the engine's spectrum on while it's open and off when it closes" do
    view = mount_screen(SpectrumScreen)
    assert FakeAudio.spectrum?(FakeAudio.current())
    SpectrumScreen.terminate(:normal, view.socket)
    refute FakeAudio.spectrum?(FakeAudio.current())
  end

  test "draws the columns and the heard pitch, and names the note" do
    view = mount_screen(SpectrumScreen) |> pump()
    empty_ops = assigns(view).ops
    ref = FakeAudio.current()

    for t <- 0..300//33, do: FakeAudio.spectrum(ref, column(t, 69))
    sing(readings(0, 330, 69))
    view = pump_frame(view)

    a = assigns(view)
    assert a.shown.note == 69
    assert "A4" in texts(view)
    assert "440 Hz · 0¢" in texts(view)
    assert [_, _, _, _, _, _, _, _, _, _] = a.columns
    assert a.ops != empty_ops
    # Some cell in the brightest shade, and the pitch line.
    assert Enum.any?(a.ops, &(&1[:op] == :rect and &1[:color] in Spectrum.ramp()))

    assert Enum.any?(
             a.ops,
             &(&1[:op] in [:path, :line, :circle] and
                 &1[:color] == Humdinger.Style.pitch_color(69))
           )

    assert_renderable(view)
  end

  test "keeps only the columns inside the window; a new listen starts over" do
    view = mount_screen(SpectrumScreen) |> pump()
    ref = FakeAudio.current()
    for t <- 0..6_000//100, do: FakeAudio.spectrum(ref, column(t, 60))
    view = pump(view)
    assert hd(assigns(view).columns).t >= 6_000 - 4_200

    FakeAudio.spectrum(ref, column(10, 60))
    view = pump(view)
    assert [%{t: 10}] = assigns(view).columns
  end

  test "Notes goes back to Live; every tap target carries the press-out handle" do
    view = mount_screen(SpectrumScreen)
    assert assert_every_tap_held(view) == 2
    assert render_info(view, {:tap, :notes}).socket.__mob__.nav_action == {:pop}
  end

  test "the readout" do
    assert SpectrumScreen.readout(%{hz: 440.0, cents: -12.4, mood: :flat}) == "440 Hz · −12¢"
    assert SpectrumScreen.readout(%{hz: 261.6, cents: 3.0, mood: :singing}) == "262 Hz · +3¢"
    assert SpectrumScreen.readout(%{hz: nil, cents: nil, mood: :paused}) == "paused"
    assert SpectrumScreen.readout(nil) == "listening…"
  end
end
