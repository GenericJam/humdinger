# Checks the hum_audio engine on a connected Android phone over Erlang
# distribution: readings' rate and latency, pitch of a tone the Mac plays,
# the spectrum, stop, a second listen replacing the first, file analysis, and
# (BACKGROUND=1) listening on with the app in the background.
#
#   mix mob.connect --no-iex --android-only --device <serial>
#   adb -s <serial> shell pm grant com.genericjam.humdinger android.permission.RECORD_AUDIO
#   SERIAL=<serial> mix run --no-start scripts/audio_check.exs
#
# Put the phone next to the Mac's speaker: the script plays sines with
# afplay. FILE=<path on the phone> also analyses that file (adb push it into
# /data/data/com.genericjam.humdinger/files/ first, e.g. with
# `adb shell run-as`). BACKGROUND=1 starts MobBackground (:microphone), presses
# Home, turns the screen off and on, and checks readings keep coming for
# SECS (default 35) seconds.

serial = System.fetch_env!("SERIAL")

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"audio_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

# Code runs on the phone: the collector is compiled there (Code.compile_string)
# so its pid is local to the NIF and its timings are of compiled code.
on_phone = fn code, binding ->
  {value, _} = :rpc.call(node, Code, :eval_string, [code, binding])
  value
end

collector_module = """
defmodule HumAudioCheck.Collector do
  def start, do: spawn(fn -> loop(%{msgs: [], readings: [], spectra: [], other: []}) end)

  # What a consumer does per reading at least: match it and turn hz into a
  # fractional MIDI note.
  defp walk(rs) do
    Enum.reduce(rs, 0.0, fn
      %{t: t, hz: nil, clarity: c, db: db}, a -> a + t + c + db
      %{t: t, hz: hz, clarity: c, db: db}, a -> a + t + 69 + 12 * :math.log2(hz / 440) + c + db
    end)
  end

  defp loop(st) do
    receive do
      {:hum_audio, _ref, {:readings, rs}} = msg ->
        now = System.monotonic_time(:microsecond)
        t1 = System.monotonic_time(:nanosecond)
        walk(rs)
        ns = System.monotonic_time(:nanosecond) - t1
        entry = {now, length(rs), List.last(rs).t, ns / 1000, :erts_debug.flat_size(msg)}
        loop(%{st | msgs: [entry | st.msgs], readings: Enum.reverse(rs, st.readings)})

      {:hum_audio, _ref, {:spectrum, sp}} ->
        loop(%{st | spectra: [{System.monotonic_time(:microsecond), sp} | st.spectra]})

      {:hum_audio, _ref, other} ->
        loop(%{st | other: [other | st.other]})

      {:mob_background, _event} = tap ->
        loop(%{st | other: [tap | st.other]})

      {:report, from} ->
        send(from, {:report, self(), %{st | msgs: Enum.reverse(st.msgs), readings: Enum.reverse(st.readings), spectra: Enum.reverse(st.spectra)}})
        loop(st)

      :exit ->
        :ok
    end
  end
end
"""

_ = :rpc.call(node, Code, :compile_string, [collector_module])
new_collector = fn -> :rpc.call(node, HumAudioCheck.Collector, :start, []) end

report = fn pid ->
  send(pid, {:report, self()})

  receive do
    {:report, ^pid, st} -> st
  after
    10_000 -> raise "no report from #{inspect(pid)}"
  end
end

listen = fn pid, opts ->
  on_phone.(
    "t0 = System.monotonic_time(:microsecond); {t0, Humdinger.Audio.Native.listen(pid, opts)}",
    pid: pid,
    opts: opts
  )
end

pct = fn list, p ->
  case Enum.sort(list) do
    [] -> nil
    sorted -> Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end
end

fmt = fn x -> if is_float(x), do: :erlang.float_to_binary(x, decimals: 2), else: inspect(x) end

tone = fn hz, secs ->
  path = "/tmp/hum_tone_#{hz}.wav"

  {_, 0} =
    System.cmd(
      "ffmpeg",
      ~w(-v error -y -f lavfi -i sine=frequency=#{hz}:duration=#{secs}:sample_rate=48000 -af volume=0.6 #{path})
    )

  Task.async(fn -> System.cmd("afplay", [path]) end)
end

cents = fn hz, ref -> 1200 * :math.log2(hz / ref) end

summarize = fn label, st, t0 ->
  msgs = st.msgs
  n = length(st.readings)
  [{first, _, _, _, _} | _] = msgs
  {last, _, _, _, _} = List.last(msgs)
  secs = (last - first) / 1.0e6

  gaps =
    msgs
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> (b - a) / 1000 end)

  # Delay from the newest analysed sample's capture to the message's arrival:
  # arrival (ms since listen) − (t of the newest reading + half the window).
  half_window = 2004 / 48_000 * 500

  delays =
    Enum.map(msgs, fn {now, _, t_last, _, _} -> (now - t0) / 1000 - (t_last + half_window) end)

  costs = Enum.map(msgs, fn {_, k, _, us, _} -> us / k end)
  words = Enum.map(msgs, fn {_, k, _, _, w} -> w / k end)
  ts = Enum.map(st.readings, & &1.t)
  steps = ts |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

  IO.puts("""
  #{label}: #{n} readings in #{length(msgs)} messages over #{fmt.(secs)} s = #{fmt.(n / max(secs, 0.001))} readings/s, #{fmt.(n / max(length(msgs), 1) * 1.0)} per message
    message interval ms: p50 #{fmt.(pct.(gaps, 0.5))} p95 #{fmt.(pct.(gaps, 0.95))} max #{fmt.(pct.(gaps, 1.0))}
    capture→arrival ms:  p50 #{fmt.(pct.(delays, 0.5))} p95 #{fmt.(pct.(delays, 0.95))} max #{fmt.(pct.(delays, 1.0))}
    reading t step ms:   p50 #{inspect(pct.(steps, 0.5))} min #{inspect(pct.(steps, 0.0))} max #{inspect(pct.(steps, 1.0))}
    BEAM per reading:    #{fmt.(pct.(costs, 0.5))} µs to walk (p50), #{fmt.(pct.(words, 0.5))} heap words
    spectra: #{length(st.spectra)} (#{fmt.(length(st.spectra) / max(secs, 0.001))}/s)  other: #{inspect(st.other)}
  """)
end

IO.inspect(:rpc.call(node, Humdinger.Audio.Native, :inputs, []), label: "inputs")

# ── 1. Listen with the spectrum on while the Mac plays 440 Hz, then 660 Hz ──
c1 = new_collector.()
{t0, {:ok, ref1}} = listen.(c1, spectrum: true)
Process.sleep(500)
t440 = tone.(440, 3)
Process.sleep(3_200)
Task.await(t440)
t660 = tone.(660, 2)
Process.sleep(2_200)
Task.await(t660)
info = :rpc.call(node, Humdinger.Audio.Native, :info, [])
st1 = report.(c1)
IO.inspect(info, label: "engine")
summarize.("listen 1", st1, t0)

# The room's level before the first tone; a tone's readings are the clear ones
# at least 12 dB above it.
room = st1.readings |> Enum.filter(&(&1.t < 450)) |> Enum.map(& &1.db) |> pct.(0.5)
IO.puts("  room level #{fmt.(room)} dBFS")

for {hz, from, to} <- [{440, 1_000, 3_300}, {660, 4_000, 5_500}] do
  loud =
    Enum.filter(
      st1.readings,
      &(&1.t >= from and &1.t <= to and &1.hz != nil and &1.clarity > 0.8 and &1.db > room + 12)
    )

  heard = Enum.map(loud, &cents.(&1.hz, hz))
  octave = Enum.count(heard, &(abs(&1) > 600))
  near = Enum.reject(heard, &(abs(&1) > 600))

  IO.puts(
    "  tone #{hz} Hz: #{length(heard)} clear readings at #{fmt.(pct.(Enum.map(loud, & &1.db), 0.5))} dBFS, " <>
      "median #{fmt.(pct.(near, 0.5))} ¢, p95 |err| #{fmt.(pct.(Enum.map(near, &abs/1), 0.95))} ¢, octave errors #{octave}"
  )

  for r <- loud |> Enum.filter(&(abs(cents.(&1.hz, hz)) > 600)) |> Enum.take(8),
      do: IO.puts("    off by an octave or more: #{inspect(r)}")
end

# The strongest spectrum bin while 440 Hz played: 50·2^(i/20) = 440 → i ≈ 63.
peak_bins =
  st1.spectra
  |> Enum.map(fn {_, %{t: t, bins: bins}} -> {t, bins} end)
  |> Enum.filter(fn {t, _} -> t > 1_200 and t < 3_200 end)
  |> Enum.map(fn {_, bins} ->
    bytes = :binary.bin_to_list(bins)
    Enum.find_index(bytes, &(&1 == Enum.max(bytes)))
  end)

IO.puts(
  "  spectrum peak bin during 440 Hz: #{inspect(Enum.frequencies(peak_bins))} (440 Hz is bin 63)"
)

# ── 2. A second listen replaces the first ──
c2 = new_collector.()
{t0b, {:ok, ref2}} = listen.(c2, [])
before = length(report.(c1).msgs)
Process.sleep(1_000)
after_replace = length(report.(c1).msgs)
st2 = report.(c2)

IO.puts(
  "\nsecond listen (#{inspect(ref2)} replaces #{inspect(ref1)}): first got #{after_replace - before} messages after, second #{length(st2.msgs)}"
)

summarize.("listen 2", st2, t0b)

# ── 3. Stop: the old reference does nothing, the current one stops ──
:ok = :rpc.call(node, Humdinger.Audio.Native, :stop, [ref1])
Process.sleep(300)
still = length(report.(c2).msgs)
Process.sleep(300)
IO.puts("stop(stale ref): listener 2 still receiving: #{length(report.(c2).msgs) > still}")
:ok = :rpc.call(node, Humdinger.Audio.Native, :stop, [ref2])
Process.sleep(100)
stopped = length(report.(c2).msgs)
Process.sleep(500)

IO.puts(
  "stop(current ref): messages after stop: #{length(report.(c2).msgs) - stopped}; listening: #{:rpc.call(node, Humdinger.Audio.Native, :info, []).listening}"
)

# ── 4. File analysis ──
if file = System.get_env("FILE") do
  c3 = new_collector.()

  {us, _} =
    :timer.tc(fn ->
      {:ok, aref} =
        on_phone.("Humdinger.Audio.Native.analyze_file(pid, path, [])", pid: c3, path: file)

      send(c3, :noop)

      Enum.find_value(1..600, fn _ ->
        Process.sleep(100)
        st = report.(c3)
        st.other != [] && {aref, st.other}
      end)
    end)

  [result] = report.(c3).other

  case result do
    {:analysis, a} ->
      voiced = Enum.count(a.readings, & &1.hz)

      IO.puts(
        "\nanalyze_file #{file}: #{a.duration_ms} ms, waveform #{byte_size(a.waveform)} bytes, " <>
          "#{length(a.readings)} readings (#{voiced} pitched) in #{fmt.(us / 1.0e6)} s"
      )

      IO.puts("  first pitched: #{inspect(Enum.find(a.readings, & &1.hz))}")

    other ->
      IO.puts("\nanalyze_file #{file}: #{inspect(other)}")
  end

  send(c3, :exit)
end

# ── 5. Background ──
# NOSERVICE=1 runs the same without MobBackground: the control, where
# Android silences the microphone once the app is in the background.
if System.get_env("BACKGROUND") == "1" do
  secs = String.to_integer(System.get_env("SECS", "35"))
  adb = fn args -> System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true) end
  c4 = new_collector.()

  if System.get_env("NOSERVICE") != "1" do
    bg =
      on_phone.(
        ~s[MobBackground.start(pid, mode: :microphone, notification: %{title: "Humdinger · listening", text: "A4 −12¢ → FMutate A · ch 1"})],
        pid: c4
      )

    IO.puts("\nbackground start: #{inspect(bg)}")
  end

  {t0c, {:ok, ref4}} = listen.(c4, [])
  Process.sleep(1_000)
  adb.(~w(shell input keyevent KEYCODE_HOME))

  # IDLE=1: make Android treat the backgrounded app as idle at once (it
  # otherwise does after about a minute); an idle app's microphone is silenced
  # unless a microphone foreground service runs.
  if System.get_env("IDLE") == "1" do
    Process.sleep(500)
    {out, _} = adb.(~w(shell am make-uid-idle com.genericjam.humdinger))
    IO.puts("make-uid-idle: #{inspect(String.trim(out))}")
  end

  Process.sleep(1_500)
  {focus, _} = adb.(~w(shell dumpsys window | grep mCurrentFocus))
  IO.puts("after Home: #{String.trim(focus)}")
  {notif, _} = adb.(~w(shell dumpsys notification --noredact))

  ours =
    notif
    |> String.split("NotificationRecord")
    |> Enum.filter(&String.contains?(&1, "com.genericjam.humdinger"))

  IO.puts(
    "notification: #{inspect(ours |> Enum.join() |> then(&Regex.run(~r/android\.text=String \(([^)]*)\)/, &1)))}"
  )

  off_at = div(secs, 3)
  on_at = div(2 * secs, 3)
  tone_at = div(secs, 2)

  per_second =
    for s <- 1..secs do
      if s == off_at, do: adb.(~w(shell input keyevent KEYCODE_POWER))
      if s == on_at, do: adb.(~w(shell input keyevent KEYCODE_WAKEUP))

      if s == tone_at,
        do:
          on_phone.(
            ~s[MobBackground.update(%{title: "Humdinger · listening", text: "C5 +3¢ → FMutate A · ch 1"})],
            []
          )

      if s == tone_at, do: tone.(523, 2)
      Process.sleep(1_000)
      {s, report.(c4).readings}
    end

  IO.puts(
    "each second in the background: readings, median dBFS (screen off #{off_at}–#{on_at} s, 523 Hz tone at #{tone_at} s):"
  )

  per_second
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.each(fn [{_, a}, {s, b}] ->
    new = Enum.drop(b, length(a))
    db = pct.(Enum.map(new, & &1.db), 0.5)
    pitched = new |> Enum.filter(&(&1.hz && &1.db > -50)) |> Enum.map(& &1.hz)

    IO.puts(
      "  #{s}s: #{length(new)} readings, #{fmt.(db)} dB, loud pitched median #{fmt.(pct.(pitched, 0.5))} Hz"
    )
  end)

  st4 = report.(c4)
  summarize.("background", st4, t0c)
  :ok = :rpc.call(node, Humdinger.Audio.Native, :stop, [ref4])
  on_phone.("MobBackground.stop()", [])
  {notif, _} = adb.(~w(shell dumpsys notification --noredact))

  IO.puts(
    "notification after stop: #{String.contains?(notif, "A4 −12¢") or String.contains?(notif, "C5 +3¢")}"
  )

  adb.(~w(shell monkey -p com.genericjam.humdinger -c android.intent.category.LAUNCHER 1))
  send(c4, :exit)
end

# ── 6. Notification buttons ──
# BUTTONS=1: with the app in the background, send the service the intents its
# buttons carry (as the app's own uid, through run-as), each of which must
# arrive as {:mob_background, {:action, id}}; listen anew from the background
# (allowed while the service runs); then update and stop the notification.
# Tapping the buttons in the shade takes the same path from SystemUI.
if System.get_env("BUTTONS") == "1" do
  adb = fn args -> elem(System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true), 0) end
  c5 = new_collector.()

  notice =
    ~s|MobBackground.start(pid, mode: :microphone, notification: %{title: "Humdinger · listening", text: "A4 −12¢ → FMutate A · ch 1", actions: [%{id: :pause, label: "Pause"}, %{id: :record, label: "Record"}, %{id: :stop, label: "Stop"}]})|

  :ok = on_phone.(notice, pid: c5)
  Process.sleep(800)
  adb.(~w(shell input keyevent KEYCODE_HOME))
  Process.sleep(800)

  for action <- ~w(pause resume record record_stop stop) do
    adb.(~w(shell run-as com.genericjam.humdinger am startservice --user 0
         -n com.genericjam.humdinger/io.mob.background.BeamForegroundService
         -a io.mob.background.BUTTON --es button) ++ [action])

    Process.sleep(500)
    got = Enum.member?(report.(c5).other, {:mob_background, {:action, String.to_atom(action)}})
    IO.puts("button #{action}: arrived #{got}")
  end

  {_, result} = listen.(c5, [])
  Process.sleep(1_000)
  dbs = Enum.map(report.(c5).readings, & &1.db)

  IO.puts(
    "listen from the background: #{inspect(result)}, #{length(dbs)} readings at #{fmt.(pct.(dbs, 0.5))} dBFS"
  )

  with {:ok, ref} <- result, do: :rpc.call(node, Humdinger.Audio.Native, :stop, [ref])

  update =
    ~s|MobBackground.update(%{title: "Humdinger · recording", text: "C5 +3¢ → FMutate A · ch 1", actions: [%{id: :pause, label: "Pause"}, %{id: :record_stop, label: "Stop rec"}, %{id: :stop, label: "Stop"}]})|

  on_phone.(update, [])
  Process.sleep(800)

  IO.puts(
    "updated notice shown: #{String.contains?(adb.(~w(shell dumpsys notification --noredact)), "C5 +3¢")}"
  )

  on_phone.("MobBackground.stop()", [])
  Process.sleep(800)

  IO.puts(
    "gone after stop: #{not String.contains?(adb.(~w(shell dumpsys notification --noredact)), "C5 +3¢")}"
  )

  adb.(~w(shell monkey -p com.genericjam.humdinger -c android.intent.category.LAUNCHER 1))
  send(c5, :exit)
end

for c <- [c1, c2], do: send(c, :exit)
