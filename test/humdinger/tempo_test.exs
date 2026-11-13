defmodule Humdinger.TempoTest do
  use ExUnit.Case, async: true

  alias Humdinger.Tempo

  # Two bars of a melody in eighths, with rests (a gap at eighths 4–7 and 12–15).
  @pattern [0, 2, 3, 8, 10, 11, 16, 18, 19, 20, 24, 26, 28, 30]

  defp perform(steps, bpm, jitter_ms, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    eighth = Tempo.eighth_ms(bpm)
    Enum.map(steps, fn s -> 400 + s * eighth + (:rand.uniform() * 2 - 1) * jitter_ms end)
  end

  test "finds the tempo of performances with human jitter and rests" do
    for bpm <- [72, 84, 96, 110, 126, 140], jitter <- [0, 20, 40], seed <- 1..3 do
      %{bpm: found} = Tempo.detect(perform(@pattern, bpm, jitter, seed))
      assert abs(found - bpm) <= 1, "#{bpm} bpm ±#{jitter} ms (seed #{seed}) detected as #{found}"
    end
  end

  test "fast tempos may come back at half speed, never a 3:2 relative" do
    for bpm <- [160, 180] do
      %{bpm: found} = Tempo.detect(perform(@pattern, bpm, 25, 4))
      assert abs(found - bpm) <= 1 or abs(found - bpm / 2) <= 1
    end
  end

  test "even quarter notes pick the octave nearest a singer's usual tempo" do
    quarters = Enum.map(0..11, &(&1 * 2))

    assert %{bpm: 100} = Tempo.detect(perform(quarters, 100, 0, 5))
    assert %{bpm: 120} = Tempo.detect(perform(quarters, 60, 0, 5))
    assert %{bpm: 84} = Tempo.detect(perform(quarters, 168, 0, 5))
  end

  test "the grid phase locates the onsets" do
    onsets = perform(@pattern, 96, 0, 6)
    %{bpm: 96, phase_ms: phase} = Tempo.detect(onsets)
    eighth = Tempo.eighth_ms(96)

    for t <- onsets do
      steps = (t - phase) / eighth
      assert abs(steps - round(steps)) < 0.01
    end
  end

  test "confidence is high on the grid and lower for onsets with no pulse" do
    %{confidence: steady} = Tempo.detect(perform(@pattern, 100, 10, 7))
    :rand.seed(:exsss, {9, 9, 9})
    %{confidence: random} = Tempo.detect(Enum.map(1..14, fn _ -> :rand.uniform() * 8000 end))

    assert steady > 0.9
    assert random < 0.6
  end

  test "needs three distinct onsets" do
    assert Tempo.detect([]) == nil
    assert Tempo.detect([0, 500]) == nil
    assert Tempo.detect([0, 500, 500]) == nil
    assert %{} = Tempo.detect([0, 500, 1000])
  end
end
