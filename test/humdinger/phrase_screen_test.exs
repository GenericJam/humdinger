defmodule Humdinger.PhraseScreenTest do
  # One in-memory database, and doubles configured in the application env.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.{LiveScreen, Phrase, Phrases, PhraseScreen, Repo, Scale}
  alias Humdinger.Test.{FakeOutput, Listener}
  alias Humdinger.Views.PianoRoll

  @eighth 60_000 / 96 / 2

  setup_all do: Humdinger.Test.Repo.start()

  setup do
    Repo.delete_all(Phrases.Row)
    Listener.listen()
    FakeOutput.reset()
    Application.put_env(:humdinger, :output, FakeOutput)
    Application.put_env(:humdinger, :file_share, Humdinger.Test.FileShare)
    dir = Path.join(System.tmp_dir!(), "humdinger-review-#{System.unique_integer([:positive])}")
    Application.put_env(:humdinger, :export_dir, dir)

    on_exit(fn ->
      Enum.each(
        [:output, :file_share, :export_dir],
        &Application.delete_env(:humdinger, &1)
      )

      File.rm_rf!(dir)
    end)
  end

  # The board's phrase: D Dorian at 96, eighths; F4 (index 4) is selected there.
  defp phrase do
    notes =
      for {s, d, m} <- [
            {0, 2, 62},
            {2, 1, 64},
            {3, 1, 65},
            {4, 3, 69},
            {8, 2, 65},
            {10, 2, 64},
            {12, 2, 62},
            {14, 2, 60}
          ] do
        %{
          start_ms: round(s * @eighth),
          dur_ms: round(d * @eighth),
          midi: m,
          velocity: 90,
          unsure: m == 65
        }
      end

    %Phrase{
      notes: notes,
      trace: for(t <- 0..5000//20, do: {t, 62 + :math.sin(t / 800) * 3}),
      duration_ms: 5000,
      tempo_bpm: 96,
      tempo_detected: true,
      scale: Scale.new("D", :dorian),
      quantize: :q8,
      created_at: ~U[2026-11-12 10:00:00Z]
    }
  end

  defp review(params \\ %{}),
    do: mount_screen(PhraseScreen, Map.merge(%{phrase: phrase()}, params))

  # Where note `i`'s block is on the roll as the screen draws it.
  defp block(view, i) do
    a = assigns(view)
    data = PhraseScreen.roll_data(a.phrase, a.selected)
    layout = PianoRoll.layout(data, 350, 312)
    {Enum.at(layout.blocks, Enum.find_index(data.indexes, &(&1 == i))), layout}
  end

  defp row_y(layout, midi) do
    row = Enum.find(layout.rows, &(&1.midi == midi))
    row.y + layout.row_h / 2
  end

  defp drag(view, phase, x, y), do: render_info(view, {:drag, :roll, %{phase: phase, x: x, y: y}})

  test "shows the name, the summary, the tabs and the roll" do
    view = review()
    assert "New phrase" in texts(view)
    assert "8 notes · 2 bars at 96 · D Dorian" in texts(view)

    assert ["Piano roll", "Staff", "Hum again", "Quantize", "1/4", "1/8", "1/16", "Off"] --
             texts(view) == []

    assert "96 bpm · detected" in texts(view)
    assert "Play out to FMutate A" in texts(view)
    assert find(view, :canvas, id: "roll").props.on_drag
    assert_renderable(view)
  end

  test "the play button names the first destination that is on and reachable" do
    FakeOutput.reset([
      %{id: :fmutate, name: "FMutate", detail: "", enabled: true, available: false},
      %{id: :port, name: "Humdinger port", detail: "", enabled: true, available: true}
    ])

    assert "Play out to Humdinger port" in texts(review())

    FakeOutput.reset([])
    assert "Play out" in texts(review())
  end

  test "dragging a note's body moves it to the row under the finger" do
    view = review()
    {b, layout} = block(view, 4)
    cx = b.x + b.w / 2
    cy = b.y + b.h / 2

    view = drag(view, :began, cx, cy)
    assert assigns(view).selected == 4
    assert %{index: 4, part: :body} = assigns(view).drag

    # Up one row of D Dorian: F4 → G4.
    view = drag(view, :dragging, cx + 3, row_y(layout, 67))
    assert Enum.at(assigns(view).phrase.notes, 4).midi == 67

    # Rows come from the roll as it was when the drag began: two rows down is D4.
    view = drag(view, :ended, cx, row_y(layout, 62))
    note = Enum.at(assigns(view).phrase.notes, 4)
    assert note.midi == 62
    refute note.unsure
    assert assigns(view).drag == nil
    assert "8 notes · 2 bars at 96 · D Dorian" in texts(view)
  end

  test "dragging a note's ends changes its length on the grid" do
    view = review()
    {b, layout} = block(view, 7)
    end_x = b.x + b.w - 2
    step_px = @eighth * layout.px_per_ms

    view = view |> drag(:began, end_x, b.y + b.h / 2)
    assert %{index: 7, part: :end} = assigns(view).drag

    view = view |> drag(:dragging, end_x + step_px, b.y) |> drag(:ended, end_x + step_px, b.y)
    last = List.last(assigns(view).phrase.notes)
    assert last.start_ms + last.dur_ms == round(17 * @eighth)

    {b3, _} = block(view, 3)

    view =
      view |> drag(:began, b3.x + 2, b3.y + b3.h / 2) |> drag(:ended, b3.x + 2 + step_px, b3.y)

    assert Enum.at(assigns(view).phrase.notes, 3).start_ms == round(5 * @eighth)
  end

  test "a drag whose end never arrives ends after a quiet second; a stale timer does nothing" do
    view = review()
    {b, _} = block(view, 2)
    view = drag(view, :began, b.x + b.w / 2, b.y + b.h / 2)
    %{token: first} = assigns(view).drag

    view = drag(view, :dragging, b.x + b.w / 2, b.y + 1)
    %{token: latest} = assigns(view).drag
    assert first != latest

    assert assigns(render_info(view, {:drag_quiet, first})).drag
    assert assigns(render_info(view, {:drag_quiet, latest})).drag == nil
  end

  test "a drag whose began was lost still grabs at its first point; an empty spot deselects" do
    view = review()
    {b, _} = block(view, 0)
    view = drag(view, :dragging, b.x + b.w / 2, b.y + b.h / 2)
    assert %{index: 0} = assigns(view).drag

    view = view |> drag(:ended, b.x + b.w / 2, b.y + b.h / 2) |> drag(:began, 340, 6)
    assert assigns(view).selected == nil
    assert assigns(view).drag == nil
  end

  test "quantize and tempo change the phrase; the tempo is then no longer the detected one" do
    view = review() |> render_info({:tap, {:quantize, :q16}})
    assert assigns(view).phrase.quantize == :q16
    assert find(view, :box, id: "seg_q16").props.background == Humdinger.Style.selected()

    view = view |> render_info({:tap, {:tempo, 1}}) |> render_info({:tap, {:tempo, 1}})
    assert assigns(view).phrase.tempo_bpm == 98
    assert "98 bpm" in texts(view)

    view = render_info(view, {:tap, {:tempo, -1}})
    assert assigns(view).phrase.tempo_bpm == 97
  end

  test "Save stores it, tells the list, reads Saved until the next edit" do
    view = review(%{notify: self()}) |> render_info({:tap, :save})
    assert %Phrase{id: id} = assigns(view).phrase
    assert is_integer(id)
    assert Phrases.get(id).name == "New phrase"
    assert_received :phrases_changed
    assert "Saved" in texts(view)

    view = render_info(view, {:tap, {:quantize, :q4}})
    assert "Save" in texts(view)
    render_info(view, {:tap, :save})
    assert Phrases.get(id).quantize == :q4
  end

  test "Discard asks first for a phrase that isn't saved, then leaves" do
    view = render_info(review(), {:tap, :discard})
    assert "Discard this phrase?" in texts(view)
    assert nav(view) == nil

    kept = render_info(view, {:tap, :dismiss})
    assert sheet(kept) == nil

    gone = render_info(view, {:tap, :leave})
    assert nav(gone) == {:pop}
  end

  test "a saved phrase without changes leaves at once; with changes back asks" do
    {:ok, saved} = Phrases.save(phrase())
    view = mount_screen(PhraseScreen, %{id: saved.id}) |> render_async()
    assert assigns(view).phrase.id == saved.id

    assert nav(render_info(view, {:tap, :back})) == {:pop}

    edited = view |> render_info({:tap, {:tempo, 1}}) |> render_info({:tap, :back})
    assert nav(edited) == nil
    assert "Discard your changes?" in texts(edited)
  end

  test "a phrase that's gone says so" do
    view = mount_screen(PhraseScreen, %{id: 999_999}) |> render_async()
    assert text_of(view, "missing") =~ "isn't on the phone"
    assert nav(render_info(view, {:tap, :leave})) == {:pop}
  end

  test "Hum again tells Live to record and goes back to it" do
    view = review(%{return_to: self()}) |> render_info({:tap, :hum_again})
    assert_received :hum_again
    assert nav(view) == {:pop_to, LiveScreen}
  end

  test "tapping the name renames it" do
    view = review() |> render_info({:tap, :rename})
    assert find(view, :text_field, id: "name").props.value == "New phrase"

    view = view |> render_info({:change, :name, "Bus stop riff"}) |> render_info({:submit, :name})
    assert assigns(view).phrase.name == "Bus stop riff"
    assert sheet(view) == nil
  end

  test "Play out plays the phrase on its grid and becomes Stop" do
    view = review() |> render_info({:tap, :play})
    assert_receive {:output, [{:note_on, 62, 90}]}
    assert "Stop" in texts(view)

    view = render_info(view, {:player, :finished, :phrase})
    refute assigns(view).playing

    view = view |> render_info({:tap, :play}) |> render_info({:tap, :play})
    refute assigns(view).playing
    assert_receive {:output, [{:note_off, 62}]}
  end

  test "Export .mid hands the file to the share sheet" do
    review() |> render_info({:tap, {:share, :mid}}) |> render_async()
    assert_receive {:share, path, "audio/midi", "New phrase"}
    assert Path.extname(path) == ".mid"
  end

  test "the staff tab: clef, rhythm and note names drive the engraving and the exports" do
    view = review(%{tab: :staff})
    staff = find(view, :canvas, id: "staff")
    assert staff.props.width == 350
    refute "Hum again" in texts(view)

    assert ["Auto", "Treble", "Bass", "As sung (1/8)", "Simpler (1/4)", "Note names"] --
             texts(view) == []

    assert Enum.any?(
             texts(view),
             &(&1 =~
                 "D Dorian has no sharps or flats, so no key signature. Transpose on the home screen")
           )

    view =
      view
      |> render_info({:tap, {:clef, :bass}})
      |> render_info({:tap, {:rhythm, :simpler}})
      |> render_info({:change, :note_names, false})

    assert %{clef: :bass, rhythm: :simpler, note_names: false} = assigns(view)
    assert find(view, :canvas, id: "staff").props.draw != staff.props.draw

    view = view |> render_info({:tap, {:share, :pdf}}) |> render_async()
    assert_receive {:share, pdf, "application/pdf", "New phrase"}
    assert File.read!(pdf) =~ "%PDF"

    view = view |> render_info({:tap, {:share, :musicxml}}) |> render_async()
    assert_receive {:share, xml, "application/vnd.recordare.musicxml+xml", _}
    assert File.read!(xml) =~ "<sign>F</sign>"

    view |> render_info({:tap, :print}) |> render_async()
    assert_receive {:print, printed, "New phrase"}
    assert Path.extname(printed) == ".pdf"
  end

  test "switching tabs keeps the edits" do
    view =
      review()
      |> render_info({:tap, {:tempo, 4}})
      |> render_info({:tap, {:tab, :staff}})
      |> render_info({:tap, {:tab, :roll}})

    assert assigns(view).phrase.tempo_bpm == 100
  end

  test "every tap target keeps its tap through re-renders, on both tabs and in the sheets" do
    playing = review() |> render_info({:tap, :play})

    for v <- [
          playing,
          render_info(playing, {:tap, {:tab, :staff}}),
          render_info(playing, {:tap, :rename}),
          render_info(playing, {:tap, :discard})
        ] do
      assert_every_tap_held(v)
    end
  end
end
