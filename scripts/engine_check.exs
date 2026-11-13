# Checks Humdinger.Engine on a connected Android phone over Erlang
# distribution: tones the Mac plays become notes sent to Output, how long
# that takes, a recorded take, listening on with the app in the background
# (frames, events, the notification's text) and the notification's buttons
# (pause, resume, record, stop rec → a saved phrase, stop).
#
#   mix mob.deploy --native --android --device <serial>
#   mix mob.connect --no-iex --android-only --device <serial>
#   SERIAL=<serial> mix run --no-start scripts/engine_check.exs
#
# Put the phone next to the Mac's speaker. It changes the saved settings to
# Scale mode, D Dorian, octave and transpose 0, and leaves the engine off.

serial = System.fetch_env!("SERIAL")
app = "com.genericjam.humdinger"

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

adb = fn args -> elem(System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true), 0) end

{:ok, _} = Node.start(:"engine_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

rpc = fn m, f, a -> :rpc.call(node, m, f, a) end

# A collector on the phone: subscribed to the engine (frames, status, saved
# phrases) and tracing the engine process: when each batch of readings
# arrived and when each batch of events went to Output.send_events/1.
collector_module = """
defmodule EngineCheck.Collector do
  def start do
    spawn(fn ->
      engine = Process.whereis(Humdinger.Engine)
      :ok = Humdinger.Engine.subscribe(self())
      :erlang.trace_pattern({Humdinger.Output, :send_events, 1}, true, [:local])
      :erlang.trace(engine, true, [:receive, :call, :monotonic_timestamp, {:tracer, self()}])
      loop(%{readings: [], sends: [], frames: [], other: []})
    end)
  end

  defp us(ts), do: :erlang.convert_time_unit(ts, :native, :microsecond)

  defp loop(st) do
    receive do
      {:trace_ts, _, :receive, {:hum_audio, _ref, {:readings, rs}}, ts} ->
        loop(%{st | readings: [{us(ts), rs} | st.readings]})

      {:trace_ts, _, :call, {Humdinger.Output, :send_events, [events]}, ts} ->
        loop(%{st | sends: [{us(ts), events} | st.sends]})

      {:trace_ts, _, _, _, _} ->
        loop(st)

      {:engine, :frame, frame} ->
        loop(%{st | frames: [{System.monotonic_time(:microsecond), frame} | st.frames]})

      {:engine, _, _} = msg ->
        loop(%{st | other: [{System.monotonic_time(:microsecond), msg} | st.other]})

      {:report, from} ->
        send(from, {:report, self(), Map.new(st, fn {k, v} -> {k, Enum.reverse(v)} end)})
        loop(%{readings: [], sends: [], frames: [], other: []})

      :exit ->
        :erlang.trace(Process.whereis(Humdinger.Engine), false, [:all])
        :erlang.trace_pattern({Humdinger.Output, :send_events, 1}, false, [:local])
    end
  end
end
"""

report = fn pid ->
  send(pid, {:report, self()})

  receive do
    {:report, ^pid, st} -> st
  after
    10_000 -> raise "no report"
  end
end

pct = fn list, p ->
  case Enum.sort(list) do
    [] -> nil
    sorted -> Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end
end

fmt = fn
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 1)
  x -> inspect(x)
end

# The phone's monotonic clock minus the Mac's (µs), from the quickest of a
# few round trips.
clock_offset = fn ->
  1..15
  |> Enum.map(fn _ ->
    a = System.monotonic_time(:microsecond)
    phone = rpc.(System, :monotonic_time, [:microsecond])
    b = System.monotonic_time(:microsecond)
    {b - a, phone - div(a + b, 2)}
  end)
  |> Enum.min()
end

wav = fn hz, secs ->
  path = "/tmp/engine_check_#{round(hz)}.wav"

  {_, 0} =
    System.cmd(
      "ffmpeg",
      ~w(-v error -y -f lavfi -i sine=frequency=#{hz}:duration=#{secs}:sample_rate=48000 -af volume=0.6 #{path})
    )

  path
end

# Plays the tones one after another; returns each one's start on the Mac's
# clock (µs) with its note.
play = fn tones ->
  for {midi, secs, gap} <- tones do
    path = wav.(440 * :math.pow(2, (midi - 69) / 12), secs)
    started = System.monotonic_time(:microsecond)
    System.cmd("afplay", [path])
    Process.sleep(gap)
    {midi, started}
  end
end

note_ons = fn st ->
  for {ts, events} <- st.sends, {:note_on, n, v} <- events, do: {ts, n, v}
end

notification = fn ->
  adb.(~w(shell dumpsys notification --noredact))
  |> String.split("\n")
  |> Enum.drop_while(&(not String.contains?(&1, "pkg=#{app}")))
  |> Enum.filter(&(&1 =~ ~r/android\.(title|text)=/))
  |> Enum.take(2)
  |> Enum.map(&String.trim/1)
end

# ── Setup ─────────────────────────────────────────────────────────────────
adb.(~w(shell pm grant #{app} android.permission.RECORD_AUDIO))
adb.(~w(shell monkey -p #{app} -c android.intent.category.LAUNCHER 1))
Process.sleep(1_500)

[{EngineCheck.Collector, _}] = rpc.(Code, :compile_string, [collector_module])

:ok = rpc.(Humdinger.Engine, :stop, [])

{:ok, _} =
  rpc.(Humdinger.Engine, :update_settings, [
    [mode: :scale, scale: Humdinger.Scale.new("D", :dorian), octave: 0, transpose: 0]
  ])

c = rpc.(EngineCheck.Collector, :start, [])
Process.sleep(200)
IO.puts("listen: #{inspect(rpc.(Humdinger.Engine, :listen, []))}")
IO.puts("background service running: #{rpc.(Humdinger.Background, :running?, [])}")
Process.sleep(800)
report.(c)

# ── 1. Tones → notes, and how long it takes ───────────────────────────────
{rtt, offset} = clock_offset.()
IO.puts("clock: round trip #{fmt.(rtt / 1000)} ms")
starts = play.([{69, 0.8, 500}, {72, 0.8, 500}, {76, 0.8, 500}, {74, 0.8, 800}])
st = report.(c)
ons = note_ons.(st)

IO.puts(
  "\n1. Tones A4 C5 E5 D5 → note ons: #{inspect(Enum.map(ons, fn {_, n, v} -> {Humdinger.Music.note_name(n), v} end))}"
)

for {midi, mac_start} <- starts do
  start = mac_start + offset
  ref = 440 * :math.pow(2, (midi - 69) / 12)

  heard =
    Enum.find_value(st.readings, fn {ts, rs} ->
      (ts > start and
         Enum.any?(rs, &(&1.hz && &1.clarity > 0.8 && abs(1200 * :math.log2(&1.hz / ref)) < 50))) &&
        ts
    end)

  sent = Enum.find_value(ons, fn {ts, n, _} -> (ts > start and n == midi) && ts end)

  IO.puts(
    "  #{Humdinger.Music.note_name(midi)}: tone start → first clear reading #{fmt.(heard && (heard - start) / 1000)} ms, " <>
      "→ note on #{fmt.(sent && (sent - (heard || start)) / 1000)} ms later, total #{fmt.(sent && (sent - start) / 1000)} ms"
  )
end

moods = st.frames |> Enum.map(fn {_, f} -> f.mood end) |> Enum.dedup()
secs = (elem(List.last(st.frames), 0) - elem(hd(st.frames), 0)) / 1.0e6

IO.puts(
  "  frames: #{length(st.frames)} in #{fmt.(secs)} s (#{fmt.(length(st.frames) / secs)}/s), moods #{inspect(moods)}"
)

IO.puts("  Output.last_sent: #{inspect(rpc.(Humdinger.Output, :last_sent, []))}")
IO.puts("  notification: #{inspect(notification.())}")

# ── 2. A recorded take ────────────────────────────────────────────────────
:ok = rpc.(Humdinger.Engine, :record_start, [])
play.([{69, 0.6, 300}, {71, 0.6, 300}, {72, 0.6, 600}])
{:ok, take} = rpc.(Humdinger.Engine, :record_stop, [])

IO.puts(
  "\n2. Take: #{inspect(Enum.map(take.notes, &{Humdinger.Music.note_name(&1.midi), &1.start_ms, &1.dur_ms}))}, " <>
    "#{length(take.trace)} trace points, #{take.duration_ms} ms, scale #{Humdinger.Scale.name(take.scale)}"
)

report.(c)

# ── 3. In the background ──────────────────────────────────────────────────
adb.(~w(shell input keyevent KEYCODE_HOME))
Process.sleep(1_000)
play.([{69, 1.0, 300}])
mid = notification.()
play.([{74, 1.0, 600}])
st = report.(c)

IO.puts(
  "\n3. Home pressed: #{length(st.frames)} frames, #{length(st.readings)} reading batches, " <>
    "note ons #{inspect(Enum.map(note_ons.(st), fn {_, n, _} -> Humdinger.Music.note_name(n) end))}"
)

IO.puts("  notification while A4 played: #{inspect(mid)}")
IO.puts("  notification now: #{inspect(notification.())}")

# ── 4. The notification's buttons (the intents a tap sends, as the app's uid) ──
button = fn action ->
  adb.(~w(shell run-as #{app} am startservice --user 0 -n #{app}/.HumListenService
       -a #{app}.listen.BUTTON --es button #{action}))

  Process.sleep(600)
end

IO.puts("\n4. Buttons:")
button.("pause")
IO.puts("  pause → #{inspect(rpc.(Humdinger.Engine, :status, []))}, #{inspect(notification.())}")
button.("resume")
IO.puts("  resume → #{inspect(rpc.(Humdinger.Engine, :status, []))}")
button.("record")

IO.puts(
  "  record → recording? #{rpc.(Humdinger.Engine, :recording?, [])}, #{inspect(notification.())}"
)

play.([{69, 0.6, 300}, {72, 0.6, 600}])
button.("record_stop")
Process.sleep(500)
st = report.(c)

saved =
  for {_, {:engine, :phrase_saved, p}} <- st.other,
      do: {p.id, p.name, Enum.map(p.notes, &Humdinger.Music.note_name(&1.midi))}

IO.puts("  record_stop → phrase saved: #{inspect(saved)}")
button.("stop")

IO.puts(
  "  stop → #{inspect(rpc.(Humdinger.Engine, :status, []))}, service running #{rpc.(Humdinger.Background, :running?, [])}, " <>
    "notification #{inspect(notification.())}"
)

send(c, :exit)
