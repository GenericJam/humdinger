defmodule Humdinger.RangeFinder do
  @moduledoc """
  First run's "find your range": the singer holds their lowest comfortable
  note, then their highest, each for `hold_ms/0` (2 s).

  Feed it the sung pitch (fractional MIDI from the raw Hz, before octave
  and transpose) with `push/3`. A hold starts on the first voiced reading
  and lasts while the voice stays within a semitone of where it started.
  Readings further off are set aside: a stray run (readings within a
  semitone of each other) that lasts `stray_ms/0` (100 ms) is a new note
  and starts a new hold there, while shorter ones (the detector's octave
  and sub-octave blips) are ignored. A silence longer than `gap_ms/0`
  (250 ms, from the last pitched reading of any note) ends the hold; shorter dropouts don't. When a hold reaches 2 s
  its note (the rounded median of the hold) becomes the lowest, or the
  highest; a highest that isn't above the lowest is refused (`refused/1`)
  and the singer holds again. `holding/1` keeps the last held note through
  a silence, so a screen can keep showing it.

  `octave_for/1` is the octave setting a range gets: the shift (−3..3)
  that brings the middle of the range closest to E4 (MIDI 64, the middle
  of the treble staff, where melody patches on a synth sit). E2–G4 (40–67,
  middle 53.5) gets +1: a low voice plays an octave up.
  """

  alias Humdinger.Music

  @hold_ms 2_000
  @gap_ms 250
  @stray_ms 100
  @tolerance 1.0
  @target 64

  defstruct phase: :low,
            low: nil,
            high: nil,
            anchor: nil,
            start_t: nil,
            last_t: nil,
            pitches: [],
            stray: [],
            kept: 0,
            heard_t: nil,
            candidate: nil,
            refused: false

  @type t :: %__MODULE__{
          phase: :low | :high | :done,
          low: integer() | nil,
          high: integer() | nil,
          anchor: float() | nil,
          start_t: integer() | nil,
          last_t: integer() | nil,
          pitches: [float()],
          stray: [{integer(), float()}],
          kept: non_neg_integer(),
          heard_t: integer() | nil,
          candidate: integer() | nil,
          refused: boolean()
        }

  @doc "How long a note must be held, ms."
  def hold_ms, do: @hold_ms

  @doc "The longest silence a hold survives, ms."
  def gap_ms, do: @gap_ms

  @doc "How long readings off the held note must last to count as a new note, ms."
  def stray_ms, do: @stray_ms

  @doc "A finder asking for the lowest note."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "A finder from a saved `{low, high}` (done), or `new/0` for nil."
  @spec from_range({integer(), integer()} | nil) :: t()
  def from_range({low, high}), do: %__MODULE__{phase: :done, low: low, high: high}
  def from_range(nil), do: new()

  @doc "Add the pitch heard at engine time `t` (nil when silent)."
  @spec push(t(), integer(), float() | nil) :: t()
  def push(%{phase: :done} = finder, _t, _pitch), do: finder

  def push(finder, t, nil) do
    finder = %{finder | stray: [], kept: 0}
    if finder.anchor && t - finder.heard_t > @gap_ms, do: reset(finder), else: finder
  end

  def push(%{anchor: nil} = finder, t, pitch), do: start(%{finder | heard_t: t}, t, [pitch])

  def push(finder, t, pitch) do
    gap = t - finder.heard_t
    finder = %{finder | heard_t: t}

    cond do
      gap > @gap_ms ->
        start(finder, t, [pitch])

      abs(pitch - finder.anchor) <= @tolerance ->
        %{finder | last_t: t, pitches: [pitch | finder.pitches], kept: finder.kept + 1} |> check()

      true ->
        stray(finder, t, pitch)
    end
  end

  # An off-note reading joins the stray run (readings within a semitone of
  # its first; another pitch starts a new run). The run becomes the held
  # note once it spans @stray_ms and outnumbers the readings of the held
  # note since it began (`kept`), so a note change wins in 100 ms, a hold
  # that began on a blip hands over to the real note, and the detector's
  # occasional octave errors never do.
  defp stray(finder, t, pitch) do
    {run, kept} =
      case finder.stray do
        [{_t0, p0} | _] = run when abs(pitch - p0) <= @tolerance ->
          {run ++ [{t, pitch}], finder.kept}

        _ ->
          {[{t, pitch}], 0}
      end

    case run do
      [{t0, _} | _] when t - t0 >= @stray_ms and length(run) > kept ->
        start(finder, t0, Enum.map(run, &elem(&1, 1)), t)

      run ->
        %{finder | stray: run, kept: kept}
    end
  end

  defp start(finder, t0, [first | _] = pitches, last_t \\ nil) do
    %{
      finder
      | anchor: first,
        start_t: t0,
        last_t: last_t || t0,
        pitches: Enum.reverse(pitches),
        stray: [],
        kept: 0
    }
    |> check()
  end

  defp check(finder) do
    finder = %{finder | candidate: round(median(finder.pitches))}
    if finder.last_t - finder.start_t >= @hold_ms, do: settle(finder), else: finder
  end

  @doc "How long the current note has been held, ms (0 when none)."
  @spec held_ms(t()) :: non_neg_integer()
  def held_ms(%{anchor: nil}), do: 0
  def held_ms(finder), do: min(finder.last_t - finder.start_t, @hold_ms)

  @doc "The note being held now (rounded median so far), else the last one held this step, or nil."
  @spec holding(t()) :: integer() | nil
  def holding(%{pitches: []} = finder), do: finder.candidate
  def holding(finder), do: round(median(finder.pitches))

  @doc "Whether the last highest was refused for not being above the lowest."
  @spec refused(t()) :: boolean()
  def refused(finder), do: finder.refused

  @doc "The range found, once both notes are in."
  @spec range(t()) :: {integer(), integer()} | nil
  def range(%{phase: :done, low: low, high: high}), do: {low, high}
  def range(_finder), do: nil

  @doc "Start again from the lowest."
  @spec restart(t()) :: t()
  def restart(_finder), do: new()

  @doc "The octave setting for a range (see the moduledoc)."
  @spec octave_for({integer(), integer()}) :: -3..3
  def octave_for({low, high}) do
    ((@target - (low + high) / 2) / 12) |> round() |> max(-3) |> min(3)
  end

  @doc "\"E2 – G4\" for a range."
  @spec label({integer(), integer()}) :: String.t()
  def label({low, high}), do: "#{Music.note_name(low)} – #{Music.note_name(high)}"

  defp settle(%{phase: :low} = finder),
    do: %{reset(finder) | phase: :high, low: holding(finder), candidate: nil, refused: false}

  defp settle(%{phase: :high} = finder) do
    note = holding(finder)

    if note > finder.low,
      do: %{reset(finder) | phase: :done, high: note, candidate: nil, refused: false},
      else: %{reset(finder) | candidate: nil, refused: true}
  end

  defp reset(finder), do: %{finder | anchor: nil, start_t: nil, pitches: [], stray: [], kept: 0}

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end
end
