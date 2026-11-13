defmodule Humdinger.EngineTest do
  # Mob.State (settings), the fake microphone and the phrase database are shared.
  use ExUnit.Case, async: false

  alias Humdinger.Audio.Fake
  alias Humdinger.{Engine, Music, Phrase, Phrases, Repo, Scale, Settings, Take, Tracker}
  alias Mob.ScreenCase.StateOwner

  defmodule Output do
    @moduledoc false
    # Forwards what the engine sends to the test process; tells the engine
    # where the notes go, as Humdinger.Output does on subscribe.
    def send_events(events), do: send(Humdinger.EngineTest, {:output, events})
    def configure(opts), do: send(Humdinger.EngineTest, {:configure, opts})

    def subscribe(pid) do
      send(pid, {:output, :destinations, destinations()})
      :ok
    end

    def destinations do
      [
        %{id: :fmutate, name: "FMutate", detail: "", enabled: true, available: false},
        %{id: :port, name: "Humdinger port", detail: "", enabled: true, available: true},
        %{id: :usb, name: "USB MIDI out", detail: "", enabled: false, available: true},
        %{id: :bt, name: "Bluetooth MIDI", detail: "", enabled: false, available: false}
      ]
    end
  end

  setup_all do
    Humdinger.Test.Repo.start()
  end

  setup do
    {:ok, ref} = StateOwner.checkout()
    on_exit(fn -> StateOwner.checkin(ref) end)
    Mob.State.delete(:settings)
    :ok = Settings.save(%{Settings.defaults() | scale: Scale.chromatic(), on_stop: :note_off})
    Repo.delete_all(Phrases.Row)
    Fake.reset()
    Process.register(self(), __MODULE__)
    start_supervised!({Engine, output: Output})
    :ok
  end

  # Readings as the phone sends them: every 5 ms, `t` ms since listen,
  # silence at the −90 dBFS floor.
  defp sing(from, ms, pitch, db \\ -30.0) do
    for t <- from..(from + ms - 1)//5 do
      case pitch do
        nil -> %{t: t, hz: nil, clarity: 0.0, db: -90.0}
        p -> %{t: t, hz: Music.midi_to_hz(p), clarity: 0.95, db: db}
      end
    end
  end

  # In twos, as the phone delivers them.
  defp deliver(ref, readings) do
    readings |> Enum.chunk_every(2) |> Enum.each(&Fake.sing(ref, &1))
    Engine.status()
  end

  defp listening do
    :ok = Engine.listen()
    Fake.current()
  end

  defp output_events(acc \\ []) do
    receive do
      {:output, events} -> output_events(acc ++ events)
    after
      0 -> acc
    end
  end

  defp note_events(events), do: Enum.filter(events, &(elem(&1, 0) in [:note_on, :note_off]))

  # Host timers can fire hundreds of ms late (macOS timer coalescing), so
  # tests wait generously for timer-driven results and never for a timer to
  # be on time.
  defp eventually(check, tries \\ 400) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(check, tries - 1)
    end
  end

  defp latest_frame(last \\ nil) do
    receive do
      {:engine, :frame, frame} -> latest_frame(frame)
    after
      0 -> last
    end
  end

  defp notice, do: Fake.background() && Fake.background().notice

  test "the default audio is the configured one" do
    ref = listening()
    assert Fake.listening?(ref)
  end

  test "listen turns the microphone on, subscribers get status changes" do
    :ok = Engine.subscribe(self())
    assert_receive {:engine, :status, :off}
    assert Engine.status() == :off

    ref = listening()
    assert Fake.listening?(ref)
    assert_receive {:engine, :status, :listening}
    assert Engine.listen() == :ok
    assert Fake.current() == ref

    :ok = Engine.pause()
    assert_receive {:engine, :status, :paused}
    refute Fake.listening?(ref)
    assert_receive {:engine, :frame, %{mood: :paused}}

    :ok = Engine.resume()
    assert_receive {:engine, :status, :listening}
    assert Fake.current() not in [nil, ref]

    :ok = Engine.stop()
    assert_receive {:engine, :status, :off}
    assert Fake.current() == nil
  end

  test "events reach the output in the order the tracker makes them" do
    ref = listening()
    readings = sing(0, 300, 69.0) ++ sing(300, 300, 72.0) ++ sing(600, 200, nil)
    deliver(ref, readings)

    {expected, _tracker} =
      Enum.flat_map_reduce(readings, Tracker.new(Engine.settings()), fn r, tr ->
        {tr, events} = Tracker.push(tr, r)
        {events, tr}
      end)

    assert output_events() == expected

    assert [{:note_on, 69, _}, {:note_on, 72, _}, {:note_off, 69}, {:note_off, 72}] =
             note_events(expected)
  end

  test "frames come at most 30 a second with the latest state and a mood" do
    :ok = Engine.subscribe(self())
    ref = listening()
    started = System.monotonic_time(:millisecond)

    for i <- 0..39 do
      Fake.sing(ref, sing(i * 10, 10, 69.0))
      Process.sleep(10)
    end

    elapsed = System.monotonic_time(:millisecond) - started

    frames =
      Stream.repeatedly(fn -> receive do: ({:engine, :frame, f} -> f), after: (0 -> nil) end)
      |> Enum.take_while(& &1)

    # One frame came with the status change; the rest from the timer.
    assert Enum.count(frames) <= div(elapsed, 33) + 2

    last =
      Enum.find(Enum.reverse(frames), &match?(%{note: 69, mood: :singing}, &1)) ||
        receive do
          {:engine, :frame, %{note: 69, mood: :singing} = frame} -> frame
        after
          2000 -> flunk("no frame showed the note")
        end

    assert %{voiced: true, sent: "A4 on · vel " <> _, recording: false, background: :running} =
             last

    assert Map.keys(last) |> Enum.sort() ==
             Enum.sort([
               :t,
               :pitch,
               :note,
               :cents,
               :hz,
               :db,
               :velocity,
               :voiced,
               :mood,
               :sent,
               :recording,
               :background
             ])
  end

  test "mood follows the voice" do
    :ok = Engine.subscribe(self())
    ref = listening()

    # Each segment ends in a mood the one before didn't show.
    for {readings, mood} <- [
          {sing(0, 100, nil), :idle},
          {sing(100, 300, 69.0), :singing},
          {sing(400, 300, 69.0, -15.0), :aria},
          {sing(700, 300, 69.25), :sharp},
          {sing(1000, 300, 68.75), :flat},
          {sing(1300, 300, nil), :listening}
        ] do
      latest_frame()
      deliver(ref, readings)
      assert_receive {:engine, :frame, %{mood: ^mood}}, 2000
    end
  end

  test "microphone errors become the status and :no_mic, and release the note" do
    :ok = Engine.subscribe(self())

    for reason <- [:device_lost, :input_error] do
      ref = listening()
      deliver(ref, sing(0, 300, 69.0))
      output_events()
      Fake.fail(ref, reason)
      assert Engine.status() == {:error, reason}
      assert output_events() == [{:note_off, 69}]
      assert_receive {:engine, :status, {:error, ^reason}}
      assert_receive {:engine, :frame, %{mood: :no_mic}}
      refute Fake.listening?(ref)
    end
  end

  test "a refused microphone is an error status; listen tries again" do
    :ok = Engine.subscribe(self())
    Fake.set_permission(false)
    assert Engine.listen() == {:error, :permission}
    assert Engine.status() == {:error, :permission}
    assert_receive {:engine, :frame, %{mood: :no_mic, background: :off}}
    assert Fake.background() == nil

    Fake.set_permission(true)
    assert Engine.listen() == :ok
    assert Engine.status() == :listening
  end

  test "readings from an earlier listen are ignored" do
    old = listening()
    :ok = Engine.pause()
    :ok = Engine.resume()
    deliver(old, sing(0, 300, 69.0))
    assert output_events() == []

    deliver(Fake.current(), sing(0, 300, 69.0))
    assert [{:note_on, 69, _} | _] = note_events(output_events())
  end

  test "pause ends the sounding note" do
    ref = listening()
    deliver(ref, sing(0, 300, 69.0))
    output_events()
    :ok = Engine.pause()
    assert output_events() == [{:note_off, 69}]
  end

  test "a hold ends on the timer with no more readings" do
    {:ok, _} = Engine.update_settings(on_stop: :hold)
    ref = listening()
    deliver(ref, sing(0, 300, 69.0) ++ sing(300, 50, nil))
    assert [{:note_on, 69, _}] = note_events(output_events())
    refute_receive {:output, _}, 120
    # Due ~200 ms after the last reading.
    assert_receive {:output, [{:note_off, 69}]}, 2000
  end

  test "a settings change that re-maps notes releases first; a channel change reaches the output after" do
    ref = listening()
    deliver(ref, sing(0, 300, 69.0))
    output_events()

    assert {:ok, %Settings{mode: :open}} = Engine.update_settings(mode: :open)
    assert output_events() == [{:note_off, 69}]
    assert Settings.load().mode == :open

    deliver(ref, sing(300, 300, 64.0))
    output_events()
    {:ok, _} = Engine.update_settings(%{channel: 5})
    assert_received {:output, [{:note_off, 64}]}
    assert_received {:configure, [channel: 5]}

    {:messages, messages} = Process.info(self(), :messages)
    assert messages == []

    {:ok, _} = Engine.update_settings(&%{&1 | response: :steady})
    refute_received {:configure, _}
    assert Engine.update_settings(octave: 9) == {:error, {:invalid, :octave}}
    assert Engine.settings().octave == 0
  end

  test "a recording returns the take of the notes sent" do
    ref = listening()
    refute Engine.recording?()
    :ok = Engine.record_start()
    assert Engine.recording?()

    deliver(ref, sing(0, 300, 62.0) ++ sing(300, 100, nil) ++ sing(400, 300, 65.0, -20.0))
    {:ok, %Take{} = take} = Engine.record_stop()
    refute Engine.recording?()

    assert [a, b] = take.notes
    assert a.midi == 62 and b.midi == 65
    assert_in_delta a.start_ms, 60, 25
    assert_in_delta a.dur_ms, 300 - 60 + 30, 30
    assert_in_delta b.start_ms, 460, 30
    # The second note still sounds: it ends where the take does.
    assert b.start_ms + b.dur_ms == take.duration_ms
    assert b.velocity > a.velocity
    refute a.unsure
    assert take.scale == Scale.chromatic()
    assert take.source == :hum
    assert %DateTime{} = take.recorded_at

    times = Enum.map(take.trace, &elem(&1, 0))
    assert times == Enum.sort(times)
    voiced = for {t, p} <- take.trace, p != nil, do: t
    voiced |> Enum.chunk_every(2, 1, :discard) |> Enum.each(fn [x, y] -> assert y - x >= 10 end)
    assert Enum.count(take.trace, fn {_, p} -> p == nil end) == 1

    assert Enum.all?(take.trace, fn {_, p} ->
             p == nil or abs(p - 62) < 0.5 or abs(p - 65) < 0.5
           end)
  end

  test "a take in Open mode has no scale; an empty take is an error" do
    {:ok, _} = Engine.update_settings(mode: :open)
    ref = listening()
    assert Engine.record_stop() == {:error, :not_recording}

    :ok = Engine.record_start()
    deliver(ref, sing(0, 200, nil))
    assert Engine.record_stop() == {:error, :empty}

    :ok = Engine.record_start()
    deliver(ref, sing(0, 300, 69.0))
    assert {:ok, %Take{scale: nil, notes: [%{midi: 69}]}} = Engine.record_stop()
  end

  test "a note sounding when the recording starts begins the take" do
    ref = listening()
    deliver(ref, sing(0, 300, 69.0))
    :ok = Engine.record_start()
    deliver(ref, sing(300, 100, 69.0) ++ sing(400, 100, nil))
    {:ok, take} = Engine.record_stop()
    assert [%{midi: 69, start_ms: 0, dur_ms: dur}] = take.notes
    assert_in_delta dur, 130, 30
  end

  test "spectrum goes only to subscribers who want it, and only while someone does" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Engine.subscribe(self())
    ref = listening()
    refute Fake.spectrum?(ref)

    :ok = Engine.spectrum(other, true)
    assert Fake.spectrum?(ref)
    Fake.spectrum(ref, %{t: 0, bins: <<0::1024>>})
    Engine.status()
    refute_received {:engine, :spectrum, _}

    :ok = Engine.spectrum(self(), true)
    Fake.spectrum(ref, %{t: 10, bins: <<1::1024>>})
    Engine.status()
    assert_received {:engine, :spectrum, %{bins: <<1::1024>>}}

    :ok = Engine.spectrum(self(), false)
    assert Fake.spectrum?(ref)
    Process.exit(other, :kill)
    # The engine learns of the death from its own monitor, asynchronously.
    assert eventually(fn -> not Fake.spectrum?(ref) end)

    # A new listen asks for the spectrum when someone wants it.
    :ok = Engine.spectrum(self(), true)
    :ok = Engine.pause()
    :ok = Engine.resume()
    assert Fake.spectrum?(Fake.current())
  end

  test "spectrum columns are on the frames' clock, across pause and resume" do
    :ok = Engine.spectrum(self(), true)
    first = listening()
    deliver(first, sing(0, 300, 69.0))
    :ok = Engine.pause()
    Process.sleep(20)
    :ok = Engine.resume()
    ref = Fake.current()
    latest_frame()

    # The same audio time in a reading and a spectrum column.
    deliver(ref, [%{t: 50, hz: nil, clarity: 0.0, db: -90.0}])
    Fake.spectrum(ref, %{t: 50, bins: <<0::1024>>})
    Engine.status()
    assert_receive {:engine, :spectrum, %{t: t}}
    assert_receive {:engine, :frame, %{t: ^t}}, 2000
    # Engine time kept running from before the pause.
    assert t > 300
  end

  describe "the background notification" do
    test "listening starts it; it shows the note, where it goes and the channel" do
      ref = listening()

      assert %{owner: owner, notice: %{title: "Humdinger · listening", state: :listening}} =
               Fake.background()

      assert owner == Process.whereis(Engine)
      assert eventually(fn -> notice().text == "listening… → Humdinger port · ch 1" end)

      deliver(ref, sing(0, 300, 69.25))
      assert eventually(fn -> notice().text == "A4 +25¢ → Humdinger port · ch 1" end)
    end

    test "pause keeps it with Resume; Resume in the shade listens again" do
      :ok = Engine.subscribe(self())
      old = listening()
      :ok = Engine.pause()
      assert %{title: "Humdinger · paused", state: :paused} = notice()

      :ok = Fake.tap_background(:resume)
      assert_receive {:engine, :status, :listening}
      assert Fake.current() not in [nil, old]
      assert %{title: "Humdinger · listening", state: :listening} = notice()

      :ok = Fake.tap_background(:pause)
      assert_receive {:engine, :status, :paused}
      refute Fake.listening?(Fake.current() || old)
    end

    test "Record and Stop rec in the shade save the take as a phrase" do
      :ok = Engine.subscribe(self())
      ref = listening()
      :ok = Fake.tap_background(:record)
      assert eventually(fn -> notice().state == :recording end)
      assert notice().title == "Humdinger · recording"
      assert Engine.recording?()

      deliver(ref, sing(0, 300, 62.0) ++ sing(300, 300, 65.0) ++ sing(600, 100, nil))
      :ok = Fake.tap_background(:record_stop)
      assert_receive {:engine, :phrase_saved, %Phrase{id: id, name: name} = phrase}, 2000
      assert name == Phrase.default_name()
      assert Enum.map(phrase.notes, & &1.midi) == [62, 65]
      assert %Phrase{id: ^id} = Phrases.get(id)
      refute Engine.recording?()
      assert notice().state == :listening

      # Nothing sung: nothing saved.
      :ok = Fake.tap_background(:record)
      :ok = Fake.tap_background(:record_stop)
      Engine.status()
      refute_received {:engine, :phrase_saved, _}
      assert [_one] = Phrases.list()
    end

    test "Stop in the shade turns everything off" do
      ref = listening()
      :ok = Engine.subscribe(self())
      assert_receive {:engine, :status, :listening}
      deliver(ref, sing(0, 300, 69.0))
      output_events()

      :ok = Fake.tap_background(:stop)
      assert_receive {:engine, :status, :off}
      assert output_events() == [{:note_off, 69}]
      refute Fake.listening?(ref)
      assert Fake.background() == nil
    end

    test "Engine.stop takes it away; listening again brings it back" do
      listening()
      :ok = Engine.stop()
      assert Fake.background() == nil
      listening()
      assert Fake.background() != nil
    end

    test "a microphone error keeps it, saying so, with Resume" do
      :ok = Engine.subscribe(self())
      ref = listening()
      Fake.fail(ref, :device_lost)
      assert_receive {:engine, :status, {:error, :device_lost}}
      # The notice follows the status message, in the same step.
      Engine.status()

      assert %{
               title: "Humdinger · no microphone",
               text: "microphone disconnected · Resume to try again",
               state: :paused
             } = notice()

      :ok = Fake.tap_background(:resume)
      assert_receive {:engine, :status, :listening}
    end

    @tag :capture_log
    test "when Android refuses it the engine keeps listening and says why" do
      :ok = Engine.subscribe(self())
      listening()
      latest_frame()
      send(Process.whereis(Engine), {:background, :failed})
      assert_receive {:engine, :frame, %{background: {:error, :failed}}}
      assert Engine.status() == :listening
      assert Fake.background() == nil

      # The next listen from the foreground tries again.
      :ok = Engine.pause()
      :ok = Engine.resume()
      assert Fake.background() != nil
      latest_frame()
      Fake.sing(Fake.current(), sing(0, 10, nil))
      assert_receive {:engine, :frame, %{background: :running}}, 2000

      # A late report about a service already stopped changes nothing.
      :ok = Engine.stop()
      send(Process.whereis(Engine), {:background, :failed})
      :ok = Engine.listen()
      assert Fake.background() != nil
    end
  end
end
