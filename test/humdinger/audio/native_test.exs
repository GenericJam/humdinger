defmodule Humdinger.Audio.NativeTest do
  use ExUnit.Case, async: true

  alias Humdinger.Audio.Native

  test "returns {:error, :unsupported} instead of faking success when NIF is not loaded" do
    assert {:error, :unsupported} =
             Native.play_piano(self(), [%{start_ms: 0, dur_ms: 250, midi: 60}])
  end
end
