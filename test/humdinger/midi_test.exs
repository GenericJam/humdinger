defmodule Humdinger.MidiTest do
  use ExUnit.Case, async: true

  alias Humdinger.Midi

  describe "encode/2" do
    test "note on puts the channel in the status nibble" do
      assert Midi.encode({:note_on, 69, 92}, 1) == <<0x90, 69, 92>>
      assert Midi.encode({:note_on, 69, 92}, 10) == <<0x99, 69, 92>>
      assert Midi.encode({:note_on, 69, 92}, 16) == <<0x9F, 69, 92>>
    end

    test "channels outside 1..16 are clamped" do
      assert Midi.encode({:note_on, 60, 100}, 0) == <<0x90, 60, 100>>
      assert Midi.encode({:note_on, 60, 100}, -3) == <<0x90, 60, 100>>
      assert Midi.encode({:note_on, 60, 100}, 17) == <<0x9F, 60, 100>>
    end

    test "note on keeps velocity in 1..127, so it never turns into a note off" do
      assert Midi.encode({:note_on, 60, 0}, 1) == <<0x90, 60, 1>>
      assert Midi.encode({:note_on, 60, 1}, 1) == <<0x90, 60, 1>>
      assert Midi.encode({:note_on, 60, 127}, 1) == <<0x90, 60, 127>>
      assert Midi.encode({:note_on, 60, 300}, 1) == <<0x90, 60, 127>>
    end

    test "notes are clamped to 0..127" do
      assert Midi.encode({:note_on, -1, 90}, 1) == <<0x90, 0, 90>>
      assert Midi.encode({:note_on, 128, 90}, 1) == <<0x90, 127, 90>>
      assert Midi.encode({:note_off, 200}, 1) == <<0x80, 127, 64>>
    end

    test "note off is 0x8n with release velocity 64" do
      assert Midi.encode({:note_off, 69}, 1) == <<0x80, 69, 64>>
      assert Midi.encode({:note_off, 69}, 16) == <<0x8F, 69, 64>>
    end

    test "pitch bend is 14 bits around 8192, LSB first" do
      assert Midi.encode({:pitch_bend, 0}, 1) == <<0xE0, 0x00, 0x40>>
      assert Midi.encode({:pitch_bend, 1}, 1) == <<0xE0, 0x01, 0x40>>
      assert Midi.encode({:pitch_bend, -1}, 1) == <<0xE0, 0x7F, 0x3F>>
      assert Midi.encode({:pitch_bend, -8192}, 1) == <<0xE0, 0x00, 0x00>>
      assert Midi.encode({:pitch_bend, 8191}, 1) == <<0xE0, 0x7F, 0x7F>>
      assert Midi.encode({:pitch_bend, 1024}, 2) == <<0xE1, 0x00, 0x48>>
    end

    test "pitch bend beyond its range is clamped" do
      assert Midi.encode({:pitch_bend, 9000}, 1) == <<0xE0, 0x7F, 0x7F>>
      assert Midi.encode({:pitch_bend, -9000}, 1) == <<0xE0, 0x00, 0x00>>
    end

    test "control change" do
      assert Midi.encode({:cc, 11, 80}, 1) == <<0xB0, 11, 80>>
      assert Midi.encode({:cc, 1, 40}, 16) == <<0xBF, 1, 40>>
      assert Midi.encode({:cc, 130, -5}, 1) == <<0xB0, 127, 0>>
    end
  end

  describe "describe/2" do
    test "the Output board's lines" do
      assert Midi.describe({:note_on, 69, 92}, 1) == "A4 on · vel 92 · ch 1"
      assert Midi.describe({:note_off, 69}, 1) == "A4 off · ch 1"
      assert Midi.describe({:pitch_bend, 1024}, 1) == "bend +1024 · ch 1"
      assert Midi.describe({:pitch_bend, -1234}, 3) == "bend -1234 · ch 3"
      assert Midi.describe({:pitch_bend, 0}, 1) == "bend 0 · ch 1"
      assert Midi.describe({:cc, 11, 80}, 1) == "CC 11 = 80 · ch 1"
      assert Midi.describe({:cc, 1, 40}, 16) == "CC 1 = 40 · ch 16"
      assert Midi.describe({:note_on, 61, 100}, 2) == "C#4 on · vel 100 · ch 2"
    end

    test "describes what was sent, clamped" do
      assert Midi.describe({:note_on, 69, 0}, 0) == "A4 on · vel 1 · ch 1"
      assert Midi.describe({:pitch_bend, 10_000}, 20) == "bend +8191 · ch 16"
      assert Midi.describe({:note_off, -4}, 1) == "C-1 off · ch 1"
    end
  end

  test "reset_controllers/1: bend centre, modulation 0, expression full" do
    assert Midi.reset_controllers(2) == [<<0xE1, 0x00, 0x40>>, <<0xB1, 1, 0>>, <<0xB1, 11, 127>>]
  end

  describe "all_notes_off/2" do
    test "CC 123 alone when no notes are known" do
      assert Midi.all_notes_off(1) == [<<0xB0, 123, 0>>]
      assert Midi.all_notes_off(16) == [<<0xBF, 123, 0>>]
    end

    test "a note off for each sounding note first, each note once" do
      assert Midi.all_notes_off(2, [60, 64, 60]) == [
               <<0x81, 60, 64>>,
               <<0x81, 64, 64>>,
               <<0xB1, 123, 0>>
             ]
    end
  end
end
