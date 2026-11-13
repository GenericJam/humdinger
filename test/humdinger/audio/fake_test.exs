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

    test "cancel ends it; an unknown reference is ignored" do
      {:ok, ref} = Fake.analyze_file(self(), "/tmp/a.wav", [])
      assert Fake.analysing?(ref)
      assert :ok = Fake.cancel_analysis(ref)
      refute Fake.analysing?(ref)
      assert :ok = Fake.cancel_analysis(make_ref())
    end

    test "one per owner: a newer analysis cancels the older" do
      {:ok, first} = Fake.analyze_file(self(), "/tmp/a.wav", [])
      {:ok, second} = Fake.analyze_file(self(), "/tmp/b.wav", [])
      refute Fake.analysing?(first)
      assert Fake.analysing?(second)
    end

    test "a burst of replacements leaves one analysis, and other owners still fit" do
      refs = for i <- 1..20, do: elem(Fake.analyze_file(self(), "/tmp/#{i}.wav", []), 1)
      {older, [latest]} = Enum.split(refs, -1)
      assert Fake.analysing?(latest)
      refute Enum.any?(older, &Fake.analysing?/1)

      [b, c] = for _ <- 1..2, do: spawn(fn -> receive do: (:go -> :ok) end)
      assert {:ok, _} = Fake.analyze_file(b, "/tmp/b.wav", [])
      assert {:error, :busy} = Fake.analyze_file(c, "/tmp/c.wav", [])
      Enum.each([b, c], &send(&1, :go))
    end

    test "two owners at once; a third is busy until one finishes" do
      owners = for _ <- 1..3, do: spawn(fn -> receive do: (:go -> :ok) end)
      [a, b, c] = owners
      {:ok, ref_a} = Fake.analyze_file(a, "/tmp/a.wav", [])
      {:ok, _} = Fake.analyze_file(b, "/tmp/b.wav", [])
      assert {:error, :busy} = Fake.analyze_file(c, "/tmp/c.wav", [])

      :ok = Fake.analysis_error(ref_a, :decode_error)
      assert {:ok, _} = Fake.analyze_file(c, "/tmp/c.wav", [])
      Enum.each(owners, &send(&1, :go))
    end

    test "it is cancelled when its owner exits; a dead owner can't start one" do
      owner = spawn(fn -> receive do: (:go -> :ok) end)
      {:ok, ref} = Fake.analyze_file(owner, "/tmp/a.wav", [])
      mon = Process.monitor(owner)
      send(owner, :go)
      assert_receive {:DOWN, ^mon, :process, ^owner, _}
      assert Enum.any?(1..200, fn _ -> not Fake.analysing?(ref) or Process.sleep(1) == :never end)
      assert {:error, :owner_dead} = Fake.analyze_file(owner, "/tmp/a.wav", [])
    end
  end
end
