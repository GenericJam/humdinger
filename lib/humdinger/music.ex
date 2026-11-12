defmodule Humdinger.Music do
  @moduledoc """
  Note numbers, names and frequencies. MIDI numbering: 60 = C4 (middle C),
  69 = A4 = 440 Hz. Names use sharps ("F#4"), as the design boards do.
  """

  @names ~w(C C# D D# E F F# G G# A A# B)

  @doc "The name of a MIDI note: `note_name(69)` → `\"A4\"`."
  def note_name(midi) when is_integer(midi) do
    Enum.at(@names, Integer.mod(midi, 12)) <> Integer.to_string(octave(midi))
  end

  @doc "The pitch class name without octave: `pitch_class_name(70)` → `\"A#\"`."
  def pitch_class_name(midi) when is_integer(midi), do: Enum.at(@names, Integer.mod(midi, 12))

  @doc "The octave number of a MIDI note (C4 = 60 is in octave 4)."
  def octave(midi) when is_integer(midi), do: Integer.floor_div(midi, 12) - 1

  @doc """
  Parses a note name ("A4", "F#3", "Bb2", "c5") to its MIDI number.
  """
  def parse(name) when is_binary(name) do
    case Regex.run(~r/^([A-Ga-g])([#b]?)(-?\d+)$/, String.trim(name)) do
      [_, letter, accidental, octave] ->
        base = Enum.find_index(@names, &(&1 == String.upcase(letter)))
        shift = %{"#" => 1, "b" => -1, "" => 0}[accidental]
        {:ok, (String.to_integer(octave) + 1) * 12 + base + shift}

      nil ->
        :error
    end
  end

  @doc "Frequency in Hz to a fractional MIDI number."
  def hz_to_midi(hz) when is_number(hz) and hz > 0, do: 69 + 12 * :math.log2(hz / 440)

  @doc "A (fractional) MIDI number to its frequency in Hz."
  def midi_to_hz(midi) when is_number(midi), do: 440 * :math.pow(2, (midi - 69) / 12)

  @doc "How far a fractional MIDI pitch is from a note, in cents (−50..50 for the nearest)."
  def cents(pitch, note) when is_number(pitch) and is_integer(note), do: (pitch - note) * 100

  @doc "True for C, D, E, F, G, A and B."
  def white_key?(midi) when is_integer(midi), do: Integer.mod(midi, 12) in [0, 2, 4, 5, 7, 9, 11]

  @doc "The lowest and highest notes of an 88-key piano (A0, C8)."
  def piano_range, do: 21..108
end
