defmodule Humdinger.PlayerTest do
  # The output double reports through the application env.
  use ExUnit.Case, async: false

  alias Humdinger.Player
  alias Humdinger.Test.{FakeOutput, Listener}

  setup do
    Listener.listen()
    FakeOutput.reset()
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    {:ok, player} =
      Player.start_link(output: FakeOutput, clock: fn -> Agent.get(clock, & &1) end)

    %{clock: clock, player: player}
  end

  # Moves the fake clock to `t` and fires the player's pending timer now.
  defp at(%{clock: clock, player: player}, t) do
    Agent.update(clock, fn _ -> t end)

    case :sys.get_state(player).token do
      nil -> :ok
      token -> send(player, {:tick, token})
    end

    :sys.get_state(player)
    :ok
  end

  defp note(start, dur, midi, vel \\ 90),
    do: %{start_ms: start, dur_ms: dur, midi: midi, velocity: vel}

  defmodule FakeAudio do
    @key {__MODULE__, :cfg}

    def configure(test_pid, reply \\ :ok, cancel \\ :ok) do
      :persistent_term.put(@key, %{test: test_pid, reply: reply, cancel: cancel})
    end

    def clear, do: :persistent_term.erase(@key)

    def play_piano(owner, notes) do
      cfg = :persistent_term.get(@key)

      case cfg.reply do
        :ok ->
          ref = make_ref()
          send(cfg.test, {:audio_call, {:play_piano, owner, notes, ref}})
          {:ok, ref}

        {:error, reason} = err ->
          send(cfg.test, {:audio_call, {:play_piano_error, owner, notes, reason}})
          err
      end
    end

    def cancel_piano(ref) do
      case :persistent_term.get(@key, nil) do
        %{test: test, cancel: cancel} ->
          send(test, {:audio_call, {:cancel_piano, ref}})
          cancel

        nil ->
          :ok
      end
    end
  end

  defmodule DyingSessionOutput do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def acquire(owner, server), do: GenServer.call(server, {:acquire, owner})
    def session_events(_ref, _events, _server), do: :ok
    def release(_ref, _server), do: :ok

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:acquire, owner}, from, test) do
      ref = make_ref()
      send(test, {:session_output, {:acquire, owner, ref}})
      GenServer.reply(from, {:ok, ref})
      {:stop, :normal, test}
    end
  end

  defmodule SessionOutput do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def acquire(owner, server), do: GenServer.call(server, {:acquire, owner})
    def session_events(ref, events, server), do: GenServer.call(server, {:events, ref, events})
    def release(ref, server), do: GenServer.call(server, {:release, ref})

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:acquire, owner}, _from, test) do
      ref = make_ref()
      send(test, {:session_output, {:acquire, owner, ref}})
      {:reply, {:ok, ref}, test}
    end

    def handle_call({:events, ref, events}, _from, test) do
      send(test, {:session_output, {:events, ref, events}})
      {:reply, :ok, test}
    end

    def handle_call({:release, ref}, _from, test) do
      send(test, {:session_output, {:release, ref}})
      {:reply, :ok, test}
    end
  end

  defp start_piano_player(audio_reply \\ :ok) do
    FakeAudio.configure(self(), audio_reply)
    on_exit(fn -> FakeAudio.clear() end)
    out = start_supervised!(Supervisor.child_spec({SessionOutput, self()}, restart: :temporary))

    player =
      start_supervised!(
        {Player,
         owner: self(), output: {SessionOutput, out}, audio: FakeAudio, clock: fn -> 0 end}
      )

    %{out: out, player: player}
  end

  test "the timeline batches events at the same time, note offs first" do
    assert Player.timeline([note(0, 500, 62), note(500, 250, 62, 70), note(750, 250, 64)]) == [
             {0, [{:note_on, 62, 90}]},
             {500, [{:note_off, 62}, {:note_on, 62, 70}]},
             {750, [{:note_off, 62}, {:note_on, 64, 90}]},
             {1000, [{:note_off, 64}]}
           ]
  end

  test "notes go out when the clock reaches them, and the owner hears when it ends", ctx do
    :ok = Player.play(ctx.player, [note(0, 500, 62), note(500, 500, 64)], :riff)
    assert_receive {:output, [{:note_on, 62, 90}]}
    assert Player.playing(ctx.player) == :riff

    at(ctx, 499)
    refute_received {:output, _}

    at(ctx, 500)
    assert_received {:output, [{:note_off, 62}, {:note_on, 64, 90}]}

    at(ctx, 1000)
    assert_received {:output, [{:note_off, 64}]}
    assert_received {:player, :finished, :riff}
    assert Player.playing(ctx.player) == nil
  end

  test "a late tick sends every batch that came due, in order", ctx do
    :ok = Player.play(ctx.player, [note(0, 200, 60), note(200, 200, 62), note(400, 200, 64)], :x)
    assert_receive {:output, [{:note_on, 60, 90}]}

    at(ctx, 450)

    assert_received {:output, [{:note_off, 60}, {:note_on, 62, 90}]}
    assert_received {:output, [{:note_off, 62}, {:note_on, 64, 90}]}
    refute_received {:player, :finished, _}

    at(ctx, 600)
    assert_received {:output, [{:note_off, 64}]}
    assert_received {:player, :finished, :x}
  end

  test "stop silences the sounding note and sends no finish", ctx do
    :ok = Player.play(ctx.player, [note(0, 1000, 67)], :x)
    assert_receive {:output, [{:note_on, 67, 90}]}

    :ok = Player.stop(ctx.player)
    assert_received {:output, [{:note_off, 67}]}

    at(ctx, 2000)
    refute_received {:output, _}
    refute_received {:player, :finished, _}
  end

  test "playing something else first silences what was playing", ctx do
    :ok = Player.play(ctx.player, [note(0, 1000, 67)], :a)
    assert_receive {:output, [{:note_on, 67, 90}]}

    :ok = Player.play(ctx.player, [note(0, 500, 60)], :b)
    assert_received {:output, [{:note_off, 67}]}
    assert_received {:output, [{:note_on, 60, 90}]}
    assert Player.playing(ctx.player) == :b
  end

  test "overlapping notes of one pitch re-strike instead of leaving one hanging", ctx do
    :ok = Player.play(ctx.player, [note(0, 600, 62), note(300, 600, 62)], :x)
    assert_receive {:output, [{:note_on, 62, 90}]}

    at(ctx, 300)
    assert_received {:output, [{:note_off, 62}, {:note_on, 62, 90}]}

    # The first note's end finds the pitch re-struck and sounding: it ends it;
    # the second's end then has nothing left to stop.
    at(ctx, 600)
    assert_received {:output, [{:note_off, 62}]}
    at(ctx, 900)
    refute_received {:output, _}
    assert_received {:player, :finished, :x}
  end

  test "when its screen goes, the player stops and silences the note" do
    test = self()

    owner =
      spawn(fn ->
        {:ok, player} = Player.start_link(output: FakeOutput, clock: fn -> 0 end)
        send(test, {:player, player})
        Player.play(player, [note(0, 1000, 70)], :x)
        receive do: (:go -> exit(:shutdown))
      end)

    assert_receive {:player, player}
    assert_receive {:output, [{:note_on, 70, 90}]}
    ref = Process.monitor(player)

    send(owner, :go)
    assert_receive {:DOWN, ^ref, :process, ^player, _}
    assert_received {:output, [{:note_off, 70}]}
  end

  describe "local piano mode" do
    test "acquires output, starts native audio without MIDI events, and forwards positions/finish" do
      %{player: player} = start_piano_player()
      notes = [note(0, 500, 62), note(500, 250, 64)]
      tag = make_ref()

      assert :ok = Player.play(player, notes, tag, mode: :piano)
      assert Player.playing(player) == tag

      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, ^notes, pref}}
      refute_received {:session_output, {:events, _, _}}

      send(player, {:hum_audio, pref, {:piano_position, 140}})
      assert_receive {:player, :position, ^tag, 140}

      send(player, {:hum_audio, pref, :piano_finished})
      assert_receive {:session_output, {:release, ^sref}}
      assert_receive {:player, :finished, ^tag}
      assert Player.playing(player) == nil
      refute_received {:audio_call, {:cancel_piano, _}}
    end

    test "stop cancels native before releasing output and ignores late native messages" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 800, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      assert :ok = Player.stop(player)
      assert Player.playing(player) == nil

      # Verify cancel happened before release in the mailbox.
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:session_output, {:release, ^sref}}

      send(player, {:hum_audio, pref, {:piano_position, 300}})
      send(player, {:hum_audio, pref, :piano_finished})
      send(player, {:hum_audio, pref, {:piano_error, :late}})
      _ = :sys.get_state(player)
      refute_received {:player, _, _, _}
      refute_received {:player, _, _}
    end

    test "rapid replay cancels previous native ref, keeps session, and ignores stale refs" do
      %{player: player} = start_piano_player()
      tag1 = make_ref()
      tag2 = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag1, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, _sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref1}}

      assert :ok = Player.play(player, [note(0, 500, 64)], tag2, mode: :piano)
      assert_receive {:audio_call, {:cancel_piano, ^pref1}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref2}}
      assert pref1 != pref2
      assert Player.playing(player) == tag2

      send(player, {:hum_audio, pref1, {:piano_position, 100}})
      send(player, {:hum_audio, pref1, :piano_finished})
      _ = :sys.get_state(player)
      refute_received {:player, :position, ^tag1, _}
      refute_received {:player, :finished, ^tag1}

      send(player, {:hum_audio, pref2, {:piano_position, 55}})
      assert_receive {:player, :position, ^tag2, 55}
    end

    test "switching from piano to MIDI mode cancels native before sending MIDI" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      assert :ok = Player.play(player, [note(0, 500, 67)], :midi_tag)
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:session_output, {:events, _, [{:note_on, 67, 90}]}}

      send(player, {:hum_audio, pref, {:piano_position, 50}})
      _ = :sys.get_state(player)
      refute_received {:player, :position, _, _}
    end

    test "synchronous play_piano failure releases output and returns error" do
      %{player: player} = start_piano_player({:error, :unavailable})
      tag = make_ref()

      assert {:error, :unavailable} = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano_error, ^player, _, :unavailable}}
      assert_receive {:session_output, {:release, ^sref}}
      assert Player.playing(player) == nil
      refute_received {:player, _, _, _}
    end

    test "async piano_error releases output and notifies owner" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      send(player, {:hum_audio, pref, {:piano_error, :audio_lost}})
      assert_receive {:session_output, {:release, ^sref}}
      assert_receive {:player, :error, ^tag, :audio_lost}
      assert Player.playing(player) == nil
    end

    test "output preemption cancels native and finishes owner" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      send(player, {:output, :session_ended, sref})
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:player, :finished, ^tag}
      assert Player.playing(player) == nil
    end

    test "output server death cancels native and finishes owner" do
      %{out: out, player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, _sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      GenServer.stop(out)
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:player, :finished, ^tag}
      assert Player.playing(player) == nil
    end

    test "owner exit cancels native and releases output" do
      %{out: out} = start_piano_player()
      test = self()

      owner =
        spawn(fn ->
          {:ok, player} =
            Player.start_link(output: {SessionOutput, out}, audio: FakeAudio, clock: fn -> 0 end)

          send(test, {:player, player})
          :ok = Player.play(player, [note(0, 1000, 60)], make_ref(), mode: :piano)
          receive do: (:go -> exit(:shutdown))
        end)

      assert_receive {:player, player}
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}
      mon = Process.monitor(player)

      send(owner, :go)
      assert_receive {:DOWN, ^mon, :process, ^player, _}
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:session_output, {:release, ^sref}}
    end

    test "stop when cancel returns stream_stuck releases the session and returns the error" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 800, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      FakeAudio.configure(self(), :ok, {:error, :stream_stuck})
      assert {:error, :stream_stuck} = Player.stop(player)
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:session_output, {:release, ^sref}}
      assert Player.playing(player) == nil
    end

    test "replaying over a stuck preview refuses, releases the session, and notifies the owner" do
      %{player: player} = start_piano_player()
      old_tag = make_ref()
      new_tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], old_tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      FakeAudio.configure(self(), :ok, {:error, :stream_stuck})

      assert {:error, :stream_stuck} =
               Player.play(player, [note(0, 500, 64)], new_tag, mode: :piano)

      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      refute_received {:audio_call, {:play_piano, _, _, _}}
      assert_receive {:session_output, {:release, ^sref}}
      assert_receive {:player, :error, ^old_tag, :stream_stuck}
      assert Player.playing(player) == nil
    end

    test "session_ended with a stuck cancel notifies owner with an error instead of finished" do
      %{player: player} = start_piano_player()
      tag = make_ref()

      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}

      FakeAudio.configure(self(), :ok, {:error, :stream_stuck})
      send(player, {:output, :session_ended, sref})

      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:player, :error, ^tag, :stream_stuck}
      refute_received {:player, :finished, ^tag}
      assert Player.playing(player) == nil
    end

    test "an unresolvable output returns output_down without starting audio or emitting notes" do
      FakeAudio.configure(self())
      on_exit(fn -> FakeAudio.clear() end)

      player =
        start_supervised!(
          {Player,
           owner: self(),
           output: {SessionOutput, :no_such_humdinger_output},
           audio: FakeAudio,
           clock: fn -> 0 end}
        )

      assert {:error, :output_down} =
               Player.play(player, [note(0, 500, 60)], make_ref(), mode: :piano)

      refute_received {:audio_call, _}
      assert Player.playing(player) == nil

      assert {:error, :output_down} = Player.play(player, [note(0, 500, 60)], :midi_tag)
      refute_received {:session_output, _}
      refute_received {:output, _}
      assert Player.playing(player) == nil
    end

    test "an output that dies right after granting a session cancels the preview and finishes" do
      FakeAudio.configure(self())
      on_exit(fn -> FakeAudio.clear() end)

      out =
        start_supervised!(
          Supervisor.child_spec({DyingSessionOutput, self()}, restart: :temporary)
        )

      player =
        start_supervised!(
          {Player,
           owner: self(), output: {DyingSessionOutput, out}, audio: FakeAudio, clock: fn -> 0 end}
        )

      tag = make_ref()
      assert :ok = Player.play(player, [note(0, 500, 60)], tag, mode: :piano)
      assert_receive {:session_output, {:acquire, ^player, _sref}}
      assert_receive {:audio_call, {:play_piano, ^player, _, pref}}
      assert_receive {:audio_call, {:cancel_piano, ^pref}}
      assert_receive {:player, :finished, ^tag}
      assert Player.playing(player) == nil
    end
  end
end
