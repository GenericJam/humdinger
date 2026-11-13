defmodule Humdinger.Audio.FakeTest do
  # One engine per VM, like the phone: not async.
  use ExUnit.Case, async: false

  alias Humdinger.Audio.Fake

  setup do
    Fake.reset()
    :ok
  end

  defp reading(t, hz), do: %{t: t, hz: hz, clarity: 0.9, db: -20.0}

  test "the test engine is the configured one" do
    assert Humdinger.Audio.impl() == Fake
  end

  describe "listening" do
    test "readings and spectra reach the owner tagged with its reference" do
      {:ok, ref} = Fake.listen(self(), spectrum: true)
      assert Fake.listening?(ref)
      assert Fake.spectrum?(ref)

      :ok = Fake.sing(ref, [reading(0, 440.0), reading(5, nil)])
      assert_receive {:hum_audio, ^ref, {:readings, [%{hz: 440.0}, %{hz: nil}]}}

      column = %{t: 10, bins: :binary.copy(<<7>>, 128)}
      :ok = Fake.spectrum(ref, column)
      assert_receive {:hum_audio, ^ref, {:spectrum, ^column}}
    end

    test "spectrum is off unless asked for, and toggles while listening" do
      {:ok, ref} = Fake.listen(self(), [])
      refute Fake.spectrum?(ref)
      :ok = Fake.set_spectrum(ref, true)
      assert Fake.spectrum?(ref)
      :ok = Fake.set_spectrum(ref, false)
      refute Fake.spectrum?(ref)
    end

    test "the chosen input is recorded" do
      [_, %{id: id} | _] = Fake.inputs()
      {:ok, _ref} = Fake.listen(self(), input: id)
      assert %{input: ^id} = Fake.current_opts()
    end

    test "a second listen replaces the first; the old reference is stale" do
      {:ok, old} = Fake.listen(self(), spectrum: true)
      {:ok, new} = Fake.listen(self(), [])
      assert old != new
      refute Fake.listening?(old)
      assert Fake.current() == new

      # Calls with the stale reference change nothing.
      :ok = Fake.set_spectrum(old, true)
      refute Fake.spectrum?(new)
      :ok = Fake.stop(old)
      assert Fake.listening?(new)
    end

    test "stale messages are still deliverable, so owners can be tested against them" do
      {:ok, old} = Fake.listen(self(), [])
      {:ok, _new} = Fake.listen(self(), [])
      :ok = Fake.sing(old, [reading(0, 220.0)])
      assert_receive {:hum_audio, ^old, {:readings, _}}
    end

    test "stop ends listening and is idempotent" do
      {:ok, ref} = Fake.listen(self(), [])
      assert :ok = Fake.stop(ref)
      refute Fake.listening?(ref)
      assert Fake.current() == nil
      assert :ok = Fake.stop(ref)
    end

    test "a failure reaches the owner and ends listening" do
      {:ok, ref} = Fake.listen(self(), [])
      :ok = Fake.fail(ref, :device_lost)
      assert_receive {:hum_audio, ^ref, {:error, :device_lost}}
      refute Fake.listening?(ref)
    end

    test "listening stops when the owner exits" do
      owner = spawn(fn -> receive do: (:go -> :ok) end)
      {:ok, ref} = Fake.listen(owner, [])
      assert Fake.listening?(ref)
      send(owner, :go)
      # The Fake hears of the exit through its own monitor, in its own time.
      assert Enum.any?(1..200, fn _ -> not Fake.listening?(ref) or Process.sleep(1) == :never end)
    end

    test "without the microphone permission listen is refused" do
      :ok = Fake.set_permission(false)
      assert {:error, :permission} = Fake.listen(self(), [])
      assert Fake.current() == nil
      :ok = Fake.set_permission(true)
      assert {:ok, _} = Fake.listen(self(), [])
    end

    test "driving an unknown reference is a test bug" do
      assert_raise ArgumentError, fn -> Fake.sing(make_ref(), []) end
    end
  end

  test "inputs are microphones in the contract's shape" do
    for input <- Fake.inputs() do
      assert %{id: id, name: name, kind: kind} = input
      assert is_integer(id) and is_binary(name) and is_atom(kind)
    end
  end

  describe "file analysis" do
    test "the result reaches the caller under the analysis reference" do
      {:ok, ref} = Fake.analyze_file(self(), "/tmp/take.m4a", [])
      assert [{^ref, "/tmp/take.m4a"}] = Fake.analyses()

      analysis = %{duration_ms: 1000, waveform: <<0, 128, 255>>, readings: [reading(21, 440.0)]}
      :ok = Fake.analysis(ref, analysis)
      assert_receive {:hum_audio, ^ref, {:analysis, ^analysis}}
    end

    test "errors arrive as analysis_error" do
      {:ok, ref} = Fake.analyze_file(self(), "/tmp/long.mp3", [])
      :ok = Fake.analysis_error(ref, :too_long)
      assert_receive {:hum_audio, ^ref, {:analysis_error, :too_long}}
    end

    test "an analysis doesn't disturb listening" do
      {:ok, listen} = Fake.listen(self(), [])
      {:ok, _} = Fake.analyze_file(self(), "/tmp/a.wav", [])
      assert Fake.listening?(listen)
    end
  end
end
