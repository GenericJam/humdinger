defmodule Humdinger.ExportTest do
  # Changes application env and MOB_DATA_DIR.
  use ExUnit.Case, async: false

  alias Humdinger.{Export, Phrase, Scale}
  alias Humdinger.Test.{FileShare, Listener}

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
    assert mid == Path.join(dir, "Bus stop riff.mid")
    assert <<"MThd", _::binary>> = File.read!(mid)

    assert {:ok, xml} = Export.write(phrase(), :musicxml, dir: dir, clef: :bass)
    assert Path.basename(xml) == "Bus stop riff.musicxml"
    assert File.read!(xml) =~ "<sign>F</sign>"

    assert {:ok, pdf} = Export.write(phrase(), :pdf, dir: dir, note_names: true)
    assert <<"%PDF-", _::binary>> = File.read!(pdf)
  end

  test "file names drop characters file systems refuse" do
    assert Export.file_name(phrase(~s(a/b\\c:d*e?"f"<g>|h)), :mid) == "abcdefgh.mid"
    assert Export.file_name(phrase("  ../.hidden  "), :pdf) == "hidden.pdf"
    assert Export.file_name(phrase("   "), :musicxml) == "phrase.musicxml"
    assert phrase(String.duplicate("x", 200)) |> Export.file_name(:mid) |> String.length() == 84
  end

  test "writing removes exports older than a day", %{tmp_dir: dir} do
    old = Path.join(dir, "old.mid")
    fresh = Path.join(dir, "fresh.pdf")
    File.write!(old, "x")
    File.write!(fresh, "x")
    File.touch!(old, System.os_time(:second) - 2 * 24 * 3600)

    {:ok, _} = Export.write(phrase(), :mid, dir: dir)
    refute File.exists?(old)
    assert File.exists?(fresh)
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

  test "sharing and printing need the native hook", %{tmp_dir: dir} do
    {:ok, pdf} = Export.write(phrase(), :pdf, dir: dir)
    {:ok, xml} = Export.write(phrase(), :musicxml, dir: dir)

    assert Export.share(pdf) == {:error, :unsupported}
    assert Export.print(pdf) == {:error, :unsupported}

    Listener.listen()
    Application.put_env(:humdinger, :file_share, FileShare)

    try do
      assert Export.share(xml) == :ok

      assert_received {:share, ^xml, "application/vnd.recordare.musicxml+xml",
                       "Bus stop riff.musicxml"}

      assert Export.print(pdf) == :ok
      assert_received {:print, ^pdf, "Bus stop riff"}
      assert_raise MatchError, fn -> Export.print(xml) end
    after
      Application.delete_env(:humdinger, :file_share)
    end
  end
end
