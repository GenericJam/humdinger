defmodule Humdinger.ExportTest do
  # Changes application env and MOB_DATA_DIR.
  use ExUnit.Case, async: false

  alias Humdinger.{Export, Phrase, Scale}
  alias Humdinger.Test.{Listener, Print}

  setup do
    dir = Path.join(System.tmp_dir!(), "humdinger-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  defp phrase(name \\ "Bus stop riff") do
    notes =
      for {m, i} <- Enum.with_index([62, 64, 65, 69]),
          do: %{start_ms: i * 625, dur_ms: 600, midi: m, velocity: 90, unsure: false}

    %Phrase{
      name: name,
      notes: notes,
      tempo_bpm: 96,
      scale: Scale.new("D", :dorian),
      quantize: :q8
    }
  end

  test "writes each kind under the phrase's name", %{tmp_dir: dir} do
    assert {:ok, mid} = Export.write(phrase(), :mid, dir: dir)
    assert Path.basename(mid) == "Bus stop riff.mid"
    assert Path.dirname(Path.dirname(mid)) == dir
    assert <<"MThd", _::binary>> = File.read!(mid)

    assert {:ok, xml} = Export.write(phrase(), :musicxml, dir: dir, clef: :bass)
    assert Path.basename(xml) == "Bus stop riff.musicxml"
    assert File.read!(xml) =~ "<sign>F</sign>"

    assert {:ok, pdf} = Export.write(phrase(), :pdf, dir: dir, note_names: true)
    assert <<"%PDF-", _::binary>> = File.read!(pdf)
  end

  test "two phrases with the same name export to distinct files", %{tmp_dir: dir} do
    low = %{
      phrase()
      | notes: [%{start_ms: 0, dur_ms: 500, midi: 40, velocity: 90, unsure: false}]
    }

    {:ok, first} = Export.write(phrase(), :mid, dir: dir)
    {:ok, second} = Export.write(low, :mid, dir: dir)

    assert first != second
    assert Path.basename(first) == Path.basename(second)
    assert File.read!(first) != File.read!(second)
    assert File.read!(first) == Export.render(phrase(), :mid, [])
  end

  test "file names drop characters file systems refuse" do
    assert Export.file_name(phrase(~s(a/b\\c:d*e?"f"<g>|h)), :mid) == "abcdefgh.mid"
    assert Export.file_name(phrase("  ../.hidden  "), :pdf) == "hidden.pdf"
    assert Export.file_name(phrase("   "), :musicxml) == "phrase.musicxml"
  end

  test "long names are cut to 200 bytes on a character boundary, extension included" do
    ascii = Export.file_name(phrase(String.duplicate("x", 300)), :musicxml)
    assert byte_size(ascii) == 200
    assert String.ends_with?(ascii, ".musicxml")

    # 4-byte emoji and a combining sequence: never split.
    for unit <- ["🎵", "e\u0301", "語"] do
      name = Export.file_name(phrase(String.duplicate(unit, 120)), :mid)
      assert byte_size(name) <= 200
      assert String.valid?(name)
      base = String.trim_trailing(name, ".mid")
      assert base == String.duplicate(unit, div(byte_size(base), byte_size(unit)))
    end
  end

  test "writing removes exports older than a day", %{tmp_dir: dir} do
    old = Path.join(dir, "1-1")
    fresh = Path.join(dir, "2-2")
    File.mkdir_p!(old)
    File.mkdir_p!(fresh)
    File.write!(Path.join(old, "old.mid"), "x")
    File.write!(Path.join(fresh, "fresh.pdf"), "x")
    File.touch!(old, System.os_time(:second) - 2 * 24 * 3600)

    {:ok, _} = Export.write(phrase(), :mid, dir: dir)
    refute File.exists?(old)
    assert File.exists?(Path.join(fresh, "fresh.pdf"))
  end

  test "on Android exports go to the cache directory next to files/" do
    previous = System.get_env("MOB_DATA_DIR")
    System.put_env("MOB_DATA_DIR", "/data/user/0/com.genericjam.humdinger/files")

    try do
      assert Export.dir() == "/data/user/0/com.genericjam.humdinger/cache/exports"
    after
      if previous,
        do: System.put_env("MOB_DATA_DIR", previous),
        else: System.delete_env("MOB_DATA_DIR")
    end
  end

  test "sharing forwards MIME and title through Mob.Share and returns socket; printing is PDF-only",
       %{tmp_dir: dir} do
    {:ok, pdf} = Export.write(phrase(), :pdf, dir: dir)
    {:ok, xml} = Export.write(phrase(), :musicxml, dir: dir)
    socket = %Mob.Socket{}

    Listener.listen()

    assert Export.share(socket, xml) == socket

    assert_received {:share, ^xml, "application/vnd.recordare.musicxml+xml",
                     "Bus stop riff.musicxml"}

    assert Export.share(socket, pdf, title: "Bus stop riff") == socket
    assert_received {:share, ^pdf, "application/pdf", "Bus stop riff"}

    assert Export.print(pdf) == :ok
    assert_received {:print, ^pdf, "Bus stop riff"}
    assert Export.print(pdf, title: "Custom title") == :ok
    assert_received {:print, ^pdf, "Custom title"}
    assert_raise MatchError, fn -> Export.print(xml) end

    Print.set_result({:error, :no_app})
    assert Export.print(pdf) == {:error, :no_app}
  end

  test "a name beyond the BMP reaches the share double intact, file and title", %{tmp_dir: dir} do
    name = "Hook 🎵𝄞 bird"
    {:ok, mid} = Export.write(phrase(name), :mid, dir: dir)
    assert Path.basename(mid) == name <> ".mid"
    assert File.exists?(mid)

    socket = %Mob.Socket{}
    Listener.listen()

    assert Export.share(socket, mid, title: name) == socket
    assert_received {:share, ^mid, "audio/midi", ^name}
  end
end
