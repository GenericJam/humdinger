defmodule Humdinger.RangeFinderTest do
  use ExUnit.Case, async: true

  alias Humdinger.RangeFinder

  defp hold(finder, from, ms, pitch_fun) do
    Enum.reduce(from..(from + ms)//10, finder, fn t, f ->
      RangeFinder.push(f, t, pitch_fun.(t))
    end)
  end

  test "a 2 s hold within a semitone sets the lowest, then the highest" do
    f = hold(RangeFinder.new(), 0, 1_000, fn _ -> 40.2 end)
    assert f.phase == :low
    assert RangeFinder.held_ms(f) == 1_000
    assert RangeFinder.holding(f) == 40

    f = hold(f, 1_010, 1_000, fn t -> 40.0 + :math.sin(t / 50) * 0.8 end)
    assert f.phase == :high
    assert f.low == 40
    assert RangeFinder.held_ms(f) == 0

    f = hold(f, 3_000, 2_000, fn _ -> 67.1 end)
    assert RangeFinder.range(f) == {40, 67}
    assert RangeFinder.label({40, 67}) == "E2 – G4"
  end

  test "straying more than a semitone starts the hold again" do
    f = hold(RangeFinder.new(), 0, 1_500, fn _ -> 50.0 end)
    f = RangeFinder.push(f, 1_510, 51.5)
    assert RangeFinder.held_ms(f) == 0
    assert RangeFinder.holding(f) == 52
  end

  test "a short breath doesn't end a hold; a longer silence does" do
    f = hold(RangeFinder.new(), 0, 1_000, fn _ -> 50.0 end)
    f = RangeFinder.push(f, 1_100, nil)
    f = RangeFinder.push(f, 1_110, 50.0)
    assert RangeFinder.held_ms(f) == 1_110

    f = RangeFinder.push(f, 1_400, nil)
    assert RangeFinder.held_ms(f) == 0
  end

  test "a highest no higher than the lowest is refused" do
    f = hold(RangeFinder.new(), 0, 2_000, fn _ -> 55.0 end)
    f = hold(f, 2_500, 2_000, fn _ -> 55.0 end)
    assert f.phase == :high
    assert RangeFinder.refused(f)
  end

  test "the octave puts the middle of the range nearest E4" do
    assert RangeFinder.octave_for({40, 67}) == 1
    assert RangeFinder.octave_for({57, 79}) == 0
    assert RangeFinder.octave_for({72, 96}) == -2
    assert RangeFinder.octave_for({69, 91}) == -1
    assert RangeFinder.octave_for({21, 30}) == 3
    assert RangeFinder.octave_for({100, 108}) == -3
  end
end
