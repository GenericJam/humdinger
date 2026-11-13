# Checks Humdinger.Background's lifecycle on a connected Android phone over
# Erlang distribution: the races between start, update and stop, and that
# the service stops when its owner dies. Each check reads the notification
# list (dumpsys) and watches the app's pid and logcat for a crash.
#
#   mix mob.connect --no-iex --android-only --device <serial>
#   adb -s <serial> shell pm grant com.genericjam.humdinger android.permission.RECORD_AUDIO
#   adb -s <serial> shell pm grant com.genericjam.humdinger android.permission.POST_NOTIFICATIONS  # Android 13+
#   SERIAL=<serial> mix run --no-start scripts/background_check.exs
#
# The Engine may own the service while the app runs: the script stops it
# first and leaves it stopped.

serial = System.fetch_env!("SERIAL")

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"background_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

adb = fn args -> elem(System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true), 0) end
pid_of_app = fn -> String.trim(adb.(~w(shell pidof com.genericjam.humdinger))) end

on_phone = fn code ->
  {value, _} = :rpc.call(node, Code, :eval_string, [code, []])
  value
end

# Our notification is posted (ours carry the id 4410).
posted? = fn ->
  adb.(~w(shell dumpsys notification --noredact))
  |> String.contains?("pkg=com.genericjam.humdinger user=UserHandle{0} id=4410")
end

running? = fn -> :rpc.call(node, Humdinger.Background, :running?, []) end
app_pid = pid_of_app.()
since = String.trim(adb.(["shell", "date '+%m-%d %H:%M:%S.000'"]))
results = :ets.new(:results, [:ordered_set, :public])

check = fn name, ok? ->
  :ets.insert(results, {System.unique_integer([:monotonic]), name, ok?})
  IO.puts("#{if ok?, do: "ok  ", else: "FAIL"} #{name}")
end

# A long-lived owner on the phone (an eval's own process exits with the rpc).
owner_code = """
spawn(fn -> receive do :exit -> :ok end end)
"""

:rpc.call(node, Humdinger.Background, :stop, [])
Process.sleep(1_000)

# ── 1. Start then stop at once, before the service reaches startForeground ──
owner = on_phone.(owner_code)

for _ <- 1..20 do
  :ok = :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "start-stop"}])
  :ok = :rpc.call(node, Humdinger.Background, :stop, [])
end

Process.sleep(1_500)
check.("20 × start then immediate stop: app alive", pid_of_app.() == app_pid)
check.("20 × start then immediate stop: not running", running?.() == false)
check.("20 × start then immediate stop: notification gone", not posted?.())

# ── 2. start, stop, start in a row ends running and shown ──
:ok = :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "first"}])
:ok = :rpc.call(node, Humdinger.Background, :stop, [])
:ok = :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "second"}])
Process.sleep(1_500)
check.("start, stop, start: running", running?.() == true)
check.("start, stop, start: notification shown", posted?.())
:ok = :rpc.call(node, Humdinger.Background, :stop, [])
Process.sleep(1_000)
check.("then stop: notification gone", not posted?.())

# ── 3. Updates queued right before stop don't leave a notification behind ──
:ok = :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "updates"}])
Process.sleep(1_500)

for i <- 1..30 do
  :ok = :rpc.call(node, Humdinger.Background, :update, [%{text: "update #{i}"}])
end

:ok = :rpc.call(node, Humdinger.Background, :stop, [])
Process.sleep(1_500)
check.("30 updates then stop: notification gone", not posted?.())

# ── 4. The owner dies: the service stops ──
:ok = :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "owner"}])
Process.sleep(1_500)
check.("owner alive: running and shown", running?.() == true and posted?.())
send(owner, :exit)
Process.sleep(1_500)
check.("owner died: not running", running?.() == false)
check.("owner died: notification gone", not posted?.())

# ── 5. A dead owner can't start it ──
check.(
  "dead owner: {:error, :owner_dead}",
  :rpc.call(node, Humdinger.Background, :start, [owner, %{text: "dead"}]) == {:error, :owner_dead}
)

Process.sleep(500)
check.("dead owner: notification not shown", not posted?.())

log = adb.(["shell", "logcat -d -T '#{since}'"])

check.(
  "no startForeground crash in logcat",
  not String.contains?(log, "did not then call Service.startForeground")
)

check.("no FATAL EXCEPTION in logcat", not String.contains?(log, "FATAL EXCEPTION"))
check.("app never restarted", pid_of_app.() == app_pid)

failed = :ets.select_count(results, [{{:_, :_, false}, [], [true]}])
IO.puts(if failed == 0, do: "all passed", else: "#{failed} failed")
