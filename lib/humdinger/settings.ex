defmodule Humdinger.Settings do
  @moduledoc """
  The singer's saved preferences: how Humdinger listens, how it turns the
  voice into notes, and where the notes go. Kept in `Mob.State` under
  `:settings`, so they survive restarts.

  Saved as a plain map of plain terms (the scale as `{root, mode}`), not
  as the struct: `load/0` builds the struct from the defaults and takes
  each saved field that is still known and still valid, so settings saved
  by an older or newer version load without crashing. Unknown keys are
  dropped, invalid values fall back to their defaults.

  Fields (defaults from the Settings and Live boards):

  - `sensitivity_db` — the voicing gate in dBFS: readings below it count
    as room noise. −55, within `sensitivity_range/0`.
  - `response` — `:fast | :balanced | :steady` (`Humdinger.Tracker.response_ms/1`).
  - `pitch_change` — `:legato` (new note on, then old note off) or `:new_note`.
  - `on_stop` — `:hold` (keep the note 250 ms over a breath) or `:note_off`.
  - `bend_range` — semitones of pitch bend in Open mode: 1, 2, 7 or 12.
  - `velocity_from_loudness`, `cc11_from_loudness`, `cc1_from_vibrato`.
  - `mode` — `:scale` (snap to `scale`) or `:open` (nearest note + bend).
  - `scale` — a `Humdinger.Scale`, D Dorian.
  - `octave` (−3..3), `transpose` (−12..12) — added to the sent note.
  - `channel` — MIDI channel 1..16.
  - `destinations` — `%{fmutate:, port:, usb:, bt:}` booleans.
  - `range` — the singer's `{low, high}` MIDI range from First run, or nil.
  - `first_run_done`.
  """

  alias Humdinger.Scale

  @key :settings
  @sensitivity_range {-70.0, -20.0}
  @bend_ranges [1, 2, 7, 12]

  defstruct sensitivity_db: -55.0,
            response: :balanced,
            pitch_change: :legato,
            on_stop: :hold,
            bend_range: 2,
            velocity_from_loudness: true,
            cc11_from_loudness: true,
            cc1_from_vibrato: false,
            mode: :scale,
            scale: %Scale{root: 2, mode: :dorian},
            octave: 0,
            transpose: 0,
            channel: 1,
            destinations: %{fmutate: true, port: true, usb: false, bt: false},
            range: nil,
            first_run_done: false

  @type t :: %__MODULE__{
          sensitivity_db: float(),
          response: :fast | :balanced | :steady,
          pitch_change: :legato | :new_note,
          on_stop: :note_off | :hold,
          bend_range: 1 | 2 | 7 | 12,
          velocity_from_loudness: boolean(),
          cc11_from_loudness: boolean(),
          cc1_from_vibrato: boolean(),
          mode: :scale | :open,
          scale: Scale.t(),
          octave: -3..3,
          transpose: -12..12,
          channel: 1..16,
          destinations: %{fmutate: boolean(), port: boolean(), usb: boolean(), bt: boolean()},
          range: {0..127, 0..127} | nil,
          first_run_done: boolean()
        }

  @type change :: map() | keyword() | (t() -> t())

  @doc "The defaults."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "The span of the Sensitivity slider, in dBFS."
  @spec sensitivity_range() :: {float(), float()}
  def sensitivity_range, do: @sensitivity_range

  @doc "The bend ranges the Settings sheet offers, in semitones."
  @spec bend_ranges() :: [pos_integer()]
  def bend_ranges, do: @bend_ranges

  @doc "The saved settings, or the defaults where nothing (valid) was saved."
  @spec load() :: t()
  def load, do: decode(Mob.State.get(@key))

  @doc "Save settings."
  @spec save(t()) :: :ok
  def save(%__MODULE__{} = settings), do: Mob.State.put(@key, encode(settings))

  @doc """
  Load, apply a change (a map or keyword list of fields, or a function of
  the settings), validate and save. Returns the saved settings, or
  `{:error, {:invalid, field}}` and saves nothing.
  """
  @spec update(change()) :: {:ok, t()} | {:error, {:invalid, atom()}}
  def update(change) do
    with {:ok, settings} <- merge(load(), change) do
      :ok = save(settings)
      {:ok, settings}
    end
  end

  @doc """
  Apply a change to settings without saving, as `update/1` does. A field
  that doesn't exist or a value out of range is `{:error, {:invalid, field}}`.
  `destinations` merges into the current ones.
  """
  @spec merge(t(), change()) :: {:ok, t()} | {:error, {:invalid, atom()}}
  def merge(%__MODULE__{} = settings, change) when is_function(change, 1) do
    case change.(settings) do
      %__MODULE__{} = changed -> validate(changed)
      _other -> {:error, {:invalid, :settings}}
    end
  end

  def merge(%__MODULE__{} = settings, change) when is_list(change) or is_map(change) do
    Enum.reduce_while(change, {:ok, settings}, fn {field, value}, {:ok, acc} ->
      case put_field(acc, field, value) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, {:error, {:invalid, field}}}
      end
    end)
  end

  @doc "Settings from a saved term, tolerating missing, unknown and invalid fields."
  @spec decode(term()) :: t()
  def decode(saved) when is_struct(saved), do: saved |> Map.from_struct() |> decode()

  def decode(saved) when is_map(saved) do
    Enum.reduce(saved, defaults(), fn {field, value}, acc ->
      case put_field(acc, field, decode_value(field, value)) do
        {:ok, acc} -> acc
        :error -> acc
      end
    end)
  end

  def decode(_saved), do: defaults()

  @doc "The term `save/1` stores: a plain map, the scale as `{root, mode}`."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{scale: %Scale{root: root, mode: mode}} = settings) do
    settings |> Map.from_struct() |> Map.put(:scale, {root, mode})
  end

  defp decode_value(:scale, {root, mode}) when is_integer(root) and is_atom(mode),
    do: %Scale{root: root, mode: mode}

  defp decode_value(_field, value), do: value

  defp validate(%__MODULE__{} = settings) do
    settings |> Map.from_struct() |> then(&merge(defaults(), &1))
  end

  defp put_field(settings, field, value) do
    if valid?(field, value) do
      {:ok, Map.put(settings, field, normalize(settings, field, value))}
    else
      :error
    end
  end

  defp normalize(_settings, :sensitivity_db, db), do: db / 1

  defp normalize(settings, :destinations, dests),
    do: Map.merge(settings.destinations, Map.new(dests))

  defp normalize(_settings, _field, value), do: value

  defp valid?(:sensitivity_db, db) do
    {low, high} = @sensitivity_range
    is_number(db) and db >= low and db <= high
  end

  defp valid?(:response, v), do: v in [:fast, :balanced, :steady]
  defp valid?(:pitch_change, v), do: v in [:legato, :new_note]
  defp valid?(:on_stop, v), do: v in [:note_off, :hold]
  defp valid?(:bend_range, v), do: v in @bend_ranges
  defp valid?(:velocity_from_loudness, v), do: is_boolean(v)
  defp valid?(:cc11_from_loudness, v), do: is_boolean(v)
  defp valid?(:cc1_from_vibrato, v), do: is_boolean(v)
  defp valid?(:mode, v), do: v in [:scale, :open]

  defp valid?(:scale, %Scale{root: root, mode: mode}),
    do: is_integer(root) and root in 0..11 and mode in Scale.modes()

  defp valid?(:octave, v), do: is_integer(v) and v in -3..3
  defp valid?(:transpose, v), do: is_integer(v) and v in -12..12
  defp valid?(:channel, v), do: is_integer(v) and v in 1..16

  defp valid?(:destinations, dests) when is_map(dests) or is_list(dests) do
    Enum.all?(dests, fn {id, on} -> id in [:fmutate, :port, :usb, :bt] and is_boolean(on) end)
  end

  defp valid?(:range, nil), do: true

  defp valid?(:range, {low, high}),
    do: is_integer(low) and is_integer(high) and low in 0..127 and high in 0..127 and low <= high

  defp valid?(:first_run_done, v), do: is_boolean(v)
  defp valid?(_field, _value), do: false
end
