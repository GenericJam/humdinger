# The First run range step, end to end on a connected Android phone: the
# Mac's speaker plays a low tone, then a higher one, each long enough for a
# 2 s hold, and the step must take both (the Engine's real readings through
# the Tracker into Humdinger.RangeFinder). The saved range is put back
# afterwards.
#
#   mix mob.connect --no-iex --android-only --device <serial>
#   adb -s <serial> shell pm grant com.genericjam.humdinger android.permission.RECORD_AUDIO
#   SERIAL=<serial> [LOW_HZ=220] [HIGH_HZ=330] [VOLUME=8] mix run --no-start scripts/first_run_check.exs
#
# Put the phone by the Mac's speaker. The Mac mini's speaker is weak below
# ~200 Hz; afplay's -v 8 is loud.

serial = System.fetch_env!("SERIAL")

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"first_run_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

low_hz = String.to_integer(System.get_env("LOW_HZ", "220"))
high_hz = String.to_integer(System.get_env("HIGH_HZ", "330"))
volume = System.get_env("VOLUME", "8")

tone = fn hz, secs ->
  path = "/tmp/hum_first_run_#{hz}.wav"

  {_, 0} =
    System.cmd(
      "ffmpeg",
      ~w(-v error -y -f lavfi -i sine=frequency=#{hz}:duration=#{secs}:sample_rate=48000 #{path})
    )

  System.cmd("afplay", ["-v", volume, path])
end

saved_range = :rpc.call(node, Humdinger.Engine, :settings, []).range
:ok = Mob.Test.navigate(node, Humdinger.FirstRunScreen, %{step: :range, only: true})
Process.sleep(1_500)
# Listen afresh: a script's own Native.listen (realtime_check.exs) takes the
# microphone from the Engine, which would go on believing it listens.
_ = :rpc.call(node, Humdinger.Engine, :stop, [])
_ = :rpc.call(node, Humdinger.Engine, :listen, [])
Process.sleep(1_000)

finder = fn -> Mob.Test.assigns(node).finder end

IO.puts(
  "engine #{inspect(:rpc.call(node, Humdinger.Engine, :status, []))}, finder phase #{finder.().phase}"
)

t0 = System.monotonic_time(:millisecond)
tone.(low_hz, 3.5)
f = finder.()

IO.puts(
  "after #{low_hz} Hz: phase #{f.phase}, low #{inspect(f.low)} (#{System.monotonic_time(:millisecond) - t0} ms)"
)

Process.sleep(700)
tone.(high_hz, 3.5)
Process.sleep(500)
f = finder.()
info = :rpc.call(node, Humdinger.Audio.Native, :info, [])
IO.puts("after #{high_hz} Hz: phase #{f.phase}, low #{inspect(f.low)}, high #{inspect(f.high)}")

IO.puts(
  "engine during the run: lag mean #{Float.round(info.lag_mean_ms, 1)} max #{Float.round(info.lag_max_ms, 1)} ms, " <>
    "reading #{Float.round(info.detect_us_mean, 0)} µs, skipped #{Float.round(info.skipped_ms, 0)} ms"
)

expected = {round(69 + 12 * :math.log2(low_hz / 440)), round(69 + 12 * :math.log2(high_hz / 440))}
ok = f.phase == :done and {f.low, f.high} == expected

IO.puts(
  if ok,
    do: "range step completed: #{inspect({f.low, f.high})}",
    else: "FAILED: expected #{inspect(expected)}"
)

:rpc.call(node, Humdinger.Engine, :update_settings, [%{range: saved_range}])
Mob.Test.pop(node)
