defmodule Humdinger.ImportScreenTest do
  # Doubles configured in the application env.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens

  alias Humdinger.Audio.Fake
  alias Humdinger.{ImportScreen, Music, Phrase, PhraseScreen, Scale, Style}
  alias Humdinger.Test.{FakeOutput, Listener, Share}

  @duration 6000
  @wave_w 344

  setup do
    Listener.listen()
    Fake.reset()
    FakeOutput.reset()
    audio = Application.get_env(:humdinger, :audio)
    Application.put_env(:humdinger, :audio, Fake)
    Application.put_env(:humdinger, :output, FakeOutput)
    dir = Path.join(System.tmp_dir!(), "humdinger-import-#{System.unique_integer([:positive])}")
    Application.put_env(:humdinger, :export_dir, dir)

    on_exit(fn ->
      Application.put_env(:humdinger, :audio, audio)
      Enum.each([:output, :export_dir], &Application.delete_env(:humdinger, &1))
      File.rm_rf!(dir)
    end)
  end

  # A clean hum in E minor at 84 bpm (eighths), after a second of silence;
  # the eleventh note is a quick 150 ms one.
  defp analysis do
    eighth = round(60_000 / 84 / 2)
    melody = [64, 67, 69, 71, 71, 69, 67, 64, 62, 64, 64, 67]
    start = 1000

    readings =
      for t <- 0..(@duration - 10)//10 do
        i = div(t - start, eighth)
        sung = if i == 10, do: 150, else: eighth - 40
        in_note = t >= start and i < length(melody) and rem(t - start, eighth) < sung

        if in_note,
          do: %{t: t, hz: Music.midi_to_hz(Enum.at(melody, i)), clarity: 0.95, db: -18.0},
          else: %{t: t, hz: nil, clarity: 0.1, db: -80.0}
      end

    waveform =
      for t <- 0..(@duration - 50)//50, into: <<>>, do: <<if(t in 1000..5300, do: 200, else: 8)>>

    %{duration_ms: @duration, waveform: waveform, readings: readings}
  end

  defp item(name \\ "voice-memo.m4a", mime \\ "audio/mp4"),
    do: %{path: "/tmp/" <> name, name: name, mime: mime, size: 1024}

  # The reference of the newest `analyze_file/3` call (for `path`).
  defp analysis_ref(path \\ "/tmp/voice-memo.m4a") do
    assert [{ref, ^path} | _] = Fake.analyses()
    ref
  end

  # Fake delivers the analysis to the screen that asked: the test process.
  defp analysed(view, ref) do
    :ok = Fake.analysis(ref, analysis())
    assert_receive {:hum_audio, ^ref, {:analysis, _}} = message
    render_info(view, message)
  end

  defp ready do
    view =
      ImportScreen |> mount_screen(%{notify: self()}) |> render_info({:files, :picked, [item()]})

    analysed(view, analysis_ref())
  end

  defp x_of(ms), do: 7 + ms / @duration * (@wave_w - 14)
  defp wave(view, phase, x), do: render_info(view, {:drag, :wave, %{phase: phase, x: x, y: 31}})

  test "starts by asking for a file" do
    view = mount_screen(ImportScreen)
    assert assigns(view).stage == :choose

    assert ["Audio to notes", "Turn a recording into notes", "Choose an audio file"] --
             texts(view) == []

    refute by_id(view, "other_file")
    assert assert_renderable(view)
  end

  test "a picked file is analysed in the background while Mimi listens" do
    view = ImportScreen |> mount_screen() |> render_info({:files, :picked, [item()]})
    ref = analysis_ref()
    assert assigns(view).stage == :analysing
    assert "Listening to voice-memo.m4a…" in texts(view)
    assert find(view, :progress, [])

    # An answer for an earlier file is ignored.
    stale = render_info(view, {:hum_audio, make_ref(), {:analysis, analysis()}})
    assert assigns(stale).stage == :analysing

    view = analysed(view, ref)
    assert assigns(view).stage == :ready
    assert "voice-memo.m4a · 0:06" in texts(view)
    assert text_of(view, "using") == "using 0:00 – 0:06"
  end

  test "another file during the analysis cancels the first" do
    view = ImportScreen |> mount_screen() |> render_info({:files, :picked, [item()]})
    first = analysis_ref()
    view = render_info(view, {:files, :picked, [item("other.mp3", "audio/mpeg")]})
    second = analysis_ref("/tmp/other.mp3")
    refute Fake.analysing?(first)
    assert Fake.analysing?(second)
    assert assigns(view).ref == second
  end

  test "leaving the screen cancels the analysis, by Back or otherwise" do
    view = ImportScreen |> mount_screen() |> render_info({:files, :picked, [item()]})
    ref = analysis_ref()
    render_info(view, {:tap, :back})
    refute Fake.analysing?(ref)

    view = ImportScreen |> mount_screen() |> render_info({:files, :picked, [item()]})
    ref = analysis_ref()
    ImportScreen.terminate(:shutdown, view.socket)
    refute Fake.analysing?(ref)
  end

  test "the result says what it heard, with the clear chip and the notes" do
    view = ready()
    %{stats: stats, take: take} = assigns(view)

    assert stats.note_count == length(take.notes)
    assert stats.note_count >= 8
    assert stats.scale == Scale.new("E", :minor)
    assert text_of(view, "heard") == "Heard #{stats.note_count} notes"
    assert text_of(view, "stats") =~ ~r/^E minor · \d+ bpm · one voice$/
    assert "clear" in texts(view)
    assert find(view, :canvas, id: "notes")
    assert find(view, :canvas, id: "wave").props.on_drag
    assert "E minor ▾" in texts(view)
  end

  test "not an audio file, a decoding error, or no engine at all" do
    view =
      ImportScreen
      |> mount_screen()
      |> render_info({:files, :picked, [item("a.pdf", "application/pdf")]})

    assert assigns(view).stage == :choose
    assert text_of(view, "notice") == "That isn't an audio file."

    view = render_info(view, {:files, :picked, [item()]})
    ref = analysis_ref()
    :ok = Fake.analysis_error(ref, :not_supported)
    assert_receive {:hum_audio, ^ref, {:analysis_error, :not_supported}} = message
    failed = render_info(view, message)
    assert {:error, text} = assigns(failed).stage
    assert text == "This phone can't decode that kind of file."
    assert by_id(failed, "other_file")

    Application.put_env(:humdinger, :audio, Humdinger.NoSuchEngine)
    view = ImportScreen |> mount_screen() |> render_info({:files, :picked, [item()]})

    assert assigns(view).stage ==
             {:error, "This build has no audio engine, so it can't read audio files."}
  end

  test "dragging the end handle narrows the part used, and the notes follow when it lets go" do
    view = ready()
    before = assigns(view).stats.note_count

    view = wave(view, :began, x_of(@duration) + 2)
    assert %{target: :end} = assigns(view).wave_drag

    view = wave(view, :dragging, x_of(@duration) + 2 - (x_of(3000) - x_of(0)))
    assert assigns(view).selection == {0, 3000}
    # Still the old notes until the drag ends.
    assert assigns(view).stats.note_count == before

    view = wave(view, :ended, x_of(3000) + 2)
    assert assigns(view).wave_drag == nil
    assert assigns(view).take.duration_ms == 3000
    assert assigns(view).stats.note_count < before
    assert text_of(view, "using") == "using 0:00 – 0:03"
  end

  test "the box moves as a whole; a touch outside it pulls the nearer edge there" do
    view = ready() |> wave(:began, x_of(@duration) + 2) |> wave(:ended, x_of(3000) + 2)

    view = view |> wave(:began, x_of(4500)) |> wave(:ended, x_of(4500))
    assert assigns(view).selection == {0, 4500}

    view = view |> wave(:began, x_of(2000)) |> wave(:dragging, x_of(3000))
    assert assigns(view).selection == {1000, 5500}

    # A lost end: the quiet timer finishes the drag and transcribes.
    %{token: token} = assigns(view).wave_drag
    view = render_info(view, {:wave_quiet, token})
    assert assigns(view).wave_drag == nil
    assert assigns(view).take.duration_ms == 4500
  end

  test "Snap: chromatic, back to the key, or a key from the menu" do
    view = ready() |> render_info({:tap, :snap_chromatic})
    assert assigns(view).snap == :chromatic
    assert by_id(view, "seg_chromatic").props.background == Style.selected()
    # The scale segment still names the key it goes back to.
    assert "E minor ▾" in texts(view)

    view = render_info(view, {:tap, :snap_scale})
    assert assigns(view).snap == :detected
    assert sheet(view) == nil

    view = render_info(view, {:tap, :snap_scale})
    assert sheet(view)
    assert "Detected: E minor" in texts(view)

    view = view |> render_info({:tap, {:root, 9}}) |> render_info({:tap, {:mode, :dorian}})
    assert assigns(view).snap == Scale.new("A", :dorian)
    assert assigns(view).take.scale == Scale.new("A", :dorian)
    assert "A Dorian ▾" in texts(view)

    view =
      view
      |> render_info({:tap, :dismiss})
      |> render_info({:tap, :snap_scale})
      |> render_info({:tap, :snap_detected})

    assert assigns(view).snap == :detected
    assert sheet(view) == nil
  end

  test "Quantize and Ignore re-run the transcription" do
    view = ready()
    on_grid = assigns(view).take.notes

    view = render_info(view, {:tap, {:quantize, :off}})
    assert assigns(view).quantize == :off
    assert assigns(view).take.notes != on_grid

    view = Enum.reduce(1..5, view, fn _, v -> render_info(v, {:tap, {:min_ms, -20}}) end)
    assert assigns(view).min_ms == 20
    assert "20 ms" in texts(view)
    all = assigns(view).stats.note_count
    assert all == 12

    view = Enum.reduce(1..20, view, fn _, v -> render_info(v, {:tap, {:min_ms, 20}}) end)
    assert assigns(view).min_ms == 300
    # The quick 150 ms note goes; the eighths (317 ms sung) stay.
    assert assigns(view).stats.note_count == all - 1
    assert text_of(view, "heard") == "Heard 11 notes"
  end

  test "Edit as a phrase and Sheet music open the review with the notes" do
    view = ready()

    edit = render_info(view, {:tap, :edit})
    assert {:push, PhraseScreen, %{phrase: %Phrase{} = phrase, notify: notify}} = nav(edit)
    assert notify == self()
    assert phrase.name == "voice-memo"
    assert phrase.source == {:file, "voice-memo.m4a"}
    assert phrase.quantize == :q16
    assert length(phrase.notes) == assigns(view).stats.note_count

    staff = render_info(view, {:tap, :sheet_music})
    assert {:push, PhraseScreen, %{phrase: %Phrase{}, tab: :staff}} = nav(staff)
  end

  test "Export .mid shares the notes; Play out plays them and becomes Stop" do
    view = ready() |> render_info({:tap, :export_mid}) |> render_async()
    assert_receive {:share, path, "audio/midi", "voice-memo"}
    assert File.read!(path) =~ "MThd"

    # The phrase starts on the beat before the first note, so it may take a moment.
    view = render_info(view, {:tap, :play})
    assert_receive {:output, [{:note_on, 64, _}]}, 2000
    assert "Stop" in texts(view)

    view = render_info(view, {:tap, :play})
    assert_receive {:output, [{:note_off, 64}]}
    assert "Play out" in texts(view)
  end

  test "a share that fails comes back to the screen as a notice" do
    Share.set_error(:no_app)
    view = ready() |> render_info({:tap, :export_mid}) |> render_async()
    assert_receive {:mob_share, :error, :no_app} = error
    assert text_of(render_info(view, error), "notice") == "No app on this phone can take it."
  end

  test "every tap target keeps its tap through re-renders" do
    playing = ready() |> render_info({:tap, :play})

    for v <- [mount_screen(ImportScreen), playing, render_info(playing, {:tap, :snap_scale})] do
      assert_every_tap_held(v)
    end
  end
end
