defmodule Humdinger.BackgroundTest do
  # The Fake engine is one per VM: not async.
  use ExUnit.Case, async: false

  alias Humdinger.Audio.Fake
  alias Humdinger.Background

  setup do
    Fake.reset()
    :ok
  end

  test "start shows the notice, filling in what's missing" do
    refute Background.running?()
    assert :ok = Background.start(%{text: "A4 −12¢ → FMutate A · ch 1"})
    assert Background.running?()
    owner = self()

    assert %{
             owner: ^owner,
             notice: %{
               title: "Humdinger · listening",
               text: "A4 −12¢ → FMutate A · ch 1",
               state: :listening
             }
           } = Fake.background()
  end

  test "update changes the notice; before start it says so" do
    assert {:error, :not_running} = Background.update(text: "A4")
    :ok = Background.start(self(), [])

    assert :ok =
             Background.update(title: "Humdinger · recording", text: "C5 +3¢", state: :recording)

    assert %{notice: %{title: "Humdinger · recording", text: "C5 +3¢", state: :recording}} =
             Fake.background()
  end

  test "button taps go to the process that started it, latest start wins" do
    :ok = Background.start(self(), [])
    :ok = Fake.tap_background(:pause)
    assert_receive {:background, :pause}

    other = spawn(fn -> receive do: (msg -> send(:background_test, {:other_got, msg})) end)
    Process.register(self(), :background_test)
    :ok = Background.start(other, state: :paused)
    :ok = Fake.tap_background(:resume)
    assert_receive {:other_got, {:background, :resume}}
    refute_received {:background, :resume}
  end

  test "stop takes it away; taps then go nowhere" do
    :ok = Background.start(self(), [])
    assert :ok = Background.stop()
    refute Background.running?()
    assert {:error, :not_running} = Fake.tap_background(:stop)
    assert :ok = Background.stop()
  end

  test "it stops when its owner exits, but not when an earlier owner does" do
    first = spawn(fn -> receive do: (:go -> :ok) end)
    second = spawn(fn -> receive do: (:go -> :ok) end)
    :ok = Background.start(first, [])
    :ok = Background.start(second, [])

    send(first, :go)
    # The service hears of exits through its own monitor, in its own time.
    Process.sleep(20)
    assert Background.running?()

    send(second, :go)
    assert Enum.any?(1..200, fn _ -> not Background.running?() or Process.sleep(1) == :never end)
  end

  test "a dead owner can't start it" do
    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    assert {:error, :owner_dead} = Background.start(owner, [])
    refute Background.running?()
  end

  test "without the microphone permission it won't start" do
    :ok = Fake.set_permission(false)
    assert {:error, :permission} = Background.start(self(), [])
    refute Background.running?()
  end

  test "a malformed notice is rejected before it reaches the phone" do
    assert_raise ArgumentError, fn -> Background.start(self(), state: :singing) end
    assert_raise ArgumentError, fn -> Background.start(self(), text: :a4) end
    refute Background.running?()
  end
end
