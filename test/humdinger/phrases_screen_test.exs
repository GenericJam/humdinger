defmodule Humdinger.PhrasesScreenTest do
  # One in-memory database, and doubles configured in the application env.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.{ImportScreen, Phrase, Phrases, PhraseScreen, PhrasesScreen, Repo, Scale, Style}
  alias Humdinger.Test.{FakeOutput, Listener}

  setup_all do: Humdinger.Test.Repo.start()

  setup do
    Repo.delete_all(Phrases.Row)
    Listener.listen()
    FakeOutput.reset()
    Application.put_env(:humdinger, :output, FakeOutput)
    Application.put_env(:humdinger, :file_share, Humdinger.Test.FileShare)
    dir = Path.join(System.tmp_dir!(), "humdinger-phrases-#{System.unique_integer([:positive])}")
    Application.put_env(:humdinger, :export_dir, dir)

    on_exit(fn ->
      Enum.each([:output, :file_share, :export_dir], &Application.delete_env(:humdinger, &1))
      File.rm_rf!(dir)
    end)
  end

  defp save(name, created_at, notes \\ nil) do
    notes =
      notes ||
        [
          %{start_ms: 0, dur_ms: 625, midi: 62, velocity: 90, unsure: false},
          %{start_ms: 625, dur_ms: 312, midi: 64, velocity: 90, unsure: false},
          %{start_ms: 937, dur_ms: 313, midi: 65, velocity: 90, unsure: false}
        ]

    {:ok, p} =
      Phrases.save(%Phrase{
        name: name,
        notes: notes,
        trace: for(t <- 0..1200//20, do: {t, 62 + t / 600}),
        duration_ms: 1250,
        tempo_bpm: 96,
        scale: Scale.new("D", :dorian),
        quantize: :q8,
        created_at: created_at
      })

    p
  end

  defp loaded, do: PhrasesScreen |> mount_screen() |> render_async()

  test "loads the saved phrases, newest first, with their summaries" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    save("Low drone idea", DateTime.add(now, -3600))
    save("Bus stop riff", now)

    view = mount_screen(PhrasesScreen)
    assert assigns(view).phrases == :loading
    assert find(view, :progress, [])

    view = render_async(view)
    assert [%{name: "Bus stop riff"}, %{name: "Low drone idea"}] = assigns(view).phrases
    assert "3 notes · 1 bar · D Dorian · today" in texts(view)
    assert find(view, :lazy_list, id: "phrases")
    assert Enum.any?(texts(view), &String.starts_with?(&1, "⋯ menu: rename"))
    assert_renderable(view)
  end

  test "with nothing saved it shows Mimi and a hint instead" do
    view = loaded()
    assert by_id(view, "empty")
    assert "No phrases yet" in texts(view)
    refute find(view, :lazy_list, [])
  end

  test "play sends the phrase out on its grid; its button turns lime; tapping again stops it" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded()

    view = render_info(view, {:tap, {:play, id}})
    assert assigns(view).playing == id
    assert_receive {:output, [{:note_on, 62, 90}]}
    assert by_id(view, "play_#{id}").props.background == Style.fm()

    view = render_info(view, {:tap, {:play, id}})
    assert assigns(view).playing == nil
    assert_receive {:output, [{:note_off, 62}]}
    assert by_id(view, "play_#{id}").props.background == Style.raised_hi()
  end

  test "the button goes back to grey when the phrase has played to the end" do
    %{id: id} = save("Short", DateTime.utc_now())
    view = loaded() |> render_info({:tap, {:play, id}})

    view = render_info(view, {:player, :finished, id})
    assert assigns(view).playing == nil
    # A finish from an earlier play doesn't stop a newer one.
    view = view |> render_info({:tap, {:play, id}}) |> render_info({:player, :finished, :other})
    assert assigns(view).playing == id
  end

  test "tapping a card opens its review; Sheet music opens it on the staff" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded()

    opened = render_info(view, {:tap, {:open, id}})
    assert {:push, PhraseScreen, %{id: ^id, tab: :roll, notify: pid}} = nav(opened)
    assert pid == self()

    staff = view |> render_info({:tap, {:more, id}}) |> render_info({:tap, {:sheet_music, id}})
    assert {:push, PhraseScreen, %{id: ^id, tab: :staff}} = nav(staff)
    assert sheet(staff) == nil
  end

  test "+ From audio file opens the import screen" do
    view = loaded() |> render_info({:tap, :import})
    assert {:push, ImportScreen, %{notify: _}} = nav(view)
  end

  test "rename from the menu saves the new name" do
    %{id: id} = save("New phrase", DateTime.utc_now())
    view = loaded() |> render_info({:tap, {:more, id}})

    assert sheet(view)
    assert ["Rename", "Sheet music", "Export .mid", "Share", "Delete"] -- texts(view) == []

    view = render_info(view, {:tap, {:rename, id}})
    assert find(view, :text_field, id: "name").props.value == "New phrase"

    view =
      view
      |> render_info({:change, :name, "  Bus stop riff "})
      |> render_info({:tap, {:save_name, id}})

    assert sheet(view) == nil
    assert Phrases.get(id).name == "Bus stop riff"
    assert [%{name: "Bus stop riff"}] = assigns(view).phrases
  end

  test "delete asks first, then removes the phrase" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded() |> render_info({:tap, {:more, id}}) |> render_info({:tap, {:delete, id}})

    assert "Delete “Bus stop riff”?" in texts(view)
    assert Phrases.get(id)

    cancelled = render_info(view, {:tap, :dismiss})
    assert sheet(cancelled) == nil
    assert Phrases.get(id)

    deleted = render_info(view, {:tap, {:confirm_delete, id}})
    assert Phrases.get(id) == nil
    assert assigns(deleted).phrases == []
    assert by_id(deleted, "empty")
  end

  test "deleting the phrase that's playing stops it" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded() |> render_info({:tap, {:play, id}})
    assert_receive {:output, [{:note_on, 62, 90}]}

    view = render_info(view, {:tap, {:confirm_delete, id}})
    assert assigns(view).playing == nil
    assert_receive {:output, [{:note_off, 62}]}
  end

  test "Export .mid and Share hand a file to the share sheet" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded()

    view =
      view
      |> render_info({:tap, {:more, id}})
      |> render_info({:tap, {:export, id, :mid}})
      |> render_async()

    assert_receive {:share, path, "audio/midi", "Bus stop riff"}
    assert Path.basename(path) == "Bus stop riff.mid"
    assert File.read!(path) =~ "MThd"
    assert assigns(view).notice == nil

    view = view |> render_info({:tap, {:share, id}})
    assert ["MIDI file (.mid)", "Sheet music (PDF)", "MusicXML"] -- texts(view) == []

    view |> render_info({:tap, {:export, id, :pdf}}) |> render_async()
    assert_receive {:share, pdf, "application/pdf", "Bus stop riff"}
    assert File.read!(pdf) =~ "%PDF"
  end

  test "without a native share hook the export says so" do
    Application.delete_env(:humdinger, :file_share)
    %{id: id} = save("Bus stop riff", DateTime.utc_now())

    view = loaded() |> render_info({:tap, {:export, id, :mid}}) |> render_async()
    assert assigns(view).notice == "This phone can't hand files to other apps."
    assert text_of(view, "notice") == "This phone can't hand files to other apps."
  end

  test "a review's save reloads the list" do
    view = loaded()
    assert assigns(view).phrases == []

    save("Answer phrase", DateTime.utc_now())
    view = view |> render_info(:phrases_changed) |> render_async()
    assert [%{name: "Answer phrase"}] = assigns(view).phrases
  end

  test "every tap target keeps its tap through re-renders, in the list and the sheets" do
    %{id: id} = save("Bus stop riff", DateTime.utc_now())
    view = loaded() |> render_info({:tap, {:play, id}})

    for v <- [
          view,
          render_info(view, {:tap, {:more, id}}),
          render_info(view, {:tap, {:share, id}}),
          view |> render_info({:tap, {:rename, id}}),
          render_info(view, {:tap, {:delete, id}})
        ] do
      assert_every_tap_held(v)
    end

    assert render_info(view, {:press_out, :held}).socket == view.socket
  end
end
