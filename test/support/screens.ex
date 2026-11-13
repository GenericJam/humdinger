defmodule Humdinger.Test.Screens do
  @moduledoc """
  Helpers for screen tests that run against a real `Humdinger.Engine` on
  `Humdinger.Test.FakeAudio` and `Humdinger.Test.FakeOutput`.

  A screen mounted with `Mob.ScreenCase.mount_screen/2` runs in the test
  process, so the Engine's frames and the screen's own timers arrive in the
  test's mailbox: `pump/2` hands them to the screen (`render_info/2`) until
  nothing more comes for `quiet_ms`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Humdinger.{Engine, Music, Settings}
  alias Humdinger.Test.{FakeAudio, FakeOutput}

  @doc """
  Saved settings, fresh fakes and an Engine named `Humdinger.Engine`.
  Screen tests sing in bursts and then look, so the Engine waits a minute,
  not 150 ms, before it treats missing readings as a stalled input.
  """
  def start_engine(settings \\ %{}) do
    Mob.State.delete(:settings)
    {:ok, saved} = Settings.merge(Settings.defaults(), settings)
    :ok = Settings.save(saved)
    FakeAudio.reset()
    FakeOutput.reset()

    for {key, value} <- [audio: FakeAudio, output: FakeOutput] do
      previous = Application.fetch_env(:humdinger, key)
      Application.put_env(:humdinger, key, value)
      on_exit(fn -> restore_env(key, previous) end)
    end

    start_supervised!({Engine, audio: FakeAudio, output: FakeOutput, stall_ms: 60_000})
    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:humdinger, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:humdinger, key)

  @doc "Readings of a steady pitch (or silence for nil) every 5 ms from `from` for `ms`."
  def readings(from, ms, pitch, db \\ -30.0) do
    for t <- from..(from + ms - 1)//5 do
      case pitch do
        nil -> %{t: t, hz: nil, clarity: 0.1, db: -75.0}
        p -> %{t: t, hz: Music.midi_to_hz(p), clarity: 0.95, db: db}
      end
    end
  end

  @doc "Sing `readings` into the live microphone (in the phone's batches of two)."
  def sing(readings) do
    ref = FakeAudio.current()
    assert ref, "the microphone isn't on"
    readings |> Enum.chunk_every(2) |> Enum.each(&FakeAudio.sing(ref, &1))
    Engine.status()
    :ok
  end

  @screen_messages [:engine, :output, :tick, :blink, :rec_tick, :toast_off, :drag_quiet]

  @doc "Deliver every screen-bound message until none arrives for `quiet_ms`."
  def pump(view, quiet_ms \\ 80) do
    receive do
      message when is_tuple(message) and elem(message, 0) in @screen_messages ->
        pump(Mob.ScreenCase.render_info(view, message), quiet_ms)

      :first_run ->
        pump(Mob.ScreenCase.render_info(view, :first_run), quiet_ms)
    after
      quiet_ms -> view
    end
  end

  @doc """
  After `sing/1`: wait (up to 2 s; host timers can be late) for the Engine's
  next frame, which carries everything sung so far, then for the screen's
  tick that shows it, then `pump/2`.
  """
  def pump_frame(view) do
    receive do
      {:engine, :frame, _} = message ->
        view |> Mob.ScreenCase.render_info(message) |> await_tick() |> pump()

      message when is_tuple(message) and elem(message, 0) in @screen_messages ->
        view |> Mob.ScreenCase.render_info(message) |> pump_frame()
    after
      2_000 -> ExUnit.Assertions.flunk("no frame from the Engine")
    end
  end

  @doc "Wait (up to 2 s) until the screen's pending tick has been delivered."
  def await_tick(view) do
    if Mob.ScreenCase.assigns(view).tick_token == nil do
      view
    else
      receive do
        message when is_tuple(message) and elem(message, 0) in @screen_messages ->
          view |> Mob.ScreenCase.render_info(message) |> await_tick()
      after
        2_000 -> ExUnit.Assertions.flunk("no tick")
      end
    end
  end

  @doc """
  Every node with an `on_tap` also has `on_press_out` (MOB-509: the screen
  re-renders on frames, and Android drops a plain tap from an older render).
  """
  def assert_every_tap_held(view) do
    taps = for node <- Mob.ScreenCase.flatten(view), node.props[:on_tap] != nil, do: node
    assert taps != [], "no tap targets rendered"

    for node <- taps do
      assert node.props[:on_press_out] != nil,
             "#{node.type} with on_tap #{inspect(node.props.on_tap)} has no on_press_out"
    end

    length(taps)
  end

  @doc "The tag of every tap target in the view."
  def tap_tags(view) do
    for node <- Mob.ScreenCase.flatten(view), tap = node.props[:on_tap], do: elem(tap, 1)
  end

  @doc "All the visible strings."
  def texts(view) do
    for node <- Mob.ScreenCase.flatten(view), node.type == :text, do: node.props.text
  end
end
