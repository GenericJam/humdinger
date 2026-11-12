defmodule Humdinger.ScaleTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Music, Scale}

  test "note names and parsing round-trip, middle C is C4" do
    assert Music.note_name(60) == "C4"
    assert Music.note_name(69) == "A4"
    assert Music.note_name(70) == "A#4"
    assert Music.note_name(21) == "A0"
    assert Music.parse("Bb2") == {:ok, 46}
    assert Music.parse("f#3") == {:ok, 54}
    assert Music.parse("H4") == :error
    for n <- 21..108, do: assert(Music.parse(Music.note_name(n)) == {:ok, n})
  end

  test "frequency conversions" do
    assert_in_delta Music.hz_to_midi(440.0), 69.0, 1.0e-9
    assert_in_delta Music.hz_to_midi(220.0), 57.0, 1.0e-9
    assert_in_delta Music.midi_to_hz(60), 261.6256, 1.0e-3
  end

  test "names follow the design: D Dorian, E minor, flats in flat keys" do
    assert Scale.name(Scale.new("D", :dorian)) == "D Dorian"
    assert Scale.name(Scale.new("E", :minor)) == "E minor"
    assert Scale.name(Scale.new(10, :major)) == "Bb major"
    assert Scale.name(Scale.new(6, :major)) == "F# major"
    assert Scale.name(Scale.chromatic()) == "Chromatic"
  end

  test "key signatures come from the parent major key" do
    assert Scale.key_fifths(Scale.new("D", :dorian)) == 0
    assert Scale.key_fifths(Scale.new("E", :minor)) == 1
    assert Scale.key_fifths(Scale.new("A", :minor)) == 0
    assert Scale.key_fifths(Scale.new("F", :major)) == -1
    assert Scale.key_fifths(Scale.new("G", :mixolydian)) == 0
  end

  test "snap goes to the nearest scale note, ties to the lower" do
    c_major = Scale.new("C", :major)
    # F#4 (66) is between F4 and G4: the lower wins.
    assert Scale.snap(c_major, 66.0) == 65
    assert Scale.snap(c_major, 66.2) == 67
    assert Scale.snap(c_major, 60.9) == 60
    assert Scale.snap(c_major, 61.4) == 62
    assert Scale.snap(Scale.chromatic(), 61.5) == 61
    assert Scale.snap(Scale.chromatic(), 61.51) == 62
    # Pentatonic gaps are wider than a tone.
    assert Scale.snap(Scale.new("C", :major_pentatonic), 65.4) == 64
  end

  test "detect finds the key of a plain melody" do
    e_minor = [{64, 4}, {66, 1}, {67, 2}, {71, 2}, {69, 1}, {67, 1}, {66, 1}, {64, 4}, {59, 1}]
    assert Scale.detect(e_minor) == Scale.new("E", :minor)

    c_major = [{60, 4}, {62, 1}, {64, 2}, {65, 1}, {67, 3}, {69, 1}, {71, 1}, {72, 4}]
    assert Scale.detect(c_major) == Scale.new("C", :major)
    assert Scale.detect([]) == nil
  end
end
