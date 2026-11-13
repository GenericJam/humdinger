defmodule Humdinger.LiveFeedTest do
  use ExUnit.Case, async: true

  alias Humdinger.LiveFeed

  defp frame(t, pitch, note), do: %{t: t, pitch: pitch, note: note}

  test "notes start and end as the sent note changes" do
    feed =
      LiveFeed.new()
      |> LiveFeed.push(frame(0, nil, nil))
      |> LiveFeed.push(frame(100, 69.1, 69))
      |> LiveFeed.push(frame(200, 70.9, 71))
      |> LiveFeed.push(frame(300, nil, nil))

    assert LiveFeed.notes(feed) == [
             %{start_ms: 100, end_ms: 200, midi: 69},
             %{start_ms: 200, end_ms: 300, midi: 71}
           ]

    assert LiveFeed.trace(feed) == [{100, 69.1}, {200, 70.9}, {300, nil}]
    assert LiveFeed.pitch(feed) == nil
  end

  test "silence is one gap, not a sample per frame" do
    feed =
      Enum.reduce(
        [frame(0, 60.0, 60), frame(33, nil, nil), frame(66, nil, nil)],
        LiveFeed.new(),
        &LiveFeed.push(&2, &1)
      )

    assert LiveFeed.trace(feed) == [{0, 60.0}, {33, nil}]
  end

  test "drops what ended before the window, keeping one sample to enter from" do
    feed =
      Enum.reduce(0..100, LiveFeed.new(1_000), fn i, f ->
        LiveFeed.push(f, frame(i * 100, 60.0, 60))
      end)

    [{first, _} | _] = LiveFeed.trace(feed)
    assert first == 8_900
    assert [%{end_ms: nil}] = LiveFeed.notes(feed)
    assert LiveFeed.visible?(feed, 4_000)
  end

  test "is invisible once everything left the window" do
    feed =
      LiveFeed.new()
      |> LiveFeed.push(frame(0, 60.0, 60))
      |> LiveFeed.push(frame(100, nil, nil))
      |> LiveFeed.push(frame(5_000, nil, nil))

    refute LiveFeed.visible?(feed, 4_000)
    refute LiveFeed.visible?(LiveFeed.new(), 4_000)
  end

  test "a frame from an earlier time starts over; frames without a time are ignored" do
    feed = LiveFeed.new() |> LiveFeed.push(frame(5_000, 60.0, 60))
    assert LiveFeed.push(feed, frame(nil, 61.0, 61)) == feed
    restarted = LiveFeed.push(feed, frame(10, 62.0, 62))
    assert LiveFeed.notes(restarted) == [%{start_ms: 10, end_ms: nil, midi: 62}]
  end
end
