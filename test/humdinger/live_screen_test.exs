defmodule Humdinger.LiveScreenTest do
  # The Engine, the fake microphone and Mob.State are shared.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.Audio.Fake
  alias Humdinger.{Engine, FirstRunScreen, LiveScreen, Scale, SpectrumScreen}
  alias Humdinger.Test.FakeOutput

  defp mount_live(settings \\ %{first_run_done: true}) do
    start_engine(settings)
    LiveScreen |> mount_screen() |> pump()
  end

  defp sing_note(view, midi, from \\ 0, ms \\ 400) do
    sing(readings(from, ms, midi))
    pump_frame(view)
  end

  describe "starting" do
    test "a first launch opens First run before asking for the microphone" do
      start_engine(%{first_run_done: false})
      view = mount_screen(LiveScreen)
      assert assigns(view).mic == :unknown
      assert Engine.status() == :off

      view = pump(view)
      assert navigated_to(view) == FirstRunScreen
      assert {:push, FirstRunScreen, %{return_to: pid}} = view.socket.__mob__.nav_action
      assert pid == self()

      view = render_info(view, {:first_run, :done})
      assert assigns(view).mic == :granted
      assert Engine.status() == :listening
    end

    test "after first run it listens at once and shows where the MIDI goes" do
      view = mount_live()
      assert Engine.status() == :listening
      assert Fake.current()
      assert_renderable(view)

      assert "FMutate A" in texts(view)
      assert "+ MIDI port · ch 1" in texts(view)
      assert "D Dorian ▾" in texts(view)
      assert "octave 0" in texts(view)
      assert "transp 0" in texts(view)
      assert "Pause" in texts(view)
      assert "hum something" in texts(view) or "listening…" in texts(view)
    end

    test "every tap target carries the press-out handle (MOB-509)" do
      view = mount_live()
      assert assert_every_tap_held(view) >= 10

      tags = tap_tags(view)

      for tag <- [:output, :settings, :spectrum, :scale_picker, :pause, :record, :phrases] do
        assert tag in tags
      end

      assert {:set, :mode, :open} in tags
      assert {:set, :octave, 1} in tags
      assert {:set, :octave, -1} in tags
      assert {:set, :transpose, 1} in tags
    end
  end

  describe "the pill" do
    test "names the first destination that's on and sums up the rest" do
      [fm, port, usb, bt] = FakeOutput.defaults()

      assert {_, "FMutate A", "+ MIDI port · ch 1"} =
               LiveScreen.destination_summary([fm, port, usb, bt], 1)

      assert {_, "Humdinger port", "ch 3"} =
               LiveScreen.destination_summary([%{fm | enabled: false}, port, usb, bt], 3)

      assert {_, "FMutate A", "+ 2 more · ch 1"} =
               LiveScreen.destination_summary([fm, port, %{usb | enabled: true}, bt], 1)

      off = Enum.map([fm, port, usb, bt], &%{&1 | enabled: false})
      assert {_, "Not sending", _} = LiveScreen.destination_summary(off, 1)
    end

    test "is lime when the first destination is reachable, amber when it isn't" do
      [fm | rest] = FakeOutput.defaults()
      {lime, _, _} = LiveScreen.destination_summary([fm | rest], 1)
      {amber, _, _} = LiveScreen.destination_summary([%{fm | available: false} | rest], 1)
      assert lime == Humdinger.Style.fm()
      assert amber == Humdinger.Style.warn()
    end

    test "follows Output's changes" do
      view = mount_live()
      FakeOutput.set_enabled(:fmutate, false)
      view = pump(view)
      assert "Humdinger port" in texts(view)
    end
  end

  describe "singing" do
    test "shows the note, its velocity and tuning, and lights the key" do
      view = mount_live()
      view = sing_note(view, 69)

      a = assigns(view)
      assert a.shown.note == 69
      assert "A4" in texts(view)
      assert Enum.any?(texts(view), &String.starts_with?(&1, "vel "))
      assert "in tune" in Enum.map(texts(view), &(&1 |> String.split(" · ") |> List.last()))

      assert a.op_keys.strip |> elem(1) == 69
      assert {:mimi_mood, m} = {:mimi_mood, elem(a.op_keys.mimi, 0)}
      assert m in [:singing, :aria]
      # The sent note is drawn in the roll as a block that's still sounding.
      assert [%{midi: 69, end_ms: nil}] = Humdinger.LiveFeed.notes(a.feed)
    end

    test "a flat voice reads as flat" do
      view = mount_live()
      view = sing_note(view, 68.8)
      assert Enum.any?(texts(view), &(&1 =~ "−20¢"))
      assert elem(assigns(view).op_keys.mimi, 0) == :flat
    end

    test "the strip follows the voice out of its window" do
      view = mount_live()
      {low, high} = assigns(view).window
      view = sing_note(view, high + 5)
      {low2, high2} = assigns(view).window
      assert low2 > low
      assert high + 5 > low2 and high + 5 < high2
    end

    test "after the voice stops the note dims and the canvases stop changing" do
      view = mount_live(%{first_run_done: true, on_stop: :note_off})
      view = sing_note(view, 69)
      # Frames come every 33 ms on a phone: deliver the stop, then the silence.
      sing(readings(400, 300, nil))
      view = pump_frame(view)
      sing(readings(700, 6_000, nil))
      view = pump_frame(view)
      assert assigns(view).shown.note == nil
      assert {:empty, _, _} = assigns(view).op_keys.roll
      # The last note stays, faint.
      assert "A4" in texts(view)

      ops = assigns(view).ops
      sing(readings(6_700, 300, nil))
      view = pump_frame(view)
      assert assigns(view).ops.roll == ops.roll
      assert assigns(view).ops.strip == ops.strip
    end
  end

  describe "controls" do
    test "Scale | Open + bend sets the mode" do
      view = mount_live()
      view = render_info(view, {:tap, {:set, :mode, :open}})
      assert Engine.settings().mode == :open
      assert assigns(view).settings.mode == :open
      _view = render_info(view, {:tap, {:set, :mode, :scale}})
      assert Engine.settings().mode == :scale
    end

    test "octave and transpose step within their ranges" do
      view = mount_live()
      view = render_info(view, {:tap, {:set, :octave, 1}})
      assert "octave +1" in texts(view)
      assert {:set, :octave, 2} in tap_tags(view)

      view = render_info(view, {:tap, {:set, :transpose, -1}})
      assert Engine.settings().transpose == -1
      assert "transp −1" in texts(view)

      view = render_info(view, {:tap, {:set, :octave, 3}})
      # At the top, + stays at 3.
      assert {:set, :octave, 3} in tap_tags(view)
      refute {:set, :octave, 4} in tap_tags(view)
    end

    test "the scale picker offers every root and mode" do
      view = mount_live()
      view = render_info(view, {:tap, :scale_picker})
      sheet = find(view, :sheet, id: "scale")
      assert sheet
      assert assert_every_tap_held(view) > 0

      scales = for {:set, :scale, s} <- tap_tags(view), do: s
      assert length(scales) == 12 + length(Scale.modes())

      view = render_info(view, {:tap, {:set, :scale, Scale.new("F#", :lydian)}})
      assert Engine.settings().scale == Scale.new("F#", :lydian)
      assert "#{Scale.name(Scale.new("F#", :lydian))} ▾" in texts(view)

      view = render_info(view, {:tap, :scale_done})
      refute find(view, :sheet, id: "scale")
    end

    test "Pause stops sending and puts Mimi to sleep; Resume listens again" do
      view = mount_live()
      view = render_info(view, {:tap, :pause}) |> pump()
      assert Engine.status() == :paused
      assert "Resume" in texts(view)
      assert "paused · not sending" in texts(view)
      assert elem(assigns(view).op_keys.mimi, 0) == :paused

      view = render_info(view, {:tap, :pause}) |> pump()
      assert Engine.status() == :listening
      assert "Pause" in texts(view)
    end

    test "Spectrum, Phrases and Output navigate (or say they aren't in this build)" do
      view = mount_live()
      assert navigated_to(render_info(view, {:tap, :spectrum})) == SpectrumScreen

      for {tag, screen} <- [phrases: Humdinger.PhrasesScreen, output: Humdinger.OutputScreen] do
        after_tap = render_info(view, {:tap, tag})

        if Code.ensure_loaded?(screen),
          do: assert(navigated_to(after_tap) == screen),
          else: assert(assigns(after_tap).toast =~ "isn't in this build")
      end
    end
  end

  describe "recording" do
    test "record, sing, stop opens the phrase review with the new phrase" do
      view = mount_live()
      view = render_info(view, {:tap, :record})
      assert Engine.recording?()
      assert assigns(view).recording
      assert Enum.any?(texts(view), &String.starts_with?(&1, "recording · 0:0"))

      view = sing_note(view, 64, 0, 300)
      view = sing_note(view, 67, 300, 300)
      view = render_info(view, {:tap, :record})
      refute Engine.recording?()
      refute assigns(view).recording

      if Code.ensure_loaded?(Humdinger.PhraseScreen) do
        assert {:push, Humdinger.PhraseScreen, %{phrase: phrase, return_to: pid}} =
                 view.socket.__mob__.nav_action

        assert pid == self()
        assert Enum.map(phrase.notes, & &1.midi) == [64, 67]
        assert phrase.id == nil
      else
        assert assigns(view).toast =~ "isn't in this build"
      end
    end

    test "an empty take says so and stays on Live" do
      view = mount_live()
      view = render_info(view, {:tap, :record})
      view = render_info(view, {:tap, :record})
      assert assigns(view).toast =~ "No notes"
      assert navigated_to(view) == nil
    end

    test "Hum again from the review starts a new recording" do
      view = mount_live()
      view = render_info(view, :hum_again)
      assert Engine.recording?()
      assert assigns(view).recording
    end

    test "a phrase saved from the notification shows a note and ends the recording" do
      view = mount_live()
      view = render_info(view, {:tap, :record})
      view = render_info(view, {:engine, :phrase_saved, %{name: "New phrase"}})
      refute assigns(view).recording
      assert "Saved “New phrase”" in texts(view)
    end

    test "follows a recording started or stopped from the notification" do
      view = mount_live()
      frame = assigns(view).frame
      # Past the half second after a tap here, the frames are trusted.
      view = %{view | socket: Mob.Socket.assign(view.socket, :rec_changed_at, long_ago())}
      view = render_info(view, {:engine, :frame, Map.put(frame, :recording, true)})
      assert assigns(view).recording

      view = %{view | socket: Mob.Socket.assign(view.socket, :rec_changed_at, long_ago())}
      view = render_info(view, {:engine, :frame, Map.put(frame, :recording, false)})
      refute assigns(view).recording
    end

    test "ignores a stale frame just after the record tap" do
      view = mount_live()
      frame = assigns(view).frame
      view = render_info(view, {:tap, :record})
      view = render_info(view, {:engine, :frame, Map.put(frame, :recording, false)})
      assert assigns(view).recording
    end
  end

  defp long_ago, do: System.monotonic_time(:millisecond) - 1_000

  describe "the microphone" do
    test "refused: Mimi has no mic, says why and offers to try again" do
      start_engine(%{first_run_done: true})
      view = mount_screen(LiveScreen)
      view = render_info(view, {:permission, :microphone, :denied})
      assert "Mimi can't hear you" in texts(view)
      assert :retry_mic in tap_tags(view)
      assert :app_settings in tap_tags(view)
      assert elem(assigns(view).op_keys.mimi, 0) == :no_mic
      assert_every_tap_held(view)

      view = render_info(view, {:tap, :retry_mic})
      assert assigns(view).mic == :granted
      assert Engine.status() == :listening
    end

    test "a notifications refusal changes nothing" do
      view = mount_live()
      view = render_info(view, {:permission, :notifications, :denied})
      assert Engine.status() == :listening
      refute "Mimi can't hear you" in texts(view)
    end

    test "an engine error shows what happened" do
      view = mount_live()
      Fake.fail(Fake.current(), :device_lost)
      view = pump(view)
      assert "The microphone stopped" in texts(view)
      _view = render_info(view, {:tap, :retry_mic})
      assert Engine.status() == :listening
    end

    test "a build without the audio engine says so" do
      start_engine(%{first_run_done: true})
      Application.put_env(:humdinger, :audio, Humdinger.NoSuchAudio)
      view = mount_screen(LiveScreen)
      assert "No audio engine" in texts(view)
      assert Engine.status() == :off
    end
  end

  describe "the Settings sheet" do
    test "opens from the header, changes settings and closes with Done" do
      view = mount_live()
      view = render_info(view, {:tap, :settings})
      assert find(view, :sheet, id: "settings")
      assert assert_every_tap_held(view) > 15
      assert "~30 ms" in texts(view)
      assert "~60 ms" in texts(view)
      assert "~120 ms" in texts(view)
      assert "Hold 250 ms" in texts(view)
      assert "find it ›" in texts(view)

      changes = [
        response: :fast,
        pitch_change: :new_note,
        on_stop: :note_off,
        bend_range: 12,
        cc1_from_vibrato: true,
        velocity_from_loudness: false
      ]

      view =
        Enum.reduce(changes, view, fn {field, value}, view ->
          assert {:set, field, value} in tap_tags(view)
          view = render_info(view, {:tap, {:set, field, value}})
          assert Map.fetch!(Engine.settings(), field) == value
          view
        end)

      # A switch now offers the other way.
      assert {:set, :cc1_from_vibrato, false} in tap_tags(view)
      assert {:set, :velocity_from_loudness, true} in tap_tags(view)

      view = render_info(view, {:tap, :settings_done})
      refute find(view, :sheet, id: "settings")
    end

    test "shows the singer's range and finds it again in First run" do
      view = mount_live(%{first_run_done: true, range: {40, 67}})
      view = render_info(view, {:tap, :settings})
      assert "E2 – G4 · find again ›" in texts(view)

      view = render_info(view, {:tap, :find_range})
      assert {:push, FirstRunScreen, %{step: :range, only: true}} = view.socket.__mob__.nav_action
      refute assigns(view).sheet
    end

    test "dragging the line sets the sensitivity when the drag ends" do
      view = mount_live()
      view = render_info(view, {:tap, :settings})
      {w, _h} = Humdinger.SettingsSheet.bar_size()

      view = render_info(view, {:drag, :sensitivity, %{x: w * 0.5, phase: :began}})
      view = render_info(view, {:drag, :sensitivity, %{x: w * 0.6, phase: :dragging}})
      # Not saved mid-drag, but drawn there.
      assert Engine.settings().sensitivity_db == -55.0
      assert elem(assigns(view).op_keys.bar, 0) == -40.0

      _view = render_info(view, {:drag, :sensitivity, %{x: w * 0.6, phase: :ended}})
      assert Engine.settings().sensitivity_db == -40.0
    end

    test "a drag whose end is lost is saved after a quiet second (MOB-511)" do
      view = mount_live()
      view = render_info(view, {:tap, :settings})
      view = render_info(view, {:drag, :sensitivity, %{x: 0, phase: :began}})
      token = assigns(view).drag_token
      _view = render_info(view, {:drag_quiet, token})
      assert Engine.settings().sensitivity_db == -70.0
    end

    test "the bar shows the room while quiet and the voice while singing" do
      view = mount_live()
      view = render_info(view, {:tap, :settings})
      sing(readings(0, 200, nil))
      view = pump_frame(view)
      assert assigns(view).room_db < -70
      view = sing_note(view, 69, 200, 300)
      assert assigns(view).voice_db > -40
      {_gate, room, voice, note} = assigns(view).op_keys.bar
      assert room && voice && note == 69
    end
  end

  describe "when the engine restarts" do
    # The test supervisor restarts the engine, as Humdinger.Realtime does.
    defp restart_engine(view) do
      old = Process.whereis(Engine)
      mon = assigns(view).engine_mon
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^mon, :process, ^old, _} = down
      view |> render_info(down) |> rewatch()
    end

    defp rewatch(view) do
      if assigns(view).engine_mon do
        pump(view)
      else
        receive do
          :engine_rewatch -> view |> render_info(:engine_rewatch) |> rewatch()
        after
          2_000 -> flunk("Live didn't watch the engine again")
        end
      end
    end

    test "Live watches the new engine and sets it listening again" do
      view = mount_live()
      Fake.reset()
      view = restart_engine(view)

      assert Engine.status() == :listening
      assert assigns(view).status == :listening
      assert Fake.current()

      # Frames come again.
      view = sing_note(view, 69)
      assert assigns(view).shown.note == 69
    end

    test "a paused Live leaves the new engine paused" do
      view = mount_live()
      view = render_info(view, {:tap, :pause}) |> pump()
      view = restart_engine(view)
      assert Engine.status() == :paused
      assert "Resume" in texts(view)

      render_info(view, {:tap, :pause}) |> pump()
      assert Engine.status() == :listening
    end
  end

  test "the view's geometry helpers" do
    assert LiveScreen.window_for(69, nil) == {62, 76}
    # A black-key centre starts the window on the white key below.
    assert {low, _} = LiveScreen.window_for(68, nil)
    assert Humdinger.Music.white_key?(low)
    assert LiveScreen.window_for(10, nil) == {21, 35}
    assert LiveScreen.follow_window({62, 76}, 70) == {62, 76}
    assert LiveScreen.follow_window({62, 76}, 80) == LiveScreen.window_for(80, nil)
    assert LiveScreen.ease_center(60.0, 64) == 61.0
    assert LiveScreen.ease_center(63.995, 64) == 64.0
  end

  test "the roll follows the voice with hysteresis and never leaves it off the rows" do
    alias Humdinger.LiveFeed

    feed = fn pitch, note ->
      LiveFeed.push(LiveFeed.new(), %{t: 1_000, pitch: pitch, note: note})
    end

    # Within the inner rows: stay.
    assert LiveScreen.roll_target(60.0, feed.(62.0, 62)) == nil
    # Past them: head for the voice; the sounding note when the pitch is gone.
    assert LiveScreen.roll_target(58.5, feed.(64.0, 64)) == 64.0
    assert LiveScreen.roll_target(58.5, feed.(nil, 64)) == 64.0
    assert LiveScreen.roll_target(58.5, feed.(nil, nil)) == nil

    # A small step eases, a leap off the rows jumps.
    assert LiveScreen.follow_center(58.0, 63.0) == 59.25
    assert LiveScreen.follow_center(58.0, 76.0) == 76.0
    assert LiveScreen.follow_center(58.0, nil) == 58.0
  end
end
