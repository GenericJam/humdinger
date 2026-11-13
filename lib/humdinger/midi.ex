defmodule Humdinger.Midi do
  @moduledoc """
  Humdinger's MIDI events as MIDI 1.0 bytes, and as the short line the Output
  board shows ("A4 on · vel 92 · ch 1").

  Events carry no channel (see `Humdinger.Tracker`). The channel is given as
  people count it, 1..16, and goes on the wire as the status byte's low
  nibble, 0..15. Values out of range are clamped rather than rejected: a
  stray value must not crash the real-time path.

  * `{:note_on, note, velocity}` → `9n note velocity`. Velocity is clamped to
    1..127: on the wire a note-on with velocity 0 means note-off, and Output's
    sounding-note bookkeeping relies on a note-on staying one.
  * `{:note_off, note}` → `8n note 64`. 64 is the release velocity the MIDI
    spec recommends when there is none to report; synths that ignore release
    velocity don't care, and those that use it get a neutral release.
  * `{:pitch_bend, value}` (−8192..8191, 0 = centre) → `En lsb msb`, the
    value offset by 8192 as 14 bits.
  * `{:cc, number, value}` → `Bn number value`.
  """

  import Bitwise

  @type channel :: 1..16
  @type event ::
          {:note_on, integer(), integer()}
          | {:note_off, integer()}
          | {:pitch_bend, integer()}
          | {:cc, integer(), integer()}

  @note_off_velocity 64

  @doc "The bytes of one event on `channel`."
  @spec encode(event(), integer()) :: binary()
  def encode({:note_on, note, velocity}, channel),
    do: <<0x90 ||| status_channel(channel), byte7(note), clamp(velocity, 1, 127)>>

  def encode({:note_off, note}, channel),
    do: <<0x80 ||| status_channel(channel), byte7(note), @note_off_velocity>>

  def encode({:pitch_bend, value}, channel) do
    raw = clamp(value, -8192, 8191) + 8192
    <<0xE0 ||| status_channel(channel), raw &&& 0x7F, raw >>> 7>>
  end

  def encode({:cc, number, value}, channel),
    do: <<0xB0 ||| status_channel(channel), byte7(number), byte7(value)>>

  @doc """
  The Output board's line for an event: `"A4 on · vel 92 · ch 1"`,
  `"A4 off · ch 1"`, `"bend +1024 · ch 1"`, `"CC 11 = 80 · ch 1"`. Values are
  clamped as `encode/2` clamps them, so the line says what went out.
  """
  @spec describe(event(), integer()) :: String.t()
  def describe({:note_on, note, velocity}, channel),
    do: "#{note_name(note)} on · vel #{clamp(velocity, 1, 127)} · #{ch(channel)}"

  def describe({:note_off, note}, channel), do: "#{note_name(note)} off · #{ch(channel)}"

  def describe({:pitch_bend, value}, channel) do
    value = clamp(value, -8192, 8191)
    sign = if value > 0, do: "+", else: ""
    "bend #{sign}#{value} · #{ch(channel)}"
  end

  def describe({:cc, number, value}, channel),
    do: "CC #{byte7(number)} = #{byte7(value)} · #{ch(channel)}"

  @doc """
  Silences `channel`: a note-off for each of `notes`, then CC 123 (All Notes
  Off). One binary per message, in sending order. The explicit note-offs are
  there because CC 123 is optional for a receiver: some synths ignore it.
  """
  @spec all_notes_off(integer(), [integer()]) :: [binary()]
  def all_notes_off(channel, notes \\ []) do
    offs = for note <- Enum.uniq(notes), do: encode({:note_off, note}, channel)
    offs ++ [encode({:cc, 123, 0}, channel)]
  end

  @doc "The channel clamped to 1..16."
  @spec channel(integer()) :: channel()
  def channel(channel), do: clamp(channel, 1, 16)

  defp status_channel(channel), do: channel(channel) - 1
  defp ch(channel), do: "ch #{channel(channel)}"
  defp note_name(note), do: Humdinger.Music.note_name(byte7(note))
  defp byte7(value), do: clamp(value, 0, 127)
  defp clamp(value, low, high) when is_integer(value), do: value |> max(low) |> min(high)
end
