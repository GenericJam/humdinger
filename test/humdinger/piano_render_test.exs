defmodule Humdinger.PianoRenderTest do
  use ExUnit.Case, async: true

  @cc System.find_executable("cc")
  if is_nil(@cc) do
    @moduletag skip: "cc not found: the piano renderer host test needs a C compiler"
  end

  setup_all do
    case @cc do
      nil ->
        :ok

      cc ->
        src = Path.expand("../../c_src/test/piano_host.c", __DIR__)
        dir = Path.join(System.tmp_dir!(), "piano_host_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf(dir) end)

        exe = Path.join(dir, "piano_host")
        {out, status} = System.cmd(cc, ["-O2", "-o", exe, src, "-lm"], stderr_to_stdout: true)
        assert status == 0, out

        %{exe: exe, dir: dir}
    end
  end

  defp run(ctx, script_lines) do
    path = Path.join(ctx.dir, "script_#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(script_lines, "\n") <> "\n")
    System.cmd("sh", ["-c", "exec \"$0\" < \"$1\"", ctx.exe, path])
  end

  defp samples(bin) do
    for <<s::little-signed-16 <- bin>>, do: s
  end

  test "a held note outlasts its sample", ctx do
    {bin, status} =
      run(ctx, [
        "bank 22050",
        "sample dc 2205 0.1",
        "root 60",
        "note 0 1000 60 127",
        "stream 256"
      ])

    assert status == 0
    pcm = samples(bin)

    # 1000 ms at 22050 Hz releases at frame 22050, even though the sample is 2205 frames (100 ms).
    assert byte_size(bin) >= 22_050 * 2
    assert Enum.at(pcm, 1000) != 0

    # With start = 0, frames = 2205, step = 1.0, sample_end = 0 + floor((2205 - 1) / 1.0) = 2204.
    # Every frame from sample_end (and therefore from index 2205 onward) is 0.
    sample_end = 0 + trunc(:math.floor((2205 - 1) / 1.0))
    assert Enum.all?(Enum.drop(pcm, sample_end), &(&1 == 0))
  end

  test "a negative onset is rejected", ctx do
    {bin, status} =
      run(ctx, [
        "bank 22050",
        "sample dc 2205 0.1",
        "root 60",
        "note -10 200 60 100",
        "stream 256"
      ])

    assert status == 4
    assert bin == <<>>
  end

  test "resampling to 48 kHz keeps the leading silence and the pitch", ctx do
    period = :erlang.float_to_binary(22_050 / 440, [:compact, decimals: 12])

    {bin, status} =
      run(ctx, [
        "bank 22050",
        "sample sine 44100 #{period} 0.5",
        "root 69",
        "out_rate 48000",
        "note 100 1000 69 127",
        "stream 512"
      ])

    assert status == 0
    pcm = samples(bin)

    # 100 ms onset at 48 kHz is 4800 frames of leading silence.
    assert Enum.all?(Enum.take(pcm, 4800), &(&1 == 0))
    assert Enum.any?(Enum.slice(pcm, 4800..4900), &(&1 != 0))

    # Count rising zero crossings over a 0.5 s (24000-frame) window inside the note.
    window_frames = 24_000
    window = Enum.slice(pcm, 4800 + 4800, window_frames + 1)
    assert length(window) == window_frames + 1

    crossings =
      window
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> a <= 0 and b > 0 end)

    freq = crossings / 0.5
    assert_in_delta freq, 440.0, 440.0 * 0.02
  end

  test "polyphony is capped at 32 voices", ctx do
    notes = for midi <- 40..79, do: "note 0 200 #{midi} 127"

    {bin, status} =
      run(
        ctx,
        ["bank 22050", "sample dc 100000 0.02", "root 60"] ++ notes ++ ["stream 256"]
      )

    assert status == 0
    pcm = samples(bin)
    first_100 = Enum.take(pcm, 100)
    assert byte_size(bin) >= 100 * 2

    sample_pcm = round(0.02 * 32_767)
    expected_32 = round(32 * (sample_pcm / 32_768) * 0.8 * 32_767)
    expected_33 = round(33 * (sample_pcm / 32_768) * 0.8 * 32_767)

    peak = Enum.max(first_100)
    assert abs(peak - expected_32) <= 2
    assert peak < expected_33
  end
end
