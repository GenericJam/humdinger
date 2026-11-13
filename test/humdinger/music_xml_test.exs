# xmerl isn't one of the app's runtime applications (the phone's OTP may not
# ship it); the tests only need it for parsing.
Mix.ensure_application!(:xmerl)

defmodule Humdinger.MusicXmlTest do
  use ExUnit.Case, async: true

  require Record

  alias Humdinger.{MusicXml, Phrase, Scale}

  Record.defrecordp(
    :xml_element,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(:xml_text, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecordp(
    :xml_attribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  # Notes given as {start_beat, beats, midi} at 60 bpm.
  defp phrase(spec, fields \\ []) do
    notes =
      for {s, l, m} <- spec,
          do: %{
            start_ms: round(s * 1000),
            dur_ms: round(l * 1000),
            midi: m,
            velocity: 80,
            unsure: false
          }

    struct!(
      %Phrase{
        name: "Test",
        notes: notes,
        tempo_bpm: 60,
        scale: Scale.new("C", :major),
        quantize: :q8
      },
      fields
    )
  end

  defp board do
    spec =
      for {s, l, m} <- [
            {0, 2, 62},
            {2, 1, 64},
            {3, 1, 65},
            {4, 3, 69},
            {8, 2, 65},
            {10, 2, 64},
            {12, 2, 62},
            {14, 2, 60}
          ],
          do: {s / 2, l / 2, m}

    phrase(spec, name: "New phrase", tempo_bpm: 96, scale: Scale.new("D", :dorian)) |> rescale(96)
  end

  defp rescale(phrase, bpm) do
    k = 60 / bpm

    %{
      phrase
      | notes:
          Enum.map(
            phrase.notes,
            &%{&1 | start_ms: round(&1.start_ms * k), dur_ms: round(&1.dur_ms * k)}
          )
    }
  end

  defp parse(xml) do
    {doc, []} =
      xml
      |> String.to_charlist()
      |> :xmerl_scan.string(
        fetch_fun: fn _dtd, state -> {:ok, :not_fetched, state} end,
        quiet: true
      )

    doc
  end

  defp xpath(node, path), do: :xmerl_xpath.string(String.to_charlist(path), node)

  defp text(node, path) do
    case xpath(node, path) do
      [] -> nil
      [el | _] -> el |> xml_element(:content) |> Enum.map_join(&to_string(xml_text(&1, :value)))
    end
  end

  defp texts(node, path),
    do:
      node
      |> xpath(path)
      |> Enum.map(
        &(&1
          |> xml_element(:content)
          |> Enum.map_join(fn t -> to_string(xml_text(t, :value)) end))
      )

  defp attr(node, path),
    do: node |> xpath(path) |> Enum.map(&to_string(xml_attribute(&1, :value)))

  test "the board phrase as a MusicXML 4.0 partwise score" do
    xml = MusicXml.encode(board())
    assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"))
    doc = parse(xml)

    assert xml_element(doc, :name) == :"score-partwise"
    assert attr(doc, "/score-partwise/@version") == ["4.0"]
    assert text(doc, "//work-title") == "New phrase"
    assert text(doc, "//score-part/part-name") == "Voice"

    [m1, m2] = xpath(doc, "//part/measure")
    assert attr(m1, "@number") == ["1"]
    assert text(m1, "attributes/divisions") == "12"
    assert text(m1, "attributes/key/fifths") == "0"
    assert text(m1, "attributes/key/mode") == "dorian"

    assert {text(m1, "attributes/time/beats"), text(m1, "attributes/time/beat-type")} ==
             {"4", "4"}

    assert {text(m1, "attributes/clef/sign"), text(m1, "attributes/clef/line")} == {"G", "2"}
    assert text(m1, "direction/direction-type/metronome/per-minute") == "96"
    assert attr(m1, "direction/sound/@tempo") == ["96"]

    assert texts(m1, "note/duration") == ~w(12 6 6 18 6)
    assert texts(m1, "note/pitch/step") == ~w(D E F A)
    assert texts(m1, "note/type") == ~w(quarter eighth eighth quarter eighth)
    assert [_] = xpath(m1, "note/dot")
    assert [_] = xpath(m1, "note/rest")
    assert texts(m1, "note/beam") == ~w(begin end)
    assert texts(m1, "note/stem") == ~w(up up up up)

    assert texts(m2, "note/pitch/step") == ~w(F E D C)
    assert texts(m2, "note/duration") == ~w(12 12 12 12)
    assert text(m2, "barline/bar-style") == "light-heavy"
    assert xpath(m2, "attributes") == []
    assert xpath(doc, "//accidental") == []
  end

  test "ties over the barline, accidentals, stems down high up" do
    doc = phrase([{3, 2, 73}, {5, 1, 73}, {6, 2, 74}]) |> MusicXml.encode() |> parse()
    [m1, m2] = xpath(doc, "//part/measure")

    [tied] = xpath(m1, "note[pitch]")
    assert attr(tied, "tie/@type") == ["start"]
    assert attr(tied, "notations/tied/@type") == ["start"]
    assert text(tied, "accidental") == "sharp"
    assert text(tied, "pitch/alter") == "1"
    assert text(tied, "stem") == "down"

    [into, again, d] = xpath(m2, "note")
    assert attr(into, "tie/@type") == ["stop"]
    assert attr(into, "notations/tied/@type") == ["stop"]
    assert xpath(into, "accidental") == []
    assert text(again, "accidental") == "sharp"
    assert xpath(d, "pitch/alter") == []
  end

  test "triplets carry a time modification and a bracket per beat" do
    third = 1 / 3

    doc =
      phrase([{0, third, 60}, {third, third, 62}, {2 * third, third, 64}, {1, 3, 65}],
        quantize: :triplet
      )
      |> MusicXml.encode()
      |> parse()

    [m1] = xpath(doc, "//part/measure")

    assert texts(m1, "note/time-modification/actual-notes") == ~w(3 3 3)
    assert texts(m1, "note/time-modification/normal-notes") == ~w(2 2 2)
    assert attr(m1, "note/notations/tuplet/@type") == ~w(start stop)
    assert texts(m1, "note/duration") == ~w(4 4 4 12 24)
  end

  test "sixteenths get second beams and hooks" do
    spec = [
      {0, 0.25, 60},
      {0.25, 0.25, 62},
      {0.5, 0.25, 64},
      {0.75, 0.25, 65},
      {1, 0.75, 67},
      {1.75, 0.25, 65},
      {2, 2, 64}
    ]

    doc = phrase(spec, quantize: :q16) |> MusicXml.encode() |> parse()

    assert texts(doc, "//note/beam[@number='1']") == ~w(begin continue continue end begin end)

    assert texts(doc, "//note/beam[@number='2']") == [
             "begin",
             "continue",
             "continue",
             "end",
             "backward hook"
           ]
  end

  test "bass clef, flat key, whole-bar rests, escaped title" do
    phrase = phrase([{4, 4, 46}], scale: Scale.new("Bb", :major), name: ~s(Bass & "drone" <1>))
    xml = MusicXml.encode(phrase)
    doc = parse(xml)

    assert text(doc, "//work-title") == ~s(Bass & "drone" <1>)
    assert text(doc, "//clef/sign") == "F"
    assert text(doc, "//clef/line") == "4"
    assert text(doc, "//key/fifths") == "-2"
    assert attr(doc, "//measure[@number='1']/note/rest/@measure") == ["yes"]
    assert text(doc, "//measure[@number='2']/note/pitch/step") == "B"
    assert text(doc, "//measure[@number='2']/note/pitch/alter") == "-1"
    assert xpath(doc, "//accidental") == []
  end

  test "open phrases have no mode; options pass to the layout" do
    phrase = phrase([{0, 0.5, 72}, {0.5, 0.5, 74}], scale: nil)
    doc = phrase |> MusicXml.encode(clef: :bass, rhythm: :simpler) |> parse()

    assert xpath(doc, "//key/mode") == []
    assert text(doc, "//clef/sign") == "F"
    assert texts(doc, "//note/type") |> Enum.all?(&(&1 in ~w(quarter half whole)))
  end
end
