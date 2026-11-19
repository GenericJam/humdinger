defmodule Humdinger.EngineTest do
  # Mob.State (settings), the fake microphone and the phrase database are shared.
  use ExUnit.Case, async: false

  alias Humdinger.Audio.Fake
  alias Humdinger.{Engine, Music, Phrase, Phrases, Repo, Scale, Settings, Take, Tracker}
  alias Humdinger.Test.{FakeOutput, Listener}
  alias Mob.ScreenCase.StateOwner

  # Where the notes go: FMutate is on but not reachable, so the notice
  # names the port.
  @destinations [
    %{id: :fmutate, name: "FMutate", detail: "", enabled: true, available: false},
    %{id: :port, name: "Humdinger port", detail: "", enabled: true, available: true},
    %{id: :usb, name: "USB MIDI out", detail: "", enabled: false, available: true},
    %{id: :bt, name: "Bluetooth MIDI", detail: "", enabled: false, available: false}
  ]

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
    FakeOutput.reset(@destinations)
    Listener.listen()
    start_supervised!({Engine, output: FakeOutput})
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

  describe "one source at a time (real Output)" do
    # Nothing here waits on wall-clock time: players run on clocks the test
    # moves, the tracker never ends a note on its own (`stall_ms`), and what
    # reached the port is read after syncing with the Engine and Output.

    # The port double reports the bytes Output sends it.
    defmodule PortProbe do
      @moduledoc false
      alias Humdinger.Test.Listener
      def available?, do: true
      def connections, do: 1
      def send(bytes), do: Listener.tell({:port, bytes})
    end

    setup do
      :ok = stop_supervised(Engine)
      {:ok, clock} = Agent.start_link(fn -> 0 end)

      start_supervised!(
        {Humdinger.Output,
         name: Humdinger.Output,
         port: PortProbe,
         fmutate: Humdinger.NoFMutate,
         clock: fn -> Agent.get(clock, & &1) end}
      )

      start_supervised!({Engine, output: Humdinger.Output, stall_ms: 600_000})
      port_now()
      %{clock: clock}
    end

    # Everything the Engine and Output have sent so far, in order.
    defp port_now do
      sync_engine()
      drain_port([])
    end

    defp sync_engine do
      if engine = Process.whereis(Engine) do
        :sys.replace_state(engine, fn state ->
          state.output.sync()
          state
        end)
      else
        Humdinger.Output.sync()
      end

      :ok
    end

    defp sync_player(player) do
      :sys.replace_state(player, fn state ->
        case state.output do
          {module, server} -> module.sync(server)
          module -> module.sync()
        end

        state
      end)

      :ok
    end

    defp drain_port(acc) do
      receive do
        {:port, bytes} -> drain_port([bytes | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp player(clock_fun),
      do: Humdinger.Player.start_link(output: Humdinger.Output, clock: clock_fun)

    defp play(player, notes, tag) do
      :ok = Humdinger.Player.play(player, notes, tag)
      sync_player(player)
    end

    defp test_note do
      :ok = Humdinger.Output.test_note()
      player = GenServer.call(Humdinger.Output, :test_player)
      sync_player(player)
      player
    end

    defp new_clock do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      clock
    end

    defp clock_fun(clock), do: fn -> Agent.get(clock, & &1) end

    # Moves `clock` to `t` and runs `player`'s pending tick now.
    defp at(player, clock, t) do
      Agent.update(clock, fn _ -> t end)

      case :sys.get_state(player).token do
        nil -> :ok
        token -> send(player, {:tick, token})
      end

      sync_player(player)
    end

    defp player_note(midi, dur), do: [%{start_ms: 0, dur_ms: dur, midi: midi, velocity: 90}]
    defp note_on?(bytes, note), do: match?(<<0x90, ^note, _>>, bytes)

    test "a player takes over on the same pitch, and the singer is back once it has finished" do
      ref = listening()
      deliver(ref, sing(0, 300, 69.0))
      assert Enum.any?(port_now(), &note_on?(&1, 69))

      clock = new_clock()
      {:ok, player} = player(clock_fun(clock))
      :ok = play(player, player_note(69, 800), :riff)

      # The singer's note off, its controllers back, then the played note.
      assert port_now() ==
               [<<0x80, 69, 64>> | Humdinger.Midi.reset_controllers(1)] ++ [<<0x90, 69, 90>>]

      # Still singing, but nothing of it reaches the output; the status stays.
      deliver(ref, sing(300, 100, 72.0))
      assert port_now() == []
      assert Engine.status() == :listening

      # Finished only once the note-off is out and the singer has the output back.
      at(player, clock, 800)
      assert_received {:player, :finished, :riff}
      assert port_now() == [<<0x80, 69, 64>>]
      deliver(ref, sing(400, 300, 72.0))
      assert Enum.any?(port_now(), &note_on?(&1, 72))
    end

    test "an engine restarted during playback stays out until the player is done" do
      clock = new_clock()
      {:ok, player} = player(clock_fun(clock))
      :ok = play(player, player_note(60, 600), :long)
      port_now()

      engine = Process.whereis(Engine)
      Process.exit(engine, :kill)
      assert eventually(fn -> Process.whereis(Engine) not in [nil, engine] end)

      ref = listening()
      deliver(ref, sing(0, 300, 72.0))
      refute Enum.any?(port_now(), &note_on?(&1, 72))

      at(player, clock, 600)
      assert_received {:player, :finished, :long}
      deliver(ref, sing(300, 300, 74.0))
      assert Enum.any?(port_now(), &note_on?(&1, 74))
    end

    test "a player killed outright has its notes released and gives the singer back" do
      {:ok, player} = player(clock_fun(new_clock()))
      Process.unlink(player)
      :ok = play(player, player_note(60, 60_000), :long)
      port_now()

      Humdinger.Output.follow_session(self())
      assert_receive {:output, :session, :active}

      # No terminate/2: Output's monitor on the session releases the note.
      Process.exit(player, :kill)
      assert_receive {:output, :session, :idle}
      assert port_now() == [<<0x80, 60, 64>>]

      ref = listening()
      deliver(ref, sing(0, 300, 72.0))
      assert Enum.any?(port_now(), &note_on?(&1, 72))
    end

    test "two players don't play at once: the newer one takes over" do
      {:ok, first} = player(clock_fun(new_clock()))
      second_clock = new_clock()
      {:ok, second} = player(clock_fun(second_clock))
      :ok = play(first, player_note(60, 60_000), :first)
      port_now()

      :ok = play(second, player_note(64, 100), :second)
      # The first hears it was taken over (and stops) before Output answers its next call.
      assert_receive {:player, :finished, :first}
      assert Humdinger.Player.playing(first) == nil
      assert port_now() == [<<0x80, 60, 64>>, <<0x90, 64, 90>>]

      at(second, second_clock, 100)
      assert_received {:player, :finished, :second}
      assert port_now() == [<<0x80, 64, 64>>]
    end

    test "test taps while singing restart the note and keep the singer out until the last ends",
         ctx do
      ref = listening()
      deliver(ref, sing(0, 300, 69.0))
      port_now()

      test_player = test_note()
      at(test_player, ctx.clock, 150)
      ^test_player = test_note()

      # Struck again at 150: the first note ends there, not at its 300 ms.
      assert port_now() ==
               [<<0x80, 69, 64>> | Humdinger.Midi.reset_controllers(1)] ++
                 [<<0x90, 69, 92>>, <<0x80, 69, 64>>, <<0x90, 69, 92>>]

      # The second lasts its own 300 ms; the singer waits for it.
      deliver(ref, sing(300, 100, 72.0))
      at(test_player, ctx.clock, 449)
      assert port_now() == []
      at(test_player, ctx.clock, 450)
      assert port_now() == [<<0x80, 69, 64>>]

      deliver(ref, sing(400, 300, 72.0))
      assert Enum.any?(port_now(), &note_on?(&1, 72))
    end
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

  test "a note whose readings stop coming ends on the timer" do
    ref = listening()
    # A stalled input: readings simply stop, no error arrives.
    deliver(ref, sing(0, 300, 69.0))
    assert [{:note_on, 69, _}] = note_events(output_events())
    # Due ~150 ms after the last reading (host timers can be late).
    assert_receive {:output, [{:note_off, 69}]}, 2000
  end

  test "a take reaching its longest is saved as a phrase" do
    :ok = stop_supervised(Engine)
    start_supervised!({Engine, output: FakeOutput, max_take_ms: 400})
    :ok = Engine.subscribe(self())
    ref = listening()
    :ok = Engine.record_start()
    deliver(ref, sing(0, 300, 62.0) ++ sing(300, 300, 65.0))

    assert_receive {:engine, :phrase_saved, %Phrase{} = phrase}, 2000
    assert Enum.map(phrase.notes, & &1.midi) == [62, 65]
    refute Engine.recording?()
    assert Engine.record_stop() == {:error, :not_recording}
    assert [_saved] = Phrases.list()
  end

  describe "when the engine ends" do
    test "a crash turns its note off, stops the microphone and the notification; it comes back off" do
      :ok = Engine.subscribe(self())
      ref = listening()
      deliver(ref, sing(0, 300, 69.0))
      output_events()
      old = Process.whereis(Engine)
      mon = Process.monitor(old)

      ExUnit.CaptureLog.capture_log(fn ->
        catch_exit(GenServer.call(Engine, :not_a_request))
        assert_receive {:DOWN, ^mon, :process, ^old, _}
      end)

      assert output_events() == [{:note_off, 69}]
      refute Fake.listening?(ref)
      assert Fake.background() == nil
      assert eventually(fn -> Process.whereis(Engine) not in [nil, old] end)
      assert Engine.status() == :off
    end

    test "Realtime restarts the engine when Output goes, and the old engine's note is turned off" do
      :ok = stop_supervised(Engine)

      realtime =
        start_supervised!(
          {Humdinger.Realtime,
           name: :realtime_test,
           children: [
             %{id: :output, start: {Agent, :start_link, [fn -> nil end]}},
             {Engine, output: FakeOutput}
           ]}
        )

      ref = listening()
      deliver(ref, sing(0, 300, 69.0))
      output_events()
      engine = Process.whereis(Engine)

      {:output, output, _, _} =
        realtime |> Supervisor.which_children() |> List.keyfind(:output, 0)

      Process.exit(output, :kill)
      assert eventually(fn -> Process.whereis(Engine) not in [nil, engine] end)
      assert output_events() == [{:note_off, 69}]
      assert Engine.status() == :off
    end
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
    voiced |> Enum.chunk_every(2, 1, :discard) |> Enum.each(fn [x, y] -> assert y - x >= 20 end)
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

      # Sung in real time (the notice follows at most 4 times a second)
      # until the notice shows it, or 3 s.
      shown =
        Enum.reduce_while(0..2990//10, false, fn from, _ ->
          Fake.sing(ref, sing(from, 10, 69.25))
          Process.sleep(10)

          if notice().text == "A4 +25¢ → Humdinger port · ch 1",
            do: {:halt, true},
            else: {:cont, false}
        end)

      assert shown
    end

    test "pause keeps it with Resume; Resume in the shade listens again" do
      :ok = Engine.subscribe(self())
      old = listening()
      :ok = Engine.pause()
      # Take the earlier status messages, so the next :listening is Resume's.
      assert_receive {:engine, :status, :listening}
      assert_receive {:engine, :status, :paused}
      assert %{title: "Humdinger · paused", state: :paused} = notice()

      :ok = Fake.tap_background(:resume)
      assert_receive {:engine, :status, :listening}
      assert Fake.current() not in [nil, old]
      # The notice follows the status message, in the same step.
      Engine.status()
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
      # The tap reaches the engine before this call does.
      assert Engine.status() == :listening
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
