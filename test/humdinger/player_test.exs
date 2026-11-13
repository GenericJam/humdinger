defmodule Humdinger.PlayerTest do
  # The output double reports through the application env.
  use ExUnit.Case, async: false

  alias Humdinger.Player
  alias Humdinger.Test.{Listener, Output}

  setup do
    Listener.listen()
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, player} = Player.start_link(output: Output, clock: fn -> Agent.get(clock, & &1) end)
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
        {:ok, player} = Player.start_link(output: Output, clock: fn -> 0 end)
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
end
