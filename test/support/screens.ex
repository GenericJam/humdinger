defmodule Humdinger.Test.Screens do
  @moduledoc """
  Helpers for screen tests (`import Humdinger.Test.Screens`).

  Queries on a mounted view: `texts/1`, `tap_tags/1`, `by_id/2`,
  `text_of/2`, `sheet/1`, `nav/1`, and `assert_every_tap_held/1`.

  Screens that run against a real `Humdinger.Engine` on
  `Humdinger.Audio.Fake` and `Humdinger.Test.FakeOutput`: `start_engine/1`,
  `readings/4`, `sing/1`. A screen mounted with
  `Mob.ScreenCase.mount_screen/2` runs in the test process, so the Engine's
  frames and the screen's own timers arrive in the test's mailbox:
  `pump/2` hands them to the screen (`render_info/2`) until nothing more
  comes for `quiet_ms`, `pump_frame/1` waits for the next frame first.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Mob.ScreenCase, only: [flatten: 1, find: 3]

  alias Humdinger.Audio.Fake
  alias Humdinger.{Engine, Music, Settings}
  alias Humdinger.Test.{FakeBackground, FakeOutput}

  # ── Queries ─────────────────────────────────────────────────────────────

  @doc "Every Text string on screen, in order."
  def texts(view), do: for(%{type: :text, props: %{text: t}} <- flatten(view), do: t)

  @doc "The tag of every tap target in the view."
  def tap_tags(view), do: for(%{props: %{on_tap: {_pid, tag}}} <- flatten(view), do: tag)

  @doc "The node with `id`, any type."
  def by_id(view, id), do: Enum.find(flatten(view), &(&1.props[:id] == id))

  @doc "The text of the `<Text>` with `id`."
  def text_of(view, id), do: find(view, :text, id: id).props.text

  @doc "The open sheet node, or nil."
  def sheet(view), do: Enum.find(flatten(view), &(&1.type == :sheet))

  @doc "The nav action the last event recorded (`{:push, dest, params}`, `{:pop}`, …)."
  def nav(view), do: Map.get(view.socket.__mob__, :nav_action)

  @doc """
  Every tap target also has `on_press_out={held()}` (MOB-509: the screens
  re-render on frames, output events or a playing phrase, and Android drops
  a plain tap from an older render). Returns how many there are.
  """
  def assert_every_tap_held(view) do
    taps = for node <- flatten(view), node.props[:on_tap] != nil, do: node
    assert taps != [], "no tap targets rendered"

    for node <- taps do
      assert node.props[:on_press_out] == {self(), :held},
             "#{node.type} with on_tap #{inspect(node.props.on_tap)} has no on_press_out={held()}"
    end

    length(taps)
  end

  # ── A real Engine on the doubles ────────────────────────────────────────

  @doc """
  Saved settings, fresh doubles and an Engine named `Humdinger.Engine`.
  Screen tests sing in bursts and then look, so the Engine waits a minute,
  not 150 ms, before it treats missing readings as a stalled input.
  """
  def start_engine(settings \\ %{}) do
    Mob.State.delete(:settings)
    {:ok, saved} = Settings.merge(Settings.defaults(), settings)
    :ok = Settings.save(saved)
    Fake.reset()
    FakeOutput.reset()
    FakeBackground.reset()

    for {key, value} <- [audio: Fake, output: FakeOutput, background: FakeBackground] do
      previous = Application.fetch_env(:humdinger, key)
      Application.put_env(:humdinger, key, value)
      on_exit(fn -> restore_env(key, previous) end)
    end

    start_supervised!(
      {Engine, audio: Fake, output: FakeOutput, background: FakeBackground, stall_ms: 60_000}
    )

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
    ref = Fake.current()
    assert ref, "the microphone isn't on"
    readings |> Enum.chunk_every(2) |> Enum.each(&Fake.sing(ref, &1))
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
      2_000 -> flunk("no frame from the Engine")
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
        2_000 -> flunk("no tick")
      end
    end
  end
end
