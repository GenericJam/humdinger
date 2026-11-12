defmodule Humdinger.Scale do
  @moduledoc """
  A scale: a root pitch class (0 = C … 11 = B) and a mode. Live's Scale mode
  snaps the voice to it, phrases carry it, sheet music takes its key
  signature from it. `chromatic/0` is every note ("Chromatic" on the
  Import screen; Live's "Open + bend" mode has no scale at all).
  """

  alias Humdinger.Music

  @enforce_keys [:root, :mode]
  defstruct [:root, :mode]

  @type mode ::
          :major
          | :minor
          | :dorian
          | :phrygian
          | :lydian
          | :mixolydian
          | :locrian
          | :harmonic_minor
          | :major_pentatonic
          | :minor_pentatonic
          | :blues
          | :chromatic
  @type t :: %__MODULE__{root: 0..11, mode: mode()}

  # Semitones above the root, and how far the mode's root sits above its
  # parent major key (for the key signature).
  @modes [
    major: {[0, 2, 4, 5, 7, 9, 11], 0, "major"},
    minor: {[0, 2, 3, 5, 7, 8, 10], 9, "minor"},
    dorian: {[0, 2, 3, 5, 7, 9, 10], 2, "Dorian"},
    phrygian: {[0, 1, 3, 5, 7, 8, 10], 4, "Phrygian"},
    lydian: {[0, 2, 4, 6, 7, 9, 11], 5, "Lydian"},
    mixolydian: {[0, 2, 4, 5, 7, 9, 10], 7, "Mixolydian"},
    locrian: {[0, 1, 3, 5, 6, 8, 10], 11, "Locrian"},
    harmonic_minor: {[0, 2, 3, 5, 7, 8, 11], 9, "harmonic minor"},
    major_pentatonic: {[0, 2, 4, 7, 9], 0, "major pentatonic"},
    minor_pentatonic: {[0, 3, 5, 7, 10], 9, "minor pentatonic"},
    blues: {[0, 3, 5, 6, 7, 10], 9, "blues"},
    chromatic: {Enum.to_list(0..11), 0, "Chromatic"}
  ]

  # Key signature (sharps > 0, flats < 0) of each major key by pitch class.
  @major_fifths %{
    0 => 0,
    1 => -5,
    2 => 2,
    3 => -3,
    4 => 4,
    5 => -1,
    6 => 6,
    7 => 1,
    8 => -4,
    9 => 3,
    10 => -2,
    11 => 5
  }

  @doc "Every mode, in menu order."
  def modes, do: Keyword.keys(@modes)

  @doc "A scale from a root (a pitch class 0..11, or a name such as D, F# or Bb) and a mode."
  def new(root, mode) when is_integer(root) and root in 0..11 and is_atom(mode) do
    if Keyword.has_key?(@modes, mode),
      do: %__MODULE__{root: root, mode: mode},
      else: raise(ArgumentError, "unknown mode #{inspect(mode)}")
  end

  def new(root, mode) when is_binary(root) do
    {:ok, midi} = Music.parse(root <> "4")
    new(Integer.mod(midi, 12), mode)
  end

  @doc "Every note."
  def chromatic, do: %__MODULE__{root: 0, mode: :chromatic}

  @doc "The scale's display name: D Dorian, E minor, Bb major, Chromatic."
  def name(%__MODULE__{mode: :chromatic}), do: "Chromatic"

  def name(%__MODULE__{root: root, mode: mode}) do
    {_steps, _offset, label} = Keyword.fetch!(@modes, mode)
    root_name(root, mode) <> " " <> label
  end

  @doc "Semitones above the root that belong to the scale."
  def steps(%__MODULE__{mode: mode}), do: mode |> then(&Keyword.fetch!(@modes, &1)) |> elem(0)

  @doc "The pitch classes (0..11) in the scale."
  def pitch_classes(%__MODULE__{root: root} = scale),
    do: Enum.map(steps(scale), &Integer.mod(root + &1, 12))

  @doc "Whether a MIDI note is in the scale."
  def contains?(%__MODULE__{} = scale, midi) when is_integer(midi),
    do: Integer.mod(midi, 12) in pitch_classes(scale)

  @doc """
  The in-scale MIDI note nearest a fractional pitch. A pitch exactly between
  two scale notes goes to the lower one.
  """
  def snap(%__MODULE__{mode: :chromatic}, pitch) when is_number(pitch), do: round_half_down(pitch)

  def snap(%__MODULE__{} = scale, pitch) when is_number(pitch) do
    base = floor(pitch)

    (base - 3)..(base + 4)
    |> Enum.filter(&contains?(scale, &1))
    |> Enum.min_by(fn n -> {abs(n - pitch), n} end)
  end

  @doc """
  Key signature in fifths (sharps positive, flats negative), from the
  scale's parent major key. Chromatic has none (0).
  """
  def key_fifths(%__MODULE__{mode: :chromatic}), do: 0

  def key_fifths(%__MODULE__{root: root, mode: mode}) do
    {_steps, offset, _label} = Keyword.fetch!(@modes, mode)
    Map.fetch!(@major_fifths, Integer.mod(root - offset, 12))
  end

  @doc """
  Whether notes in this key are spelled with flats (Bb rather than A#).
  """
  def flats?(%__MODULE__{} = scale), do: key_fifths(scale) < 0

  # Krumhansl–Kessler key profiles.
  @major_profile [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
  @minor_profile [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

  @doc """
  The major or minor key that best fits some notes (`{midi, weight}` pairs,
  weight usually the duration), by Krumhansl–Schmuckler correlation.
  Returns `nil` for no notes.
  """
  def detect([]), do: nil

  def detect(weighted) when is_list(weighted) do
    histogram =
      Enum.reduce(weighted, List.duplicate(0.0, 12), fn {midi, w}, acc ->
        List.update_at(acc, Integer.mod(midi, 12), &(&1 + w))
      end)

    for root <- 0..11, {mode, profile} <- [major: @major_profile, minor: @minor_profile] do
      rotated = Enum.map(0..11, &Enum.at(profile, Integer.mod(&1 - root, 12)))
      {correlation(histogram, rotated), -root, mode, root}
    end
    |> Enum.max()
    |> then(fn {_r, _neg, mode, root} -> %__MODULE__{root: root, mode: mode} end)
  end

  defp correlation(xs, ys) do
    mx = Enum.sum(xs) / 12
    my = Enum.sum(ys) / 12
    pairs = Enum.zip(xs, ys)
    num = Enum.reduce(pairs, 0.0, fn {x, y}, acc -> acc + (x - mx) * (y - my) end)
    dx = Enum.reduce(xs, 0.0, fn x, acc -> acc + (x - mx) * (x - mx) end)
    dy = Enum.reduce(ys, 0.0, fn y, acc -> acc + (y - my) * (y - my) end)
    if dx == 0.0 or dy == 0.0, do: 0.0, else: num / :math.sqrt(dx * dy)
  end

  defp root_name(root, mode) do
    sharp = Music.pitch_class_name(root)

    if String.ends_with?(sharp, "#") and key_fifths(%__MODULE__{root: root, mode: mode}) < 0 do
      flat_name(root)
    else
      sharp
    end
  end

  defp flat_name(pc), do: Enum.at(~w(C Db D Eb E F Gb G Ab A Bb B), pc)

  defp round_half_down(x) do
    f = floor(x)
    if x - f > 0.5, do: f + 1, else: f
  end
end
