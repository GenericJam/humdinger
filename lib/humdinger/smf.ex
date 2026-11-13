defmodule Humdinger.Smf do
  @moduledoc """
  A phrase as a Standard MIDI File ("Export .mid"): format 0, one track,
  480 ticks per quarter note, on MIDI channel 1.

  The track holds, at tick 0, the phrase name (track name), its tempo, a 4/4
  time signature and, when the phrase has a key, the key signature; then the
  phrase's notes on its grid (`Humdinger.Phrase.quantized_notes/1`), and End
  of Track. Grid notes are converted in whole grid steps, so they land on
  exact ticks; unquantized notes are converted from ms at the phrase tempo.
  """

  alias Humdinger.{Phrase, Scale}
  import Bitwise

  @ppq 480
  @minor_modes [:minor, :harmonic_minor, :minor_pentatonic, :blues]

  @doc "Ticks per quarter note."
  def ppq, do: @ppq

  @doc "The phrase as `.mid` file bytes."
  @spec encode(Phrase.t()) :: binary()
  def encode(%Phrase{} = phrase) do
    track = IO.iodata_to_binary([meta_events(phrase), note_events(phrase), <<0, 0xFF, 0x2F, 0>>])

    <<"MThd", 6::32, 0::16, 1::16, @ppq::16, "MTrk", byte_size(track)::32, track::binary>>
  end

  defp meta_events(phrase) do
    tempo = round(60_000_000 / phrase.tempo_bpm)

    [
      meta(0x03, phrase.name),
      meta(0x51, <<tempo::24>>),
      meta(0x58, <<4, 2, 24, 8>>),
      key_signature(phrase.scale)
    ]
  end

  defp key_signature(nil), do: []
  defp key_signature(%Scale{mode: :chromatic}), do: []

  defp key_signature(%Scale{mode: mode} = scale) do
    meta(0x59, <<Scale.key_fifths(scale)::signed-8, if(mode in @minor_modes, do: 1, else: 0)>>)
  end

  defp meta(type, data), do: [0, 0xFF, type, vlq(byte_size(data)), data]

  defp note_events(phrase) do
    phrase
    |> tick_notes()
    |> Enum.flat_map(fn {on, off, n} ->
      [{on, 1, <<0x90, n.midi, n.velocity>>}, {off, 0, <<0x80, n.midi, 0>>}]
    end)
    # Note-offs before note-ons at the same tick.
    |> Enum.sort_by(fn {tick, order, _} -> {tick, order} end)
    |> Enum.map_reduce(0, fn {tick, _order, event}, last -> {[vlq(tick - last), event], tick} end)
    |> elem(0)
  end

  defp tick_notes(%Phrase{quantize: :off} = phrase) do
    per_ms = @ppq / Phrase.beat_ms(phrase.tempo_bpm)

    for n <- Phrase.quantized_notes(phrase) do
      on = round(n.start_ms * per_ms)
      {on, max(round((n.start_ms + n.dur_ms) * per_ms), on + 1), n}
    end
  end

  defp tick_notes(%Phrase{quantize: q} = phrase) do
    per_step = div(@ppq, Phrase.steps_per_beat(q))

    for g <- Phrase.grid_notes(phrase.notes, phrase.tempo_bpm, q),
        do: {g.start * per_step, g.stop * per_step, g}
  end

  @doc "A MIDI variable-length quantity: 7 bits per byte, most significant first."
  @spec vlq(non_neg_integer()) :: binary()
  def vlq(n) when is_integer(n) and n >= 0 and n < 0x80, do: <<n>>

  def vlq(n) when is_integer(n) and n >= 0 and n <= 0x0FFFFFFF do
    vlq_bytes(n >>> 7, <<n &&& 0x7F>>)
  end

  defp vlq_bytes(0, acc), do: acc
  defp vlq_bytes(n, acc), do: vlq_bytes(n >>> 7, <<1::1, n &&& 0x7F::7, acc::binary>>)
end
