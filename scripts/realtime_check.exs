# Does the microphone engine keep up on this phone? Over Erlang distribution:
# listens with the spectrum off, then on, and reports the reading rate, the
# batch sizes, the engine's lag (Humdinger.Audio.Native.info/0: from the
# input callback that delivered a batch's newest sample to the send; the
# stream's burst comes before it), what a reading and a spectrum column
# cost, and any audio dropped to catch up. PRESETS=1 also compares the input presets on a steady
# tone from the Mac's speaker (level mean and spread over 5 s, pitch).
#
#   mix mob.connect --no-iex --android-only --device <serial>
#   adb -s <serial> shell pm grant com.genericjam.humdinger android.permission.RECORD_AUDIO
#   SERIAL=<serial> [SECS=6] [PRESET=voice_recognition] [PRESETS=1] mix run --no-start scripts/realtime_check.exs

serial = System.fetch_env!("SERIAL")

node =
  String.to_atom(System.get_env("NODE", "humdinger_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"realtime_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)
secs = String.to_integer(System.get_env("SECS", "6"))

collector = """
defmodule HumRealtimeCheck.Collector do
  def start, do: spawn(fn -> loop([], 0) end)

  defp loop(msgs, spectra) do
    receive do
      {:hum_audio, _ref, {:readings, rs}} ->
        loop([{System.monotonic_time(:microsecond), rs} | msgs], spectra)

      {:hum_audio, _ref, {:spectrum, _}} ->
        loop(msgs, spectra + 1)

      {:report, from} ->
        send(from, {:report, self(), Enum.reverse(msgs), spectra})
        loop(msgs, spectra)

      :exit ->
        :ok

      _ ->
        loop(msgs, spectra)
    end
  end
end
"""

true = is_list(:rpc.call(node, Code, :compile_string, [collector]))

pct = fn
  [], _ ->
    nil

  list, p ->
    sorted = Enum.sort(list)
    Enum.at(sorted, round(p * (length(sorted) - 1)))
end

fmt = fn
  nil -> "-"
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 1)
  x -> to_string(x)
end

# Listen for `secs` (the first second is dropped as warm-up); returns the
# readings and a summary line.
run = fn opts ->
  pid = :rpc.call(node, HumRealtimeCheck.Collector, :start, [])

  {:ok, ref} = :rpc.call(node, Humdinger.Audio.Native, :listen, [pid, opts])

  if opts[:tone], do: opts[:tone].()
  Process.sleep(secs * 1000)
  info = :rpc.call(node, Humdinger.Audio.Native, :info, [])
  :ok = :rpc.call(node, Humdinger.Audio.Native, :stop, [ref])
  send(pid, {:report, self()})

  {msgs, spectra} =
    receive do: ({:report, ^pid, m, s} -> {m, s}), after: (5_000 -> raise("no report"))

  send(pid, :exit)

  msgs = Enum.filter(msgs, fn {_, rs} -> List.last(rs).t > 1_000 end)
  readings = Enum.flat_map(msgs, &elem(&1, 1))
  # Readings per second of audio, over the span their times cover.
  ts = Enum.map(readings, & &1.t)
  span = if ts == [], do: 1, else: max((Enum.max(ts) - Enum.min(ts)) / 1000, 0.001)
  sizes = Enum.map(msgs, fn {_, rs} -> length(rs) end)

  row = %{
    readings_per_s: length(readings) / span,
    per_msg_max: Enum.max(sizes, fn -> 0 end),
    spectra_per_s: spectra / secs,
    info: info
  }

  {readings, row}
end

print = fn label, r ->
  i = r.info

  IO.puts(
    "#{String.pad_trailing(label, 22)} #{fmt.(r.readings_per_s)} readings/s, ≤ #{r.per_msg_max}/msg, " <>
      "lag p50 #{fmt.(i.lag_p50_ms)} p95 #{fmt.(i.lag_p95_ms)} max #{fmt.(i.lag_max_ms)} ms, " <>
      "spectra #{fmt.(r.spectra_per_s)}/s | reading #{fmt.(i.detect_us_mean)} µs (max #{fmt.(i.detect_us_max)}), " <>
      "column #{fmt.(i.column_us_mean)} µs (max #{fmt.(i.column_us_max)}), skipped #{fmt.(i.skipped_ms)} ms " <>
      "in #{i.skips}"
  )
end

preset = String.to_atom(System.get_env("PRESET", "voice_performance"))
:ok = :rpc.call(node, Humdinger.Audio.Nif, :set_input_preset, [preset])
{_, off} = run.(spectrum: false)
i = off.info

IO.puts(
  "stream: #{i.rate} Hz, burst #{i.burst}, buffer #{i.buffer}, low latency #{i.low_latency}, " <>
    "preset #{i.preset}, xruns #{i.xruns}"
)

print.("spectrum off", off)
{_, on} = run.(spectrum: true)
print.("spectrum on", on)

if System.get_env("PRESETS") == "1" do
  hz = String.to_integer(System.get_env("TONE_HZ", "220"))
  path = "/tmp/hum_preset_tone_#{hz}.wav"

  {_, 0} =
    System.cmd(
      "ffmpeg",
      ~w(-v error -y -f lavfi -i sine=frequency=#{hz}:duration=#{secs}:sample_rate=48000 #{path})
    )

  tone = fn -> Task.start(fn -> System.cmd("afplay", ["-v", "8", path]) end) end

  for preset <- [:voice_recognition, :unprocessed, :voice_performance] do
    :ok = :rpc.call(node, Humdinger.Audio.Nif, :set_input_preset, [preset])
    {quiet, _} = run.(spectrum: false)
    room = quiet |> Enum.map(& &1.db) |> pct.(0.5)
    {readings, r} = run.(spectrum: false, tone: tone)
    # The tone's steady part: drop the first and last second.
    steady = Enum.filter(readings, &(&1.t > 1_500 and &1.t < (secs - 1) * 1000))
    dbs = Enum.map(steady, & &1.db)
    mean = Enum.sum(dbs) / max(length(dbs), 1)
    sd = :math.sqrt(Enum.sum(Enum.map(dbs, &((&1 - mean) ** 2))) / max(length(dbs), 1))
    pitched = steady |> Enum.filter(& &1.hz) |> Enum.map(&(1200 * :math.log2(&1.hz / hz)))

    IO.puts(
      "preset #{String.pad_trailing(to_string(preset), 18)} (stream: #{r.info.preset}, burst #{r.info.burst}, " <>
        "low latency #{r.info.low_latency}, lag p95 #{fmt.(r.info.lag_p95_ms)} ms): " <>
        "room #{fmt.(room)} dBFS, #{hz} Hz tone at #{fmt.(mean)} dBFS ± #{fmt.(sd)}, " <>
        "level p5–p95 #{fmt.(pct.(dbs, 0.05))}…#{fmt.(pct.(dbs, 0.95))}, " <>
        "pitched #{length(pitched)}/#{length(steady)}, median #{fmt.(pct.(pitched, 0.5))} ¢"
    )

    Process.sleep(500)
  end
end

:ok = :rpc.call(node, Humdinger.Audio.Nif, :set_input_preset, [:voice_performance])
