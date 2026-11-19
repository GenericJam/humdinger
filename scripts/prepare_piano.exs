# Builds the playback piano in priv/piano from the University of Iowa
# Electronic Music Studios piano recordings (Steinway model B, mf; terms and
# provenance in priv/piano/LICENSE):
#
#     mise exec -- mix run --no-start scripts/prepare_piano.exs [cache_dir] [--check]
#
# Needs curl, ffmpeg and ffprobe. The sources (16-bit 44.1 kHz stereo AIFF)
# are downloaded once into cache_dir (default: <tmp>/humdinger_piano_src).
#
# One root every minor third, MIDI 22 (Bb0) .. 106 (Bb7), 29 notes (MIDI 60 is
# C4); the player reaches the notes in between by resampling the nearest
# root, at most a semitone and a half away. The site has no mf Bb0 (its mf
# series starts at B0), so mf_022 is B0 a semitone down (asetrate: slower and
# lower, like the player's own resampling).
#
# Each root: ffmpeg decodes it to mono ((L + R) / 2) 22050 Hz float, then
#
# 1. onset: the first sample whose |x| exceeds 1/30 of the file's peak; the
#    sample starts 2 ms (44 samples) before it, so the attack is at index 44;
# 2. length: linear in MIDI from 3.2 s at 22 to 1.0 s at 106 (low strings ring
#    longer), the last 250 ms a raised-cosine fade to silence;
# 3. level: one gain per root so the RMS of the first 400 ms after the onset is
#    the same for every root, that common RMS as high as lets the loudest peak
#    reach -1 dBFS;
# 4. written as priv/piano/mf_NNN.wav (NNN the MIDI root): 16-bit PCM mono
#    22050 Hz, a plain 44-byte RIFF header (fmt chunk, then data chunk).
#
# Then the check (alone with --check): every file's header, that its first
# 44 samples stay under 1/30 of its peak and the attack follows at 44, where
# the peak of the first 100 ms falls, and its fundamental (NSDF
# autocorrelation) against equal temperament at A4 = 440 Hz, in cents.

defmodule PreparePiano do
  @base "https://theremin.music.uiowa.edu/sound%20files/MIS/Piano_Other/piano/"
  @out "priv/piano"
  @rate 22_050
  @roots Enum.to_list(22..106//3)
  @names ~w(C Db D Eb E F Gb G Ab A Bb B)
  # Root => {source MIDI, semitones to shift it by}.
  @substitutes %{22 => {23, -1}}
  @pre 44
  @onset_fraction 1 / 30
  @length_low {22, 3.2}
  @length_high {106, 1.0}
  @fade_s 0.25
  @rms_s 0.4
  @ceiling_db -1.0
  @budget 2_800_000
  @frame 220

  @doc "Runs the preparation (unless `--check`) and then the check."
  @spec main([String.t()]) :: :ok
  def main(args) do
    {flags, rest} = Enum.split_with(args, &String.starts_with?(&1, "--"))
    cache = List.first(rest) || Path.join(System.tmp_dir!(), "humdinger_piano_src")
    unless "--check" in flags, do: prepare(cache)
    check()
  end

  # --- preparation ----------------------------------------------------------

  defp prepare(cache) do
    File.mkdir_p!(cache)
    File.mkdir_p!(@out)
    resampler = resampler()
    IO.puts("resampler: #{resampler}\n")

    cuts = Enum.map(@roots, &cut(&1, cache, resampler))
    target = target_rms(cuts)
    rows = Enum.map(cuts, &write(&1, target))

    print_prepared(rows, target)
  end

  defp resampler do
    probe =
      ~w(-v error -f lavfi -i anullsrc=r=44100:cl=mono -t 0.01 -af aresample=22050:resampler=soxr -f null -)

    case System.cmd("ffmpeg", probe, stderr_to_stdout: true) do
      {_, 0} -> "aresample=#{@rate}:resampler=soxr:precision=28"
      _ -> "aresample=#{@rate}:filter_size=64"
    end
  end

  defp cut(midi, cache, resampler) do
    {source, shift} = Map.get(@substitutes, midi, {midi, 0})
    file = "Piano.mf.#{name(source)}.aiff"
    path = download(file, cache)
    pcm = decode(path, shift, resampler)

    peak = peak(pcm)
    onset = first_above(pcm, peak * @onset_fraction, 0)
    {jump_db, jump_s} = largest_jump(pcm, onset, peak)

    seg = segment(pcm, onset, round(length_s(midi) * @rate))

    rms =
      rms(
        binary_part(seg, @pre * 4, min(round(@rms_s * @rate), div(byte_size(seg), 4) - @pre) * 4)
      )

    %{
      midi: midi,
      source: file,
      shift: shift,
      source_s: div(byte_size(pcm), 4) / @rate,
      onset_s: onset / @rate,
      jump_db: jump_db,
      jump_s: jump_s,
      seg: seg,
      rms: rms,
      peak: peak(seg)
    }
  end

  defp download(file, cache) do
    path = Path.join(cache, file)

    unless File.exists?(path) do
      part = path <> ".part"
      args = ["-fsSL", "--retry", "3", "-o", part, @base <> file]
      {_, 0} = System.cmd("curl", args)
      File.rename!(part, path)
    end

    path
  end

  defp decode(path, shift, resampler) do
    info = probe(path)
    rate = String.to_integer(info["sample_rate"])
    mono = if info["channels"] == "1", do: [], else: ["pan=mono|c0=0.5*c0+0.5*c1"]
    shifted = if shift == 0, do: [], else: ["asetrate=#{round(rate * 2 ** (shift / 12))}"]
    filter = Enum.join(shifted ++ mono ++ [resampler], ",")

    {pcm, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-i", path, "-af", filter, "-f", "f32le", "-"])

    pcm
  end

  defp probe(path) do
    args =
      ~w(-v error -select_streams a:0 -show_entries stream=sample_rate,channels -of default=nw=1) ++
        [path]

    {out, 0} = System.cmd("ffprobe", args)

    out
    |> String.split("\n", trim: true)
    |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))
  end

  # From @pre samples before the onset (zero-padded if the file starts later),
  # `want` samples or as many as the file has.
  defp segment(pcm, onset, want) do
    pad = max(@pre - onset, 0)
    start = onset + pad - @pre
    len = min(want - pad, div(byte_size(pcm), 4) - start)
    :binary.copy(<<0.0::float-32-little>>, pad) <> binary_part(pcm, start * 4, len * 4)
  end

  defp length_s(midi) do
    {m0, l0} = @length_low
    {m1, l1} = @length_high
    l0 + (l1 - l0) * (midi - m0) / (m1 - m0)
  end

  # The common RMS: as high as lets the root with the highest peak-to-RMS
  # ratio peak at the ceiling.
  defp target_rms(cuts) do
    ceiling = 10 ** (@ceiling_db / 20)
    cuts |> Enum.map(&(ceiling * &1.rms / &1.peak)) |> Enum.min()
  end

  defp write(cut, target) do
    gain = target / cut.rms
    samples = for <<x::float-32-little <- cut.seg>>, do: x
    len = length(samples)
    fade = round(@fade_s * @rate)

    data =
      samples
      |> Enum.with_index()
      |> Enum.map(fn {x, i} ->
        <<quantize(x * gain * fade(i, len - fade, fade))::signed-16-little>>
      end)
      |> IO.iodata_to_binary()

    file = Path.join(@out, wav_name(cut.midi))
    File.write!(file, [wav_header(byte_size(data)), data])

    Map.merge(cut, %{
      gain_db: db(gain),
      peak_db: db(gain * cut.peak),
      length_s: len / @rate,
      bytes: File.stat!(file).size
    })
  end

  defp fade(i, from, _n) when i < from, do: 1.0
  defp fade(i, from, n), do: 0.5 * (1 + :math.cos(:math.pi() * (i - from + 1) / n))

  defp quantize(x), do: x |> Kernel.*(32_767) |> round() |> max(-32_768) |> min(32_767)

  defp wav_header(data_bytes) do
    <<"RIFF", 36 + data_bytes::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little,
      1::16-little, @rate::32-little, @rate * 2::32-little, 2::16-little, 16::16-little, "data",
      data_bytes::32-little>>
  end

  defp print_prepared(rows, target) do
    IO.puts("common RMS of the first #{round(@rms_s * 1000)} ms: #{fmt(db(target), 1)} dBFS\n")

    header = ~w(midi name length_s gain_dB peak_dBFS bytes source shift lead_s src_s jump_dB@s)
    widths = [4, 4, 8, 7, 9, 7, 18, 5, 6, 6, 10]
    print_row(header, widths)

    Enum.each(rows, fn r ->
      print_row(
        [r.midi, name(r.midi), fmt(r.length_s, 2), fmt(r.gain_db, 1), fmt(r.peak_db, 1), r.bytes] ++
          [r.source, r.shift, fmt(r.onset_s, 2), fmt(r.source_s, 1), jump(r)],
        widths
      )
    end)

    total = rows |> Enum.map(& &1.bytes) |> Enum.sum()
    IO.puts("\nwav total: #{total} bytes (#{Float.round(total / 1.0e6, 3)} MB)\n")
  end

  defp jump(r), do: "#{fmt(r.jump_db, 1)}@#{fmt(r.jump_s, 1)}"

  # The largest rise of a 10 ms frame's RMS over the loudest of the five frames
  # before it, from 150 ms after the onset on (frames above -60 dB of the
  # peak): a second note, a thump or a pedal noise shows as a jump of several
  # dB; a ringing piano note's beats stay around a dB or two.
  defp largest_jump(pcm, onset, peak) do
    from = onset + round(0.15 * @rate)
    frames = frames(binary_part(pcm, from * 4, byte_size(pcm) - from * 4))
    floor = peak / 1000

    frames
    |> Enum.chunk_every(6, 1, :discard)
    |> Enum.with_index()
    |> Enum.filter(fn {window, _} -> List.last(window) > floor end)
    |> Enum.map(fn {window, i} ->
      {db(List.last(window) / Enum.max(Enum.drop(window, -1))), i}
    end)
    |> Enum.max(fn -> {0.0, 0} end)
    |> then(fn {jump, i} -> {jump, (from + (i + 5) * @frame) / @rate} end)
  end

  defp frames(<<frame::binary-size(@frame * 4), rest::binary>>), do: [rms(frame) | frames(rest)]
  defp frames(_), do: []

  # --- check -----------------------------------------------------------------

  defp check do
    IO.puts("check (#{@out}):")
    header = ~w(midi name samples attack_at pre_dB peak@ms f0_Hz cents)
    widths = [4, 4, 7, 9, 6, 7, 8, 6]
    print_row(header, widths)

    Enum.each(@roots, fn midi -> midi |> check_file() |> print_row(widths) end)

    total = @out |> File.ls!() |> Enum.map(&File.stat!(Path.join(@out, &1)).size) |> Enum.sum()
    verdict = if total <= @budget, do: "within", else: "OVER"
    IO.puts("\n#{@out} total: #{total} bytes, #{verdict} the #{@budget} byte budget")
  end

  defp check_file(midi) do
    x = midi |> wav_name() |> then(&Path.join(@out, &1)) |> File.read!() |> wav_samples()
    n = tuple_size(x)
    peak = Enum.max(for i <- 0..(n - 1), do: abs(elem(x, i)))
    pre = Enum.max(for i <- 0..(@pre - 1), do: abs(elem(x, i)))
    attack = Enum.find(0..(n - 1), &(abs(elem(x, &1)) > peak * @onset_fraction))
    first = round(0.1 * @rate) - 1
    peak_at = Enum.max_by(0..first, &abs(elem(x, &1)))
    f0 = f0(x, 440 * 2 ** ((midi - 69) / 12))

    [midi, name(midi), n, attack, fmt(db(max(pre, 1) / peak), 0)] ++
      [
        fmt(peak_at / @rate * 1000, 1),
        fmt(f0, 2),
        fmt(1200 * :math.log2(f0 / (440 * 2 ** ((midi - 69) / 12))), 1)
      ]
  end

  # Only the exact 44-byte layout the player expects.
  defp wav_samples(
         <<"RIFF", riff::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 1::16-little,
           @rate::32-little, 44_100::32-little, 2::16-little, 16::16-little, "data",
           size::32-little, data::binary>>
       )
       when riff == 36 + size and byte_size(data) == size do
    List.to_tuple(for <<s::signed-16-little <- data>>, do: s)
  end

  # McLeod's NSDF over lags from 1/2.5 to 2.5 periods of `expected`, 100 ms
  # after the onset: the first local maximum within 90% of the highest,
  # refined by a parabola through its neighbours.
  defp f0(x, expected) do
    period = @rate / expected
    {lo, hi} = {max(round(period / 2.5), 2), round(period * 2.5)}
    start = @pre + round(0.1 * @rate)
    w = min(max(2048, 2 * hi), tuple_size(x) - start - hi - 1)
    r = Map.new((lo - 1)..(hi + 1), &{&1, nsdf(x, start, w, &1)})

    maxima = for t <- lo..hi, r[t] > r[t - 1] and r[t] >= r[t + 1], do: t
    best = maxima |> Enum.map(&r[&1]) |> Enum.max()
    t = Enum.find(maxima, &(r[&1] >= 0.9 * best))
    {a, b, c} = {r[t - 1], r[t], r[t + 1]}
    @rate / (t + 0.5 * (a - c) / (a - 2 * b + c))
  end

  defp nsdf(x, start, w, lag) do
    {num, den} =
      Enum.reduce(start..(start + w - 1), {0, 0}, fn i, {num, den} ->
        a = elem(x, i)
        b = elem(x, i + lag)
        {num + a * b, den + a * a + b * b}
      end)

    2 * num / den
  end

  # --- helpers ----------------------------------------------------------------

  defp name(midi), do: Enum.at(@names, rem(midi, 12)) <> Integer.to_string(div(midi, 12) - 1)

  defp wav_name(midi), do: "mf_#{String.pad_leading(Integer.to_string(midi), 3, "0")}.wav"

  defp peak(pcm), do: peak(pcm, 0.0)
  defp peak(<<x::float-32-little, rest::binary>>, acc), do: peak(rest, max(acc, abs(x)))
  defp peak(<<>>, acc), do: acc

  defp first_above(<<x::float-32-little, rest::binary>>, thr, i) do
    if abs(x) > thr, do: i, else: first_above(rest, thr, i + 1)
  end

  defp rms(pcm) do
    {sum, n} =
      for <<x::float-32-little <- pcm>>, reduce: {0.0, 0}, do: ({s, n} -> {s + x * x, n + 1})

    :math.sqrt(sum / max(n, 1))
  end

  defp db(ratio), do: 20 * :math.log10(ratio)

  defp fmt(x, decimals), do: :erlang.float_to_binary(x / 1, decimals: decimals)

  defp print_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join(" ", fn {cell, w} -> String.pad_leading(to_string(cell), w) end)
    |> IO.puts()
  end
end

PreparePiano.main(System.argv())
