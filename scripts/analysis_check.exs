# Checks that file analyses end when they should on a connected Android
# phone, over Erlang distribution: cancel_analysis/1, a second analysis by the
# same owner, the owner's death, the two-owner cap, and the Import screen
# (another file, Back, pop). Each check reads the engine's running count
# (`Humdinger.Audio.Native.info().analyses`) and the app's CPU time.
#
#   adb -s <serial> push long.m4a /data/local/tmp/hum_long_ok.m4a
#   adb -s <serial> shell run-as com.genericjam.humdinger cp /data/local/tmp/hum_long_ok.m4a files/
#   mix mob.connect --no-iex --android-only --device <serial>
#   SERIAL=<serial> mix run --no-start scripts/analysis_check.exs
#
# The file must be under 10 minutes and take several seconds to decode (a
# 9-minute m4a takes ~40 s on a moto g power).

serial = System.fetch_env!("SERIAL")

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"analysis_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

file = System.get_env("FILE", "/data/data/com.genericjam.humdinger/files/hum_long_ok.m4a")
adb = fn args -> elem(System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true), 0) end
app_pid = String.trim(adb.(~w(shell pidof com.genericjam.humdinger)))
results = :ets.new(:results, [:ordered_set, :public])

check = fn name, ok? ->
  :ets.insert(results, {System.unique_integer([:monotonic]), name, ok?})
  IO.puts("#{if ok?, do: "ok  ", else: "FAIL"} #{name}")
end

running = fn -> :rpc.call(node, Humdinger.Audio.Native, :info, []).analyses end

# The app's CPU time (utime + stime, clock ticks) over `ms`, as a share of one core.
cpu = fn ms ->
  ticks = fn ->
    adb.(["shell", "cat", "/proc/#{app_pid}/stat"])
    |> String.split(") ")
    |> List.last()
    |> String.split()
    |> then(fn f -> String.to_integer(Enum.at(f, 11)) + String.to_integer(Enum.at(f, 12)) end)
  end

  a = ticks.()
  Process.sleep(ms)
  (ticks.() - a) / (ms / 10) * 100
end

# A process on the phone that keeps what it receives.
compiled =
  :rpc.call(node, Code, :compile_string, [
    """
    defmodule HumAnalysisCheck.Owner do
      def start, do: spawn(fn -> loop([]) end)

      defp loop(got) do
        receive do
          {:report, from} -> send(from, {:report, self(), Enum.reverse(got)}); loop(got)
          :exit -> :ok
          msg -> loop([msg | got])
        end
      end
    end
    """
  ])

true = is_list(compiled)
owner = fn -> :rpc.call(node, HumAnalysisCheck.Owner, :start, []) end

got = fn pid ->
  send(pid, {:report, self()})
  receive do: ({:report, ^pid, msgs} -> msgs), after: (5_000 -> raise("no report"))
end

analyze = fn pid -> :rpc.call(node, Humdinger.Audio.Native, :analyze_file, [pid, file, []]) end
cancel = fn ref -> :rpc.call(node, Humdinger.Audio.Native, :cancel_analysis, [ref]) end

wait_idle = fn ->
  Enum.find_value(1..100, false, fn _ ->
    if running.() == 0, do: true, else: Process.sleep(50) && nil
  end)
end

# The app's own load before any analysis (the Live screen, listening).
idle = cpu.(2_000)
IO.puts("idle CPU: #{round(idle)}% of a core")

# ── 1. cancel_analysis ──
o1 = owner.()
{:ok, ref} = analyze.(o1)
Process.sleep(1_000)
busy = cpu.(2_000)

check.(
  "decoding: one running, CPU #{round(busy)}% of a core",
  running.() == 1 and busy > idle + 40
)

t = System.monotonic_time(:millisecond)
:ok = cancel.(ref)
stopped = wait_idle.()
check.("cancel_analysis: thread gone in #{System.monotonic_time(:millisecond) - t} ms", stopped)
idle_after = cpu.(2_000)

check.(
  "after cancel: CPU #{round(idle_after)}% of a core (idle #{round(idle)}%)",
  idle_after < idle + (busy - idle) / 4
)

check.("after cancel: no message", got.(o1) == [])

# ── 2. A second analysis by the same owner replaces the first ──
{:ok, first} = analyze.(o1)
Process.sleep(1_000)
{:ok, second} = analyze.(o1)
Process.sleep(500)
check.("second by the same owner: one running", running.() == 1)
:ok = cancel.(second)
wait_idle.()

check.(
  "first and second: no message for either",
  Enum.all?(got.(o1), &(elem(&1, 1) not in [first, second]))
)

# ── 3. The owner dies ──
o2 = owner.()
{:ok, _} = analyze.(o2)
Process.sleep(1_000)
send(o2, :exit)
check.("owner died: thread gone", wait_idle.())
check.("dead owner: {:error, :owner_dead}", analyze.(o2) == {:error, :owner_dead})

# ── 4. Two owners at once, a third is busy ──
[a, b, c] = for _ <- 1..3, do: owner.()
{:ok, ref_a} = analyze.(a)
{:ok, ref_b} = analyze.(b)
check.("third owner: {:error, :busy}", analyze.(c) == {:error, :busy})
:ok = cancel.(ref_a)
# A cancelled job's thread counts until it notices (one decoder buffer).
Enum.find_value(1..100, fn _ -> running.() == 1 || (Process.sleep(20) && nil) end)
check.("after one is cancelled and gone the third may start", match?({:ok, _}, analyze.(c)))
for p <- [a, b, c, o1], do: send(p, :exit)
_ = ref_b
check.("all owners gone: idle", wait_idle.())

# ── 4b. A burst of replacements: still one decoder thread for the owner ──
threads = fn ->
  adb.(["shell", "ls /proc/#{app_pid}/task | wc -l"]) |> String.trim() |> String.to_integer()
end

o3 = owner.()
before = threads.()
# One analysis's threads: the decoder's and MediaCodec's own.
{:ok, one} = analyze.(o3)
Process.sleep(1_000)
per_analysis = threads.() - before
:ok = cancel.(one)
wait_idle.()
Process.sleep(500)

{refs, peaks} =
  Enum.map_reduce(1..20, {0, 0}, fn _, {max_running, max_threads} ->
    {:ok, ref} = analyze.(o3)
    {ref, {max(max_running, running.()), max(max_threads, threads.())}}
  end)

{max_running, max_threads} = peaks
check.("burst of 20: at most one analysis thread (saw #{max_running})", max_running <= 1)

check.(
  "burst of 20: threads #{before} → at most #{max_threads} (one analysis adds #{per_analysis})",
  max_threads <= before + per_analysis + 2
)

Process.sleep(1_000)
check.("burst of 20: the latest runs", running.() == 1)
:ok = cancel.(List.last(refs))
check.("burst of 20: idle after cancelling the latest", wait_idle.())
check.("burst of 20: no message for any of them", got.(o3) == [])
send(o3, :exit)

# ── 5. The Import screen ──
picked = {:files, :picked, [%{path: file, name: "long.m4a", mime: "audio/mp4", size: 1}]}

open_import = fn ->
  Mob.Test.navigate(node, Humdinger.ImportScreen, %{})
  Process.sleep(1_500)
  # The system picker opened with the screen: dismiss it.
  adb.(~w(shell input keyevent KEYCODE_BACK))
  Process.sleep(1_000)
end

open_import.()
Mob.Test.send_message(node, picked)
Process.sleep(1_000)
check.("Import: analysing, one running", running.() == 1)
Mob.Test.send_message(node, put_in(picked, [Access.elem(2), Access.at(0), :name], "again.m4a"))
Process.sleep(500)
check.("Import: another file replaces it, one running", running.() == 1)
Mob.Test.tap(node, :back)
check.("Import: Back cancels it", wait_idle.())

open_import.()
Mob.Test.send_message(node, picked)
Process.sleep(1_000)
check.("Import again: one running", running.() == 1)
Mob.Test.pop(node)
check.("Import: popping the screen cancels it", wait_idle.())

check.(
  "app never restarted",
  String.trim(adb.(~w(shell pidof com.genericjam.humdinger))) == app_pid
)

failed = :ets.select_count(results, [{{:_, :_, false}, [], [true]}])
IO.puts(if failed == 0, do: "all passed", else: "#{failed} failed")
