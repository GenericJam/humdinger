defmodule Humdinger.Engine.NoticeTest do
  use ExUnit.Case, async: true

  alias Humdinger.Engine.Notice

  @singing %{note: 69, cents: -12.4}
  @quiet %{note: nil, cents: nil}

  test "listening shows the note and cents, where it goes and the channel" do
    assert Notice.build(:listening, false, @singing, "FMutate A", 1) ==
             %{
               title: "Humdinger · listening",
               text: "A4 −12¢ → FMutate A · ch 1",
               state: :listening
             }

    assert Notice.build(:listening, false, @quiet, "FMutate A", 3).text ==
             "listening… → FMutate A · ch 3"

    assert Notice.build(:listening, false, %{note: 62, cents: nil}, nil, 1).text == "D4 · ch 1"
  end

  test "recording and paused change the title and the buttons" do
    assert %{title: "Humdinger · recording", state: :recording, text: "A4 −12¢ → X · ch 1"} =
             Notice.build(:listening, true, @singing, "X", 1)

    assert %{title: "Humdinger · paused", state: :paused, text: "paused → X · ch 1"} =
             Notice.build(:paused, true, @singing, "X", 1)
  end

  test "a microphone error offers Resume" do
    for {reason, words} <- [
          permission: "microphone not allowed",
          device_lost: "microphone disconnected",
          microphone_unavailable: "microphone in use",
          input_error: "microphone stopped"
        ] do
      assert Notice.build({:error, reason}, false, @quiet, "X", 1) == %{
               title: "Humdinger · no microphone",
               text: words <> " · Resume to try again",
               state: :paused
             }
    end
  end

  test "the destination is the first enabled and available one" do
    d = fn name, enabled, available -> %{name: name, enabled: enabled, available: available} end

    assert Notice.destination([
             d.("FMutate A", true, false),
             d.("Port", false, true),
             d.("USB", true, true)
           ]) ==
             "USB"

    assert Notice.destination([d.("FMutate A", true, true), d.("Port", true, true)]) ==
             "FMutate A"

    assert Notice.destination([d.("FMutate", true, false)]) == nil
    assert Notice.destination([]) == nil
  end
end
