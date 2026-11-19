defmodule Humdinger.PhraseScreenTest do
  # One in-memory database, and doubles configured in the application env.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.{LiveScreen, Notation, Phrase, Phrases, PhraseScreen, Repo, Scale, Style}
  alias Humdinger.Test.{FakeOutput, Listener}
  alias Humdinger.Views.{PianoRoll, Staff}

  defmodule FakePianoAudio do
    @key {__MODULE__, :cfg}

    def configure(test_pid, reply \\ :ok, cancel \\ :ok),
      do: :persistent_term.put(@key, %{test: test_pid, reply: reply, cancel: cancel})

    def clear, do: :persistent_term.erase(@key)

    def play_piano(owner, notes) do
      case :persistent_term.get(@key) do
        %{test: test, reply: :ok} ->
          ref = make_ref()
          send(test, {:piano_start, owner, notes, ref})
          {:ok, ref}

        %{test: test, reply: {:error, reason} = err} ->
          send(test, {:piano_start_error, owner, notes, reason})
          err
      end
    end

    def cancel_piano(ref) do
      case :persistent_term.get(@key, nil) do
        %{test: test, cancel: cancel} ->
          send(test, {:piano_cancel, ref})
          cancel

        nil ->
          :ok
      end
    end
  end

  @eighth 60_000 / 96 / 2

  setup_all do: Humdinger.Test.Repo.start()

  setup do
    Repo.delete_all(Phrases.Row)
    Listener.listen()
    FakeOutput.reset()
    prev_audio = Application.get_env(:humdinger, :audio)
    FakePianoAudio.configure(self())
    Application.put_env(:humdinger, :audio, FakePianoAudio)
    Application.put_env(:humdinger, :output, FakeOutput)
    Application.put_env(:humdinger, :file_share, Humdinger.Test.FileShare)
    dir = Path.join(System.tmp_dir!(), "humdinger-review-#{System.unique_integer([:positive])}")
    Application.put_env(:humdinger, :export_dir, dir)

    on_exit(fn ->
      if prev_audio,
        do: Application.put_env(:humdinger, :audio, prev_audio),
        else: Application.delete_env(:humdinger, :audio)

      FakePianoAudio.clear()

      Enum.each(
        [:output, :file_share, :export_dir],
        &Application.delete_env(:humdinger, &1)
      )

      File.rm_rf!(dir)
      # Mounting a new phrase keeps it as a draft in Mob.State (shared).
      for {key, _} <- Humdinger.PhraseDraft.all(), do: Humdinger.PhraseDraft.delete(key)
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

  # A screen that opens the review, so system Back has somewhere to go.
  defmodule Opener do
    use Mob.Screen

    @impl true
    def mount(params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :params, params)}

    @impl true
    def render(_assigns), do: ~MOB(<Column />)

    @impl true
    def handle_event("open", _params, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, PhraseScreen, socket.assigns.params)}
  end

  # The review in a real navigation stack, opened from `Opener`.
  defp opened(params) do
    {:ok, nav} = Mob.Screen.start_link(Opener, Map.put(params, :notify, self()))
    :ok = Mob.Screen.dispatch(nav, "open", %{})
    assert Mob.Screen.get_current_module(nav) == PhraseScreen
    nav
  end

  # System Back, as Android's gesture sends it (what `Mob.Test.back/1` does).
  defp system_back(nav) do
    send(nav, {:mob, :back})
    assert Mob.Screen.get_current_module(nav) == Opener
  end

  describe "system Back (it pops without asking the screen)" do
    test "keeps a new phrase: it's saved and the list hears of it" do
      nav = opened(%{phrase: phrase()})
      system_back(nav)

      assert_receive :phrases_changed
      assert [%Phrase{name: "New phrase", tempo_bpm: 96} = saved] = Phrases.list()
      assert saved.notes == phrase().notes
    end

    test "keeps edits to a saved phrase; leaves an unchanged one alone" do
      {:ok, saved} = Phrases.save(phrase())
      updated_at = Repo.get(Phrases.Row, saved.id).updated_at

      nav = opened(%{phrase: saved})
      system_back(nav)
      refute_received :phrases_changed
      assert Repo.get(Phrases.Row, saved.id).updated_at == updated_at

      nav = opened(%{phrase: saved})
      send(nav, {:tap, {:tempo, 4}})
      assert Mob.Screen.get_socket(nav).assigns.phrase.tempo_bpm == 100
      system_back(nav)

      assert_receive :phrases_changed
      assert Phrases.get(saved.id).tempo_bpm == 100
      assert [_one] = Phrases.list()
    end

    test "Discard and Hum again still drop the phrase" do
      nav = opened(%{phrase: phrase()})
      send(nav, {:tap, :leave})
      assert eventually(fn -> Mob.Screen.get_current_module(nav) == Opener end)

      nav = opened(%{phrase: phrase(), return_to: self()})
      send(nav, {:tap, :hum_again})
      assert_receive :hum_again
      # Opener stands in for Live: pop_to an absent screen leaves the review up.
      assert Mob.Screen.get_socket(nav).assigns.left

      refute_received :phrases_changed
      assert Phrases.list() == []
    end

    test "cancels active piano preview when leaving via system Back" do
      nav = opened(%{phrase: phrase()})
      send(nav, {:tap, :play_piano})
      assert_receive {:piano_start, _player, _notes, pref}

      system_back(nav)
      assert_receive {:piano_cancel, ^pref}
    end
  end

  describe "local piano preview" do
    test "plays locally without MIDI output, renders playhead and active note on roll and staff, and ignores stale tags" do
      view = review() |> render_info({:tap, :play_piano})
      player = assigns(view).player
      tag = assigns(view).piano_tag
      assert is_reference(tag)
      refute assigns(view).playing
      assert_every_tap_held(view)

      assert_receive {:piano_start, ^player, notes, pref}
      assert notes == Phrase.quantized_notes(assigns(view).phrase)
      refute_received {:output, _}

      send(player, {:hum_audio, pref, {:piano_position, 1000}})
      assert_receive {:player, :position, ^tag, 1000} = pos_msg
      view = render_info(view, pos_msg)

      assert assigns(view).playhead_ms == 1000
      roll_ops = find(view, :canvas, id: "roll").props.draw
      assert Enum.any?(roll_ops, &(&1.color == Style.fm() and &1[:fill]))
      assert Enum.any?(roll_ops, &(&1.color == Style.fm() and &1[:width] == 2))

      staff_view = render_info(view, {:tap, {:tab, :staff}})
      assert_every_tap_held(staff_view)
      staff_ops = find(staff_view, :canvas, id: "staff").props.draw
      assert Enum.any?(staff_ops, &(&1.color == Style.fm_dim() and &1[:fill]))
      assert Enum.any?(staff_ops, &(&1.color == Style.fm_dim() and &1[:width] == 2.2))

      # Stale tags do not move playhead or clear active playback.
      stale = make_ref()

      view =
        view
        |> render_info({:player, :position, stale, 4500})
        |> render_info({:player, :finished, stale})
        |> render_info({:player, :error, stale, :stale_error})

      assert assigns(view).piano_tag == tag
      assert assigns(view).playhead_ms == 1000
      refute find(view, :text, id: "notice")

      send(player, {:hum_audio, pref, :piano_finished})
      assert_receive {:player, :finished, ^tag} = fin_msg
      view = render_info(view, fin_msg)

      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      refute Enum.any?(find(view, :canvas, id: "roll").props.draw, &(&1.color == Style.fm()))
    end

    test "Stop piano cancels native playback and clears highlights, ignoring late progress" do
      view = review() |> render_info({:tap, :play_piano})
      tag = assigns(view).piano_tag
      player = assigns(view).player
      assert_receive {:piano_start, ^player, _, pref}

      view =
        view
        |> render_info({:player, :position, tag, 900})
        |> render_info({:tap, :play_piano})

      assert_receive {:piano_cancel, ^pref}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil

      view =
        view
        |> render_info({:player, :position, tag, 1200})
        |> render_info({:player, :error, tag, :late})

      assert assigns(view).playhead_ms == nil
      refute find(view, :text, id: "notice")
    end

    test "edits and external Play out stop piano preview and clear playhead" do
      view = review() |> render_info({:tap, :play_piano})
      assert_receive {:piano_start, player, _, pref1}

      view =
        view
        |> render_info({:player, :position, assigns(view).piano_tag, 800})
        |> render_info({:tap, {:quantize, :q16}})

      assert_receive {:piano_cancel, ^pref1}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      assert assigns(view).phrase.quantize == :q16

      view = render_info(view, {:tap, :play_piano})
      assert_receive {:piano_start, ^player, _, pref2}
      {b, _} = block(view, 4)

      view =
        view
        |> render_info({:player, :position, assigns(view).piano_tag, 800})
        |> drag(:began, b.x + b.w / 2, b.y + b.h / 2)

      assert_receive {:piano_cancel, ^pref2}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil

      view =
        view
        |> drag(:ended, b.x + b.w / 2, b.y + b.h / 2)
        |> render_info({:tap, :play_piano})

      assert_receive {:piano_start, ^player, _, pref3}

      view =
        view
        |> render_info({:player, :position, assigns(view).piano_tag, 500})
        |> render_info({:tap, :play})

      assert_receive {:piano_cancel, ^pref3}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      assert assigns(view).playing
      assert_receive {:output, [{:note_on, _, _} | _]}
    end

    test "Hum again cancels active piano preview" do
      view = review(%{return_to: self()}) |> render_info({:tap, :play_piano})
      assert_receive {:piano_start, _player, _, pref}

      render_info(view, {:tap, :hum_again})
      assert_receive {:piano_cancel, ^pref}
      assert_receive :hum_again
    end

    test "synchronous and async piano errors show a notice and clear highlights" do
      FakePianoAudio.configure(self(), {:error, :unavailable})
      view = review() |> render_info({:tap, :play_piano})
      assert_receive {:piano_start_error, _, _, :unavailable}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      assert find(view, :text, id: "notice")

      FakePianoAudio.configure(self(), :ok)
      view = render_info(view, {:tap, :play_piano})
      refute find(view, :text, id: "notice")
      tag = assigns(view).piano_tag
      player = assigns(view).player
      assert_receive {:piano_start, ^player, _, pref}

      view = render_info(view, {:player, :position, tag, 400})
      assert assigns(view).playhead_ms == 400

      send(player, {:hum_audio, pref, {:piano_error, :device_lost}})
      assert_receive {:player, :error, ^tag, :device_lost} = err_msg
      view = render_info(view, err_msg)

      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      assert find(view, :text, id: "notice")
      refute Enum.any?(find(view, :canvas, id: "roll").props.draw, &(&1.color == Style.fm()))
    end

    test "Simpler rhythm highlights the note actually playing on the staff" do
      p = %Phrase{
        notes: [
          %{start_ms: 0, dur_ms: 500, midi: 60, velocity: 90, unsure: false},
          %{start_ms: 500, dur_ms: 1500, midi: 67, velocity: 90, unsure: false}
        ],
        trace: [],
        duration_ms: 2000,
        tempo_bpm: 60,
        scale: Scale.new("C", :major),
        quantize: :q16
      }

      view =
        review(%{phrase: p})
        |> render_info({:tap, {:tab, :staff}})
        |> render_info({:tap, {:rhythm, :simpler}})
        |> render_info({:tap, :play_piano})

      player = assigns(view).player
      tag = assigns(view).piano_tag
      assert_receive {:piano_start, ^player, notes, _pref}
      assert notes == Phrase.quantized_notes(p)

      base_data = %{layout: Notation.layout(p, clef: :auto, rhythm: :simpler), note_names: true}
      base_ops = Staff.ops(base_data, 350, Staff.height(base_data, 350))
      [head0, head1] = Enum.filter(base_ops, &(&1.op == :ellipse))

      view = render_info(view, {:player, :position, tag, 700})
      staff_ops = find(view, :canvas, id: "staff").props.draw

      rings =
        Enum.filter(
          staff_ops,
          &(&1.op == :circle and &1.color == Style.fm_dim() and &1[:width] == 2.2 and &1.r == 11)
        )

      assert [ring] = rings
      assert ring.x == head1.x
      refute ring.x == head0.x
    end

    test "quantize :off highlights the played note on both staff and roll" do
      p = %Phrase{
        notes: [
          %{start_ms: 0, dur_ms: 130, midi: 60, velocity: 90, unsure: false},
          %{start_ms: 130, dur_ms: 400, midi: 67, velocity: 90, unsure: false}
        ],
        trace: [],
        duration_ms: 1000,
        tempo_bpm: 120,
        scale: Scale.new("C", :major),
        quantize: :off
      }

      view = review(%{phrase: p}) |> render_info({:tap, :play_piano})
      player = assigns(view).player
      tag = assigns(view).piano_tag
      assert_receive {:piano_start, ^player, notes, _pref}
      assert notes == Phrase.quantized_notes(p)

      view = render_info(view, {:player, :position, tag, 128})
      {b0, _} = block(view, 0)
      {b1, _} = block(view, 1)
      roll_ops = find(view, :canvas, id: "roll").props.draw

      roll_rings =
        Enum.filter(roll_ops, &(&1.op == :rect and &1.color == Style.fm() and &1[:width] == 2))

      assert [roll_ring] = roll_rings
      assert roll_ring.x == Float.round(b0.x + 1, 1)
      refute roll_ring.x == Float.round(b1.x + 1, 1)

      base_data = %{layout: Notation.layout(p, clef: :auto, rhythm: :as_sung), note_names: true}
      base_ops = Staff.ops(base_data, 350, Staff.height(base_data, 350))
      [head0, head1 | _] = Enum.filter(base_ops, &(&1.op == :ellipse))

      staff_view = render_info(view, {:tap, {:tab, :staff}})
      staff_ops = find(staff_view, :canvas, id: "staff").props.draw

      staff_rings =
        Enum.filter(
          staff_ops,
          &(&1.op == :circle and &1.color == Style.fm_dim() and &1[:width] == 2.2 and &1.r == 11)
        )

      assert [staff_ring] = staff_rings
      assert staff_ring.x == head0.x
      refute staff_ring.x == head1.x
    end

    test "Stop piano that can't stop the stream shows a notice" do
      view = review() |> render_info({:tap, :play_piano})
      player = assigns(view).player
      assert_receive {:piano_start, ^player, _notes, pref}

      FakePianoAudio.configure(self(), :ok, {:error, :stream_stuck})
      view = render_info(view, {:tap, :play_piano})

      assert_receive {:piano_cancel, ^pref}
      assert assigns(view).piano_tag == nil
      assert assigns(view).playhead_ms == nil
      assert find(view, :text, id: "notice")
    end

    test "Play out over a stuck piano preview doesn't crash and explains" do
      view = review() |> render_info({:tap, :play_piano})
      player = assigns(view).player
      assert_receive {:piano_start, ^player, _notes, pref}

      FakePianoAudio.configure(self(), :ok, {:error, :stream_stuck})
      view = render_info(view, {:tap, :play})

      assert_receive {:piano_cancel, ^pref}
      assert_renderable(view)
      refute assigns(view).playing
      assert assigns(view).piano_tag == nil
      assert find(view, :text, id: "notice")
      refute_received {:output, [{:note_on, _, _} | _]}
    end
  end

  # The tap reaches the screen through the router; its navigation comes back after.
  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end
end
