defmodule Humdinger.MusicXml do
  @moduledoc """
  A phrase as MusicXML 4.0 (partwise), for notation apps (MuseScore,
  Dorico, Sibelius, Finale). It is written from the same
  `Humdinger.Notation.layout/2` as the staff view and the PDF, so what the
  singer saw is what the other app opens: clef, key, 4/4, the tempo as a
  metronome mark, notes and rests with ties, beams, triplets and printed
  accidentals. One part ("Voice"), 12 divisions per quarter note.
  """

  alias Humdinger.{Notation, Phrase}

  @divisions 12
  @base %{whole: 48, half: 24, quarter: 12, eighth: 6, sixteenth: 3}
  @modes %{
    major: "major",
    minor: "minor",
    harmonic_minor: "minor",
    dorian: "dorian",
    phrygian: "phrygian",
    lydian: "lydian",
    mixolydian: "mixolydian",
    locrian: "locrian"
  }

  @doc """
  The phrase as a MusicXML document. Options are `Notation.layout/2`'s:
  `clef:` (default `:auto`) and `rhythm:` (default `:as_sung`).
  """
  @spec encode(Phrase.t(), keyword()) :: String.t()
  def encode(%Phrase{} = phrase, opts \\ []) do
    layout =
      Notation.layout(phrase,
        clef: Keyword.get(opts, :clef, :auto),
        rhythm: Keyword.get(opts, :rhythm, :as_sung)
      )

    last = length(layout.measures) - 1

    {measures, _tied} =
      Enum.map_reduce(layout.measures, false, fn m, tied ->
        {notes, tied} = notes(m.items, tied)

        head =
          if m.index == 0, do: [attributes(layout, phrase), tempo(phrase.tempo_bpm)], else: []

        tail =
          if m.index == last,
            do: ~s(<barline location="right"><bar-style>light-heavy</bar-style></barline>),
            else: []

        {[~s(<measure number="#{m.index + 1}">), head, notes, tail, "</measure>"], tied}
      end)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n),
      ~s(<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">\n),
      ~s(<score-partwise version="4.0">),
      "<work><work-title>",
      escape(phrase.name),
      "</work-title></work>",
      identification(phrase),
      ~s(<part-list><score-part id="P1"><part-name>Voice</part-name></score-part></part-list>),
      ~s(<part id="P1">),
      measures,
      "</part></score-partwise>\n"
    ])
  end

  defp identification(phrase) do
    date =
      case phrase.updated_at || phrase.created_at do
        nil -> []
        at -> ["<encoding-date>", Date.to_iso8601(DateTime.to_date(at)), "</encoding-date>"]
      end

    [
      "<identification><encoding><software>Humdinger</software>",
      date,
      "</encoding></identification>"
    ]
  end

  defp attributes(layout, phrase) do
    mode =
      case phrase.scale && Map.get(@modes, phrase.scale.mode) do
        nil -> []
        mode -> ["<mode>", mode, "</mode>"]
      end

    {sign, line} = if layout.clef == :treble, do: {"G", 2}, else: {"F", 4}

    [
      "<attributes><divisions>#{@divisions}</divisions>",
      "<key><fifths>#{layout.key_fifths}</fifths>",
      mode,
      "</key><time><beats>4</beats><beat-type>4</beat-type></time>",
      "<clef><sign>#{sign}</sign><line>#{line}</line></clef></attributes>"
    ]
  end

  defp tempo(bpm) do
    ~s(<direction placement="above"><direction-type><metronome><beat-unit>quarter</beat-unit>) <>
      ~s(<per-minute>#{bpm}</per-minute></metronome></direction-type><sound tempo="#{bpm}"/></direction>)
  end

  # `tied` says whether the previous note (maybe in the previous measure) is
  # tied into the first one here.
  defp notes(items, tied) do
    stems = stems(items)
    tuplets = tuplet_marks(items)
    beams2 = secondary_beams(items)

    items
    |> Enum.with_index()
    |> Enum.map_reduce(tied, fn {item, i}, tied_in ->
      xml = note(item, tied_in, Map.get(stems, i), Map.get(tuplets, i), Map.get(beams2, i))
      {xml, item.kind == :note and item.tie_to_next}
    end)
  end

  defp note(%{kind: :rest} = item, _tied_in, _stem, tuplet, _beam2) do
    rest =
      if item.type == :whole and item.beat == 0.0, do: ~s(<rest measure="yes"/>), else: "<rest/>"

    [
      "<note>",
      rest,
      duration(item),
      "<voice>1</voice>",
      type(item),
      time_modification(item),
      notations([], tuplet),
      "</note>"
    ]
  end

  defp note(item, tied_in, stem, tuplet, beam2) do
    alter = if item.alter != 0, do: "<alter>#{item.alter}</alter>", else: []

    ties = [
      if(tied_in, do: ~s(<tie type="stop"/>), else: []),
      if(item.tie_to_next, do: ~s(<tie type="start"/>), else: [])
    ]

    tied = [
      if(tied_in, do: ~s(<tied type="stop"/>), else: []),
      if(item.tie_to_next, do: ~s(<tied type="start"/>), else: [])
    ]

    [
      "<note><pitch><step>#{item.step}</step>",
      alter,
      "<octave>#{item.octave}</octave></pitch>",
      duration(item),
      ties,
      "<voice>1</voice>",
      type(item),
      accidental(item.accidental),
      time_modification(item),
      if(stem, do: "<stem>#{stem}</stem>", else: []),
      beams(item.beam, beam2),
      notations(tied, tuplet),
      "</note>"
    ]
  end

  defp duration(item), do: "<duration>#{ticks(item)}</duration>"

  @doc "An item's length in divisions (12 to the quarter note)."
  def ticks(item) do
    base = Map.fetch!(@base, item.type)
    base = if item.dots == 1, do: div(base * 3, 2), else: base
    if item.tuplet, do: div(base * 2, 3), else: base
  end

  defp type(item), do: ["<type>#{item.type}</type>", if(item.dots == 1, do: "<dot/>", else: [])]

  defp accidental(nil), do: []
  defp accidental(acc), do: "<accidental>#{acc}</accidental>"

  defp time_modification(%{tuplet: {actual, normal}}),
    do:
      "<time-modification><actual-notes>#{actual}</actual-notes><normal-notes>#{normal}</normal-notes></time-modification>"

  defp time_modification(_item), do: []

  defp beams(nil, _beam2), do: []

  defp beams(beam, beam2) do
    [
      ~s(<beam number="1">#{beam}</beam>),
      if(beam2, do: ~s(<beam number="2">#{beam2}</beam>), else: [])
    ]
  end

  defp notations([], nil), do: []

  defp notations(tied, tuplet) do
    tuplet_xml = if tuplet, do: ~s(<tuplet type="#{tuplet}" bracket="yes"/>), else: []
    ["<notations>", tied, tuplet_xml, "</notations>"]
  end

  # Stems: down from the middle line up, up below it; a beamed group follows
  # its note farthest from the middle line. Whole notes have none.
  defp stems(items) do
    indexed = Enum.with_index(items)

    groups =
      indexed
      |> Enum.filter(fn {i, _} -> i.kind == :note and i.type != :whole end)
      |> Enum.chunk_while(
        [],
        fn {item, _} = x, acc ->
          case item.beam do
            b when b in [:begin, nil] and acc != [] -> {:cont, Enum.reverse(acc), [x]}
            _ -> {:cont, [x | acc]}
          end
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    for group <- groups, {_item, i} <- group, into: %{} do
      far = group |> Enum.map(fn {item, _} -> item.staff_pos end) |> Enum.max_by(&abs/1)
      {i, if(far >= 0, do: "down", else: "up")}
    end
  end

  defp tuplet_marks(items) do
    items
    |> Enum.with_index()
    |> Enum.filter(fn {item, _} -> item.tuplet end)
    |> Enum.chunk_by(fn {item, _} -> trunc(item.beat) end)
    |> Enum.flat_map(fn group ->
      {_, first} = List.first(group)
      {_, last} = List.last(group)
      [{first, "start"}, {last, "stop"}]
    end)
    |> Map.new()
  end

  # Second beams for sixteenths inside a beamed group: runs of sixteenths
  # share one; a lone sixteenth gets a hook toward its neighbour.
  defp secondary_beams(items) do
    items
    |> Enum.with_index()
    |> Enum.filter(fn {item, _} -> item.beam end)
    |> Enum.chunk_while(
      [],
      fn {item, _} = x, acc ->
        if item.beam == :end, do: {:cont, Enum.reverse([x | acc]), []}, else: {:cont, [x | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.flat_map(&group_secondary/1)
    |> Map.new()
  end

  defp group_secondary(group) do
    last = length(group) - 1

    group
    |> Enum.with_index()
    |> Enum.chunk_by(fn {{item, _}, _} -> item.type == :sixteenth end)
    |> Enum.flat_map(fn
      [{{%{type: :sixteenth}, i}, pos}] ->
        [{i, if(pos == last, do: "backward hook", else: "forward hook")}]

      [{{%{type: :sixteenth}, _}, _} | _] = run ->
        n = length(run) - 1

        run
        |> Enum.with_index()
        |> Enum.map(fn {{{_, i}, _}, k} ->
          {i,
           cond do
             k == 0 -> "begin"
             k == n -> "end"
             true -> "continue"
           end}
        end)

      _ ->
        []
    end)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
