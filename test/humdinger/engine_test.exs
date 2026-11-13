defmodule Humdinger.EngineTest do
  # Mob.State (settings) and the fake microphone are shared.
  use ExUnit.Case, async: false

  alias Humdinger.{Engine, Music, Scale, Settings, Take, Tracker}
  alias Humdinger.Test.FakeAudio
  alias Mob.ScreenCase.StateOwner

  defmodule Output do
    @moduledoc false
    # Forwards what the engine sends to the test process.
    def send_events(events), do: send(Humdinger.EngineTest, {:output, events})
    def configure(opts), do: send(Humdinger.EngineTest, {:configure, opts})
  end

  setup do
    {:ok, ref} = StateOwner.checkout()
    on_exit(fn -> StateOwner.checkin(ref) end)
    Mob.State.delete(:settings)
    :ok = Settings.save(%{Settings.defaults() | scale: Scale.chromatic(), on_stop: :note_off})
    FakeAudio.reset()
    Process.register(self(), __MODULE__)
    start_supervised!({Engine, audio: FakeAudio, output: Output})
    :ok
  end

  defp sing(from, ms, pitch, db \\ -30.0) do
    for t <- from..(from + ms - 1)//5 do
      case pitch do
        nil -> %{t: t, hz: nil, clarity: 0.1, db: -75.0}
        p -> %{t: t, hz: Music.midi_to_hz(p), clarity: 0.95, db: db}
      end
    end
  end

  # Readings in batches of two, as the phone delivers them.
  defp deliver(ref, readings) do
    readings |> Enum.chunk_every(2) |> Enum.each(&FakeAudio.sing(ref, &1))
    Engine.status()
  end

  defp listening do
    :ok = Engine.listen()
    FakeAudio.current()
  end

  defp output_events(acc \\ []) do
    receive do
      {:output, events} -> output_events(acc ++ events)
    after
      0 -> acc
    end
  end

  defp note_events(events), do: Enum.filter(events, &(elem(&1, 0) in [:note_on, :note_off]))

  defp eventually(check, tries \\ 50) do
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

  test "listen turns the microphone on, subscribers get status changes" do
    :ok = Engine.subscribe(self())
    assert_receive {:engine, :status, :off}
    assert Engine.status() == :off

    ref = listening()
    assert FakeAudio.listening?(ref)
    assert_receive {:engine, :status, :listening}
    assert Engine.listen() == :ok
    assert FakeAudio.current() == ref

    :ok = Engine.pause()
    assert_receive {:engine, :status, :paused}
    refute FakeAudio.listening?(ref)
    assert_receive {:engine, :frame, %{mood: :paused}}

    :ok = Engine.resume()
    assert_receive {:engine, :status, :listening}
    assert FakeAudio.current() not in [nil, ref]

    :ok = Engine.stop()
    assert_receive {:engine, :status, :off}
    assert FakeAudio.current() == nil
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

  # Host timers can fire hundreds of ms late (macOS timer coalescing), so
  # these tests bound frame counts from above and wait generously for
  # frames, never for a timer to be on time.
  test "frames come at most 30 a second with the latest state and a mood" do
    :ok = Engine.subscribe(self())
    ref = listening()
    started = System.monotonic_time(:millisecond)

    for i <- 0..39 do
      FakeAudio.sing(ref, sing(i * 10, 10, 69.0))
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

    assert %{voiced: true, sent: "A4 on · vel " <> _} = last

    assert Map.keys(last) |> Enum.sort() ==
             Enum.sort([:t, :pitch, :note, :cents, :hz, :db, :velocity, :voiced, :mood, :sent])
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

    FakeAudio.fail(ref, :device_lost)
    assert_receive {:engine, :status, {:error, :device_lost}}
    assert_receive {:engine, :frame, %{mood: :no_mic}}
  end

  test "a refused microphone is an error status" do
    :ok = Engine.subscribe(self())
    FakeAudio.refuse_next(:permission)
    assert Engine.listen() == {:error, :permission}
    assert Engine.status() == {:error, :permission}
    assert_receive {:engine, :frame, %{mood: :no_mic}}

    assert Engine.listen() == :ok
    assert Engine.status() == :listening
  end

  test "an audio error releases the sounding note" do
    ref = listening()
    deliver(ref, sing(0, 300, 69.0))
    output_events()
    FakeAudio.fail(ref, :device_lost)
    assert Engine.status() == {:error, :device_lost}
    assert output_events() == [{:note_off, 69}]
  end

  test "readings from an earlier listen are ignored" do
    old = listening()
    :ok = Engine.pause()
    :ok = Engine.resume()
    deliver(old, sing(0, 300, 69.0))
    assert output_events() == []

    deliver(FakeAudio.current(), sing(0, 300, 69.0))
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
    # Due ~200 ms after the last reading; host timers may run late.
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
    refute FakeAudio.spectrum?(ref)

    :ok = Engine.spectrum(other, true)
    assert FakeAudio.spectrum?(ref)
    FakeAudio.spectrum(ref, %{t: 0, bins: <<0::1024>>})
    Engine.status()
    refute_received {:engine, :spectrum, _}

    :ok = Engine.spectrum(self(), true)
    FakeAudio.spectrum(ref, %{t: 10, bins: <<1::1024>>})
    Engine.status()
    assert_received {:engine, :spectrum, %{t: 10}}

    :ok = Engine.spectrum(self(), false)
    assert FakeAudio.spectrum?(ref)
    Process.exit(other, :kill)
    # The engine learns of the death from its own monitor, asynchronously.
    assert eventually(fn -> not FakeAudio.spectrum?(ref) end)

    # A new listen asks for the spectrum when someone wants it.
    :ok = Engine.spectrum(self(), true)
    :ok = Engine.pause()
    :ok = Engine.resume()
    assert FakeAudio.spectrum?(FakeAudio.current())
  end

  test "describe matches the output's wording" do
    assert Engine.describe({:note_on, 69, 92}, 1) == "A4 on · vel 92 · ch 1"
    assert Engine.describe({:note_off, 61}, 16) == "C#4 off · ch 16"
    assert Engine.describe({:pitch_bend, 1234}, 1) == "bend +1234 · ch 1"
    assert Engine.describe({:pitch_bend, -1234}, 1) == "bend -1234 · ch 1"
    assert Engine.describe({:pitch_bend, 0}, 1) == "bend 0 · ch 1"
    assert Engine.describe({:cc, 11, 80}, 2) == "CC 11 = 80 · ch 2"
  end
end
