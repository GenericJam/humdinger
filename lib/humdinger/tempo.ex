defmodule Humdinger.Tempo do
  @moduledoc """
  Tempo from note onsets, for a phrase hummed without a metronome.

  Every whole tempo from 60 to 180 bpm is tried as an eighth-note grid. For
  each grid the onsets' best phase is their circular mean, and the fit is the
  mean Gaussian closeness (σ = 35 ms, so ±20–40 ms of human jitter still
  counts) of each onset to its nearest grid line.

  A finer grid fits any onsets better by chance alone, so the fit is
  rescaled against what randomly placed onsets would score on that grid
  (the kernel's share of one grid period). The best-fitting tempo wins (the
  slowest of near-ties: perfectly even notes also fit a grid 3:2 faster),
  which rules out the 3:2 relatives that only explain some of the onsets. A tempo
  and its half or double can fit about equally (a melody of quarter notes
  fits both), so the final pick among the best tempo and its half and double
  (those fitting within 0.2 of it) goes to the one closest, on a log scale,
  to 100 bpm: the octave a singer most likely meant.

  The confidence is the rescaled fit (0..1): 1 when every onset sits on the
  grid, around 0.5 or less for onsets with no steady pulse.
  """

  @bpm_range 60..180
  @sigma_ms 35.0
  @prior_bpm 100
  @prior_octaves 0.6
  @octave_slack 0.2
  @tie 0.02

  @type result :: %{bpm: pos_integer(), confidence: float(), phase_ms: float()}

  @doc """
  Detects the tempo of onsets given in ms. Returns `nil` for fewer than
  three distinct onsets. `phase_ms` (0 ≤ phase < one eighth) is where the
  eighth-note grid lines fall: `phase_ms + k · eighth_ms(bpm)`.
  """
  @spec detect([number()]) :: result() | nil
  def detect(onsets) when is_list(onsets) do
    case onsets |> Enum.map(&(&1 * 1.0)) |> Enum.uniq() |> Enum.sort() do
      [_, _, _ | _] = sorted -> best_tempo(sorted)
      _ -> nil
    end
  end

  defp best_tempo(onsets) do
    fits = Map.new(@bpm_range, &{&1, grid_fit(onsets, eighth_ms(&1))})
    {_bpm, {top, _}} = Enum.max_by(fits, fn {_bpm, {fit, _}} -> fit end)

    # Near-ties (perfectly even notes fit 3:2 relatives too) go to the
    # coarser grid.
    {best, {best_fit, _}} =
      fits
      |> Enum.filter(fn {_bpm, {fit, _}} -> fit >= top - @tie end)
      |> Enum.min_by(&elem(&1, 0))

    {bpm, {fit, phase}} =
      [best / 2, best, best * 2]
      |> Enum.map(&round/1)
      |> Enum.filter(&(Map.has_key?(fits, &1) and elem(fits[&1], 0) >= best_fit - @octave_slack))
      |> Enum.map(&{&1, fits[&1]})
      |> Enum.max_by(fn {bpm, {fit, _}} -> max(fit, 0.0) * prior(bpm) end)

    %{bpm: bpm, confidence: fit |> max(0.0) |> min(1.0), phase_ms: phase}
  end

  @doc "The length of an eighth note at `bpm`, in ms."
  def eighth_ms(bpm), do: 30_000 / bpm

  # Fit of onsets to a grid of `period` ms at its best phase, rescaled so
  # random onsets score about 0 and onsets exactly on the grid score 1.
  defp grid_fit(onsets, period) do
    {sx, sy} =
      Enum.reduce(onsets, {0.0, 0.0}, fn t, {sx, sy} ->
        a = 2 * :math.pi() * t / period
        {sx + :math.cos(a), sy + :math.sin(a)}
      end)

    phase = fmod(:math.atan2(sy, sx) / (2 * :math.pi()) * period, period)

    closeness =
      Enum.reduce(onsets, 0.0, fn t, acc ->
        d = deviation(t, phase, period)
        acc + :math.exp(-d * d / (2 * @sigma_ms * @sigma_ms))
      end) / length(onsets)

    chance = min(@sigma_ms * :math.sqrt(2 * :math.pi()) / period, 0.95)
    {(closeness - chance) / (1 - chance), phase}
  end

  # Signed distance from t to the nearest grid line.
  defp deviation(t, phase, period) do
    x = fmod(t - phase, period)
    if x > period / 2, do: x - period, else: x
  end

  defp prior(bpm) do
    z = :math.log2(bpm / @prior_bpm) / @prior_octaves
    :math.exp(-0.5 * z * z)
  end

  defp fmod(x, m), do: x - m * Float.floor(x / m)
end
