defmodule Humdinger.SmfTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Phrase, Scale, Smf}

  defp note(start, dur, midi, velocity \\ 80),
    do: %{start_ms: start, dur_ms: dur, midi: midi, velocity: velocity, unsure: false}

  test "a small phrase, byte for byte" do
    # 120 bpm: an eighth is 250 ms = 240 ticks.
    phrase = %Phrase{
      name: "Hi",
      tempo_bpm: 120,
      scale: Scale.new("C", :major),
      quantize: :q8,
      notes: [note(10, 230, 60), note(495, 520, 64, 100), note(4510, 200, 67)]
    }

    track =
      <<0x00, 0xFF, 0x03, 0x02, "Hi">> <>
        <<0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20>> <>
        <<0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08>> <>
        <<0x00, 0xFF, 0x59, 0x02, 0x00, 0x00>> <>
        <<0x00, 0x90, 60, 80>> <>
        <<0x81, 0x70, 0x80, 60, 0>> <>
        <<0x81, 0x70, 0x90, 64, 100>> <>
        <<0x83, 0x60, 0x80, 64, 0>> <>
        <<0x9A, 0x20, 0x90, 67, 80>> <>
        <<0x81, 0x70, 0x80, 67, 0>> <>
        <<0x00, 0xFF, 0x2F, 0x00>>

    assert Smf.encode(phrase) ==
             <<"MThd", 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, "MTrk", byte_size(track)::32>> <> track
  end

  test "variable-length quantities" do
    assert Smf.vlq(0) == <<0x00>>
    assert Smf.vlq(0x7F) == <<0x7F>>
    assert Smf.vlq(0x80) == <<0x81, 0x00>>
    assert Smf.vlq(0x2000) == <<0xC0, 0x00>>
    assert Smf.vlq(0x3FFF) == <<0xFF, 0x7F>>
    assert Smf.vlq(0x4000) == <<0x81, 0x80, 0x00>>
    assert Smf.vlq(0x0FFFFFFF) == <<0xFF, 0xFF, 0xFF, 0x7F>>
    assert_raise FunctionClauseError, fn -> Smf.vlq(0x10000000) end
  end

  test "key signature: minor flag, flats, none for open or chromatic phrases" do
    base = %Phrase{name: "k", tempo_bpm: 100, notes: [note(0, 500, 64)]}

    assert :binary.match(
             Smf.encode(%{base | scale: Scale.new("E", :minor)}),
             <<0xFF, 0x59, 2, 1, 1>>
           ) != :nomatch

    assert :binary.match(
             Smf.encode(%{base | scale: Scale.new("Bb", :major)}),
             <<0xFF, 0x59, 2, 0xFE, 0>>
           ) != :nomatch

    assert :binary.match(Smf.encode(%{base | scale: nil}), <<0xFF, 0x59>>) == :nomatch

    assert :binary.match(Smf.encode(%{base | scale: Scale.chromatic()}), <<0xFF, 0x59>>) ==
             :nomatch
  end

  test "unquantized notes keep their sung timing in ticks" do
    # 60 bpm: 1 ms = 0.48 ticks.
    phrase = %Phrase{
      name: "",
      tempo_bpm: 60,
      quantize: :off,
      notes: [note(100, 333, 60), note(1000, 1000, 62)]
    }

    events = phrase |> Smf.encode() |> parse() |> Enum.filter(&match?({_, {:note, _, _, _}}, &1))

    assert events == [
             {48, {:note, :on, 60, 80}},
             {208, {:note, :off, 60, 0}},
             {480, {:note, :on, 62, 80}},
             {960, {:note, :off, 62, 0}}
           ]
  end

  test "parses back: tempo, names, every grid note on and off" do
    phrase = %Phrase{
      name: "Bus stop riff",
      tempo_bpm: 96,
      quantize: :triplet,
      notes: for(i <- 0..11, do: note(round(i * 625 / 3), 200, 60 + i))
    }

    events = phrase |> Smf.encode() |> parse()

    assert {0, {:meta, 0x03, "Bus stop riff"}} in events
    assert {0, {:meta, 0x51, <<625_000::24>>}} in events
    assert List.last(events) == {12 * 160, {:meta, 0x2F, ""}}

    ons = for {t, {:note, :on, m, _}} <- events, do: {t, m}
    assert ons == for(i <- 0..11, do: {i * 160, 60 + i})
  end

  # A minimal SMF reader for format-0 files: [{abs_tick, event}].
  defp parse(<<"MThd", 6::32, 0::16, 1::16, 480::16, "MTrk", len::32, track::binary-size(len)>>),
    do: events(track, 0, [])

  defp events(<<>>, _t, acc), do: Enum.reverse(acc)

  defp events(bin, t, acc) do
    {delta, rest} = read_vlq(bin, 0)
    t = t + delta

    case rest do
      <<0xFF, type, rest::binary>> ->
        {len, rest} = read_vlq(rest, 0)
        <<data::binary-size(^len), rest::binary>> = rest
        events(rest, t, [{t, {:meta, type, data}} | acc])

      <<0x90, m, v, rest::binary>> ->
        events(rest, t, [{t, {:note, :on, m, v}} | acc])

      <<0x80, m, v, rest::binary>> ->
        events(rest, t, [{t, {:note, :off, m, v}} | acc])
    end
  end

  defp read_vlq(<<1::1, b::7, rest::binary>>, acc), do: read_vlq(rest, acc * 128 + b)
  defp read_vlq(<<0::1, b::7, rest::binary>>, acc), do: {acc * 128 + b, rest}
end
