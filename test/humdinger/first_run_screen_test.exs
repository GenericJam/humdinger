defmodule Humdinger.FirstRunScreenTest do
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.{Engine, FirstRunScreen}
  alias Humdinger.Test.FakeOutput

  setup do
    start_engine(%{first_run_done: false})
    :ok
  end

  # Holds `midi` from `from` for `ms` as the Engine reports it: a frame
  # every 33 ms. (Live's tests cover the Engine → frame path.)
  defp hold(view, midi, from, ms) do
    hz = Humdinger.Music.midi_to_hz(midi)

    view =
      Enum.reduce(from..(from + ms)//33, view, fn t, view ->
        frame = %{
          t: t,
          pitch: midi * 1.0,
          note: midi,
          cents: 0.0,
          hz: hz,
          db: -30.0,
          velocity: 90,
          voiced: true,
          mood: :singing,
          sent: nil
        }

        render_info(view, {:engine, :frame, frame})
      end)

    # The tick that shows it.
    view |> await_tick() |> pump(20)
  end

  defp at_range do
    FirstRunScreen
    |> mount_screen(%{return_to: self()})
    |> render_info({:tap, :allow_mic})
    |> render_info({:tap, :next})
  end

  test "Mic asks for the microphone, then the engine listens and Headphones follows" do
    view = mount_screen(FirstRunScreen, %{return_to: self()})
    assert "Let Mimi hear you" in texts(view)
    assert "Skip" in texts(view)
    assert_every_tap_held(view)
    assert_renderable(view)

    view = render_info(view, {:tap, :allow_mic})
    assert assigns(view).step == :headphones
    assert Engine.status() == :listening
    assert "Headphones help" in texts(view)
    assert_every_tap_held(view)
  end

  test "a refused microphone offers Settings and another try" do
    view = mount_screen(FirstRunScreen)
    view = render_info(view, {:permission, :microphone, :denied})
    assert "Mimi can't hear you" in texts(view)
    assert :app_settings in tap_tags(view)
    assert :allow_mic in tap_tags(view)
    assert assigns(view).step == :mic
  end

  test "Range: hold the lowest, then the highest; the range and octave are saved" do
    view = at_range()
    assert "Sing your lowest comfortable note" in texts(view)
    assert "LOWEST" in texts(view)
    assert "next" in texts(view)

    view = hold(view, 40, 0, 900)
    assert Enum.any?(texts(view), &String.starts_with?(&1, "holding… 0."))
    assert "E2" in texts(view)

    view = hold(view, 40, 900, 1_350)
    assert assigns(view).finder.low == 40
    assert "Now your highest comfortable note" in texts(view)

    view = hold(view, 67, 2_400, 2_250)
    assert assigns(view).finder.phase == :done
    assert "E2 – G4" in texts(view)
    assert Engine.settings().range == {40, 67}
    assert Engine.settings().octave == 1
    assert :next in tap_tags(view)
    assert :range_again in tap_tags(view)
    assert_every_tap_held(view)

    view = render_info(view, {:tap, :range_again})
    assert assigns(view).finder.phase == :low
  end

  test "a highest that isn't higher is refused" do
    view = at_range()
    view = hold(view, 50, 0, 2_050)
    view = hold(view, 49, 3_000, 2_050)
    assert assigns(view).finder.refused
    assert assigns(view).finder.phase == :high
    assert Enum.any?(texts(view), &(&1 =~ "no higher than D3"))
  end

  test "Send to switches destinations; finishing marks first run done and goes back" do
    view = at_range() |> render_info({:tap, :next})
    assert assigns(view).step == :send_to
    view = pump(view)
    assert "FMutate A" in texts(view)
    assert {:destination, :usb, true} in tap_tags(view)

    view = render_info(view, {:tap, {:destination, :usb, true}}) |> pump()
    assert Enum.find(FakeOutput.destinations(), &(&1.id == :usb)).enabled
    assert {:destination, :usb, false} in tap_tags(view)
    assert_every_tap_held(view)

    view = render_info(view, {:tap, :finish})
    assert Engine.settings().first_run_done
    assert view.socket.__mob__.nav_action == {:pop}

    FirstRunScreen.terminate(:normal, view.socket)
    assert_received {:first_run, :done}
  end

  test "Skip finishes from any step" do
    view = mount_screen(FirstRunScreen, %{return_to: self()})
    view = render_info(view, {:tap, :skip})
    assert Engine.settings().first_run_done
    assert view.socket.__mob__.nav_action == {:pop}
  end

  test "from Settings it shows only the range step and leaves the rest alone" do
    :ok = Engine.listen()
    view = mount_screen(FirstRunScreen, %{step: :range, only: true})
    assert "Close" in texts(view)
    assert assigns(view).step == :range

    view = hold(view, 45, 0, 2_250)
    view = hold(view, 72, 2_400, 2_250)
    assert "Done" in texts(view)
    view = render_info(view, {:tap, :finish})
    assert view.socket.__mob__.nav_action == {:pop}
    assert Engine.settings().range == {45, 72}
    refute Engine.settings().first_run_done
  end
end
