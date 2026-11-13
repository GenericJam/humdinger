defmodule Humdinger.SettingsTest do
  # Mob.State is one shared store; these tests write to it.
  use ExUnit.Case, async: false

  alias Humdinger.{Scale, Settings}
  alias Mob.ScreenCase.StateOwner

  setup do
    {:ok, ref} = StateOwner.checkout()
    on_exit(fn -> StateOwner.checkin(ref) end)
    Mob.State.delete(:settings)
    :ok
  end

  test "nothing saved loads the board defaults" do
    s = Settings.load()
    assert s == Settings.defaults()
    assert s.response == :balanced
    assert s.pitch_change == :legato
    assert s.on_stop == :hold
    assert s.bend_range == 2

    assert {s.velocity_from_loudness, s.cc11_from_loudness, s.cc1_from_vibrato} ==
             {true, true, false}

    assert s.mode == :scale
    assert Scale.name(s.scale) == "D Dorian"
    assert {s.octave, s.transpose, s.channel} == {0, 0, 1}
    assert s.destinations == %{fmutate: true, port: true, usb: false, bt: false}
    assert s.range == nil
    refute s.first_run_done
    {low, high} = Settings.sensitivity_range()
    assert s.sensitivity_db > low and s.sensitivity_db < high
  end

  test "saved settings survive a reload" do
    {:ok, s} =
      Settings.merge(Settings.defaults(),
        scale: Scale.new("Bb", :major),
        mode: :open,
        octave: -2,
        range: {40, 67},
        first_run_done: true
      )

    :ok = Settings.save(s)
    assert Settings.load() == s
  end

  test "update takes a map, a keyword list or a function, and saves" do
    assert {:ok, %{octave: 1}} = Settings.update(%{octave: 1})
    assert {:ok, %{octave: 1, transpose: -5}} = Settings.update(transpose: -5)
    assert {:ok, %{octave: 2}} = Settings.update(&%{&1 | octave: &1.octave + 1})
    assert %{octave: 2, transpose: -5} = Settings.load()
  end

  test "destinations merge into the current ones" do
    {:ok, s} = Settings.update(destinations: %{usb: true})
    assert s.destinations == %{fmutate: true, port: true, usb: true, bt: false}
  end

  test "an invalid change is refused and nothing is saved" do
    {:ok, _} = Settings.update(octave: 1)

    for change <- [
          [octave: 4],
          [transpose: 13],
          [channel: 0],
          [bend_range: 3],
          [response: :slow],
          [sensitivity_db: -95],
          [range: {70, 60}],
          [destinations: %{midi: true}],
          [scale: %Scale{root: 12, mode: :major}],
          [colour: :blue]
        ] do
      [{field, _}] = change
      assert Settings.update(change) == {:error, {:invalid, field}}
    end

    assert Settings.update(fn s -> %{s | channel: 17} end) == {:error, {:invalid, :channel}}
    assert Settings.update(fn _ -> :nope end) == {:error, {:invalid, :settings}}
    assert Settings.load().octave == 1
    assert Settings.load().channel == 1
  end

  test "older or newer saved settings load: unknown keys dropped, bad values defaulted" do
    Mob.State.put(:settings, %{
      octave: 2,
      channel: 99,
      scale: {9, :minor},
      response: :warp,
      destinations: %{bt: true},
      some_future_field: :whatever
    })

    s = Settings.load()
    assert s.octave == 2
    assert s.channel == 1
    assert Scale.name(s.scale) == "A minor"
    assert s.response == :balanced
    assert s.destinations == %{fmutate: true, port: true, usb: false, bt: true}
    refute Map.has_key?(s, :some_future_field)

    Mob.State.put(:settings, :garbage)
    assert Settings.load() == Settings.defaults()
  end
end
