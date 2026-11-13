defmodule Humdinger.PhraseDraftTest do
  # Mob.State and the database are shared; each test gets its own Repo so it
  # can stop it.
  use Mob.ScreenCase, async: false

  import ExUnit.CaptureLog

  alias Humdinger.{Phrase, PhraseDraft, Phrases, PhraseScreen, Repo, Scale}
  alias Humdinger.Test.{FakeOutput, Listener}

  setup do
    Humdinger.Test.Repo.start()
    Listener.listen()
    FakeOutput.reset()
    Application.put_env(:humdinger, :output, FakeOutput)
    clear_drafts()

    on_exit(fn ->
      Application.delete_env(:humdinger, :output)
      clear_drafts()
    end)
  end

  defp clear_drafts, do: for({key, _} <- PhraseDraft.all(), do: PhraseDraft.delete(key))

  defp phrase(fields \\ []) do
    struct!(
      %Phrase{
        name: "Bus stop riff",
        notes: [%{start_ms: 0, dur_ms: 600, midi: 62, velocity: 90, unsure: false}],
        trace: for(t <- 0..600//20, do: {t, 62.0}),
        duration_ms: 600,
        tempo_bpm: 96,
        scale: Scale.new("D", :dorian),
        created_at: ~U[2026-11-13 10:00:00Z]
      },
      fields
    )
  end

  defp stop_repo, do: stop_supervised!(Repo)

  test "recover/0 saves leftover drafts into the list and forgets them" do
    {:ok, saved} = Phrases.save(phrase(name: "Saved"))
    {:ok, gone} = Phrases.save(phrase(name: "Deleted since"))
    :ok = Phrases.delete(gone.id)

    PhraseDraft.put(PhraseDraft.new_key(), phrase(name: "New one"))
    PhraseDraft.put(PhraseDraft.new_key(), %{saved | tempo_bpm: 120})
    PhraseDraft.put(PhraseDraft.new_key(), %{gone | tempo_bpm: 80})

    assert PhraseDraft.recover() == 3
    assert PhraseDraft.all() == []
    assert Phrases.get(saved.id).tempo_bpm == 120

    assert Enum.sort(Enum.map(Phrases.list(), & &1.name)) ==
             ["Deleted since", "New one", "Saved"]
  end

  test "a draft the database refuses is logged and dropped" do
    PhraseDraft.put(PhraseDraft.new_key(), phrase(trace: []))

    assert capture_log(fn -> assert PhraseDraft.recover() == 0 end) =~ "dropped a draft"
    assert PhraseDraft.all() == []
  end

  test "with the database stopped, saving answers an error and recover/0 keeps the drafts" do
    PhraseDraft.put(PhraseDraft.new_key(), phrase())
    stop_repo()

    assert {:error, {:unavailable, _}} = PhraseDraft.save(phrase())
    assert PhraseDraft.recover() == 0
    assert [{_, %Phrase{name: "Bus stop riff"}}] = PhraseDraft.all()
  end

  describe "the Review screen" do
    test "keeps a new phrase as a draft from the start" do
      view = mount_screen(PhraseScreen, %{phrase: phrase()})
      assert [{key, %Phrase{name: "Bus stop riff"}}] = PhraseDraft.all()
      assert key == assigns(view).draft_key
    end

    test "an edit becomes the draft once it settles; a stale timer does nothing" do
      {:ok, saved} = Phrases.save(phrase())
      view = mount_screen(PhraseScreen, %{phrase: saved})
      assert PhraseDraft.all() == []

      view = render_info(view, {:tap, {:tempo, 1}})
      first = assigns(view).draft_token
      view = render_info(view, {:tap, {:tempo, 1}})
      assert PhraseDraft.all() == []

      view = render_info(view, {:write_draft, first})
      assert PhraseDraft.all() == []

      view = render_info(view, {:write_draft, assigns(view).draft_token})
      assert [{_, %Phrase{tempo_bpm: 98}}] = PhraseDraft.all()

      # Back to what is saved: the draft goes.
      view = view |> render_info({:tap, {:tempo, -2}})
      render_info(view, {:write_draft, assigns(view).draft_token})
      assert PhraseDraft.all() == []
    end

    test "Save and Discard delete the draft" do
      view = mount_screen(PhraseScreen, %{phrase: phrase()})
      render_info(view, {:tap, :save})
      assert PhraseDraft.all() == []

      view = mount_screen(PhraseScreen, %{phrase: phrase()})
      render_info(view, {:tap, :leave})
      assert PhraseDraft.all() == []
    end

    test "terminate with the database stopped returns, keeps the edit as a draft, and the next start saves it" do
      view =
        PhraseScreen
        |> mount_screen(%{phrase: phrase()})
        |> render_info({:tap, {:tempo, 4}})

      stop_repo()

      log =
        capture_log(fn ->
          assert PhraseScreen.terminate(:shutdown, view.socket) == :ok
        end)

      assert log =~ "kept the phrase as a draft"
      assert [{_, %Phrase{tempo_bpm: 100}}] = PhraseDraft.all()

      # The next start: the database is back, recover/0 runs.
      Humdinger.Test.Repo.start()
      assert PhraseDraft.recover() == 1
      assert [%Phrase{name: "Bus stop riff", tempo_bpm: 100}] = Phrases.list()
      assert PhraseDraft.all() == []
    end

    test "terminate with the database up saves and forgets the draft" do
      view = PhraseScreen |> mount_screen(%{phrase: phrase(), notify: self()})
      assert PhraseScreen.terminate(:shutdown, view.socket) == :ok
      assert_received :phrases_changed
      assert [%Phrase{name: "Bus stop riff"}] = Phrases.list()
      assert PhraseDraft.all() == []
    end
  end
end
