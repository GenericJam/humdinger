defmodule Humdinger.PhrasesTest do
  # One in-memory SQLite connection shared by the module.
  use ExUnit.Case, async: false

  alias Humdinger.{Phrase, Phrases, Repo, Scale}

  setup_all do
    Humdinger.Test.Repo.start()
  end

  setup do
    Repo.delete_all(Phrases.Row)
    :ok
  end

  defp phrase(fields \\ []) do
    notes = [
      %{start_ms: 0, dur_ms: 600, midi: 62, velocity: 90, unsure: false},
      %{start_ms: 625, dur_ms: 300, midi: 64, velocity: 101, unsure: true}
    ]

    trace = for t <- 0..900//10, do: {t, if(t in 300..340, do: nil, else: 62 + t / 1000)}

    struct!(
      %Phrase{
        name: "Bus stop riff",
        notes: notes,
        trace: trace,
        duration_ms: 950,
        tempo_bpm: 96,
        tempo_detected: true,
        scale: Scale.new("D", :dorian),
        quantize: :q16,
        source: :hum,
        created_at: ~U[2026-11-10 09:00:00Z]
      },
      fields
    )
  end

  test "save/1 inserts, get/1 returns the same phrase" do
    assert {:ok, saved} = Phrases.save(phrase())
    assert is_integer(saved.id)
    assert saved.created_at == ~U[2026-11-10 09:00:00Z]
    assert DateTime.diff(DateTime.utc_now(), saved.updated_at) in 0..5

    got = Phrases.get(saved.id)
    assert got == saved

    for field <- [
          :name,
          :notes,
          :duration_ms,
          :tempo_bpm,
          :tempo_detected,
          :scale,
          :quantize,
          :source
        ] do
      assert Map.fetch!(got, field) == Map.fetch!(phrase(), field)
    end
  end

  test "the trace is thinned to 20 ms, keeping voicing changes, pitch to a cent" do
    {:ok, saved} = Phrases.save(phrase())

    times = Enum.map(saved.trace, &elem(&1, 0))
    assert times == Enum.sort(times)
    assert {300, nil} in saved.trace
    assert {350, _} = Enum.find(saved.trace, fn {t, p} -> t > 300 and p end)

    for [{t1, p1}, {t2, p2}] <- Enum.chunk_every(saved.trace, 2, 1, :discard),
        not is_nil(p1) == not is_nil(p2) do
      assert t2 - t1 >= 20
    end

    for {t, p} <- saved.trace, p, do: assert_in_delta(p, 62 + t / 1000, 0.005)
  end

  test "open phrases, imported files and every quantize setting round-trip" do
    for q <- Phrase.quantizes(), scale <- [nil, Scale.chromatic(), Scale.new("Bb", :blues)] do
      {:ok, saved} =
        Phrases.save(phrase(scale: scale, quantize: q, source: {:file, "voice-memo-0412.m4a"}))

      assert %Phrase{scale: ^scale, quantize: ^q, source: {:file, "voice-memo-0412.m4a"}} =
               Phrases.get(saved.id)
    end
  end

  test "list/0 is newest first and leaves out the trace" do
    {:ok, older} = Phrases.save(phrase(name: "Older", created_at: ~U[2026-11-01 09:00:00Z]))
    {:ok, newer} = Phrases.save(phrase(name: "Newer", created_at: ~U[2026-11-11 09:00:00Z]))
    {:ok, middle} = Phrases.save(phrase(name: "Middle", created_at: ~U[2026-11-05 09:00:00Z]))

    assert [n, m, o] = Phrases.list()
    assert Enum.map([n, m, o], & &1.id) == [newer.id, middle.id, older.id]
    assert Enum.all?([n, m, o], &match?(%{trace: [], notes: [_, _]}, &1))
    assert n.scale == Scale.new("D", :dorian)
  end

  test "save/1 updates a saved phrase and keeps when it was made" do
    {:ok, saved} = Phrases.save(phrase())

    edited =
      saved
      |> Phrase.move_note(0, 2)
      |> Phrase.set_tempo(100)
      |> Map.put(:created_at, ~U[2030-01-01 00:00:00Z])

    assert {:ok, updated} = Phrases.save(edited)
    assert updated.id == saved.id
    assert updated.created_at == saved.created_at
    assert [%{midi: 64} | _] = Phrases.get(saved.id).notes
    assert Phrases.get(saved.id).tempo_bpm == 100
    assert [_] = Phrases.list()

    assert Phrases.save(%{edited | id: saved.id + 1000}) == {:error, :not_found}
  end

  test "rename/2 and delete/1" do
    {:ok, saved} = Phrases.save(phrase())

    assert {:ok, %Phrase{name: "Answer phrase"}} = Phrases.rename(saved.id, "  Answer phrase ")
    assert {:ok, %Phrase{name: "New phrase"}} = Phrases.rename(saved.id, "")
    assert Phrases.rename(saved.id + 1, "x") == {:error, :not_found}

    assert Phrases.delete(saved.id) == :ok
    assert Phrases.get(saved.id) == nil
    assert Phrases.delete(saved.id) == {:error, :not_found}
    assert Phrases.list() == []
  end

  describe "a row that can't be read" do
    import ExUnit.CaptureLog
    import Ecto.Query

    # Saves a good phrase, then breaks one column of its row.
    defp broken(changes) do
      {:ok, %{id: id}} = Phrases.save(phrase(name: "Broken"))
      Repo.update_all(from(r in Phrases.Row, where: r.id == ^id), set: changes)
      id
    end

    for {label, changes} <- [
          {"an unknown scale mode", [scale_mode: "hypermixolydian"]},
          {"a root out of range", [scale_root: 14]},
          {"a mode without a root", [scale_root: nil]},
          {"an unknown grid", [quantize: "q32"]},
          {"an unknown source", [source: "camera"]},
          {"notes cut short", [notes: <<0, 0, 0, 0, 0, 0, 2, 88, 62>>]},
          {"a note count that doesn't match", [note_count: 5]},
          {"a note out of range",
           [notes: <<0::32, 600::32, 200, 90, 0, 625::32, 300::32, 64, 101, 1>>]},
          {"a future format", [format: 2]}
        ] do
      test "#{label} is skipped by list/0 and missing to get/1, and logged" do
        {:ok, good} = Phrases.save(phrase(name: "Good"))
        id = broken(unquote(Macro.escape(changes)))

        log =
          capture_log(fn ->
            assert [%Phrase{name: "Good"}] = Phrases.list()
            assert Phrases.get(id) == nil
          end)

        assert log =~ "skipped unreadable phrase #{id}"
        refute log =~ "Broken"
        assert Phrases.get(good.id).name == "Good"
      end
    end

    test "a trace cut short makes get/1 miss it (list/0 doesn't read traces)" do
      id = broken(trace: <<0, 0, 0, 1, 2>>)
      assert capture_log(fn -> assert Phrases.get(id) == nil end) =~ "#{id}: :trace"
      assert [%Phrase{id: ^id}] = Phrases.list()
    end

    test "rows written before the format column read as format 1" do
      {:ok, saved} = Phrases.save(phrase())
      assert Repo.get(Phrases.Row, saved.id).format == 1
    end
  end
end
