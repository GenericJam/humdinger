defmodule Humdinger.Audio.Native do
  @moduledoc """
  The phone's audio engine: `Humdinger.Audio` over `mob_audio_io` (the
  streams, the devices, file decoding) and the `hum_audio` NIF
  (`c_src/hum_audio.c`: YIN, the spectrum, the piano), which registers its
  processors with the plugin.

  The microphone is a `MobAudioIo` input stream (mono, the device's rate, 48
  kHz on the phones tried; the `:performance` preset, Android's
  VOICE_PERFORMANCE, or VOICE_RECOGNITION before Android 10, so no automatic
  gain or noise suppression bends the pitch) on the `"hum_mic"` processor,
  whose capture callback only fills a ring. The NIF's listen thread runs YIN
  (`c_src/pitch_yin.c`, 60–1600 Hz, from a hummed bass to a whistle) over a
  42 ms window every 5.3 ms, and, while asked, a spectrum column
  (`c_src/spectrum.c`) every 1/30 s. It sends readings in batches of two (or
  one that has waited 6 ms), already as `%{t, hz, clarity, db}` maps, so the
  owner does no decoding. A phone too slow to keep up loses readings (the
  thread skips to the newest audio) rather than delivering them late.
  `Humdinger.Audio.Native.Mic` owns the stream: a lost device ends the
  listening with `{:error, :device_lost}`, and the owner's exit closes it.

  The piano preview is an output stream on `"hum_piano"`
  (`Humdinger.Audio.Native.Piano`); file analysis streams the file with
  `MobAudioIo.decode_stream/3` into the NIF's analysis
  (`Humdinger.Audio.Native.Analyses`, started by `Humdinger.App`).

  The sensitivity gate is not here: a reading carries `hz` whenever the
  window was pitched at all (above −70 dBFS); the Tracker decides what counts.
  """

  @behaviour Humdinger.Audio

  alias Humdinger.Audio.Native.{Analyses, Mic, Piano}

  @presets %{
    voice_performance: :performance,
    voice_recognition: :default,
    unprocessed: :unprocessed,
    generic: :generic
  }

  @impl true
  def listen(owner, opts) when is_pid(owner) do
    ref = make_ref()
    spectrum = Keyword.get(opts, :spectrum, false)
    mic = [input: Keyword.get(opts, :input), preset: preset()]

    # One listening at a time, also between callers: the old stream closes,
    # the NIF arms (its thread waits for the stream), the stream opens.
    serially(:mic, fn ->
      with :ok <- Mic.close(),
           :ok <- nif().listen(owner, ref, spectrum),
           {:ok, _relay} <- start_mic(owner, ref, mic) do
        {:ok, ref}
      end
    end)
  rescue
    e in ErlangError -> not_loaded(e, __STACKTRACE__)
  end

  defp start_mic(owner, ref, opts) do
    with {:error, _} = error <- Mic.start(owner, ref, opts) do
      nif().stop(ref)
      error
    end
  end

  @impl true
  def set_spectrum(ref, on) when is_reference(ref) and is_boolean(on),
    do: nif().set_spectrum(ref, on)

  @impl true
  def stop(ref) when is_reference(ref) do
    :ok = Mic.close(ref)
    # Also when the stream's process is gone: the NIF ignores a stale ref.
    nif().stop(ref)
  end

  @impl true
  def inputs do
    case MobAudioIo.devices(:input) do
      devices when is_list(devices) ->
        for %{id: id, name: name, kind: kind} <- devices,
            do: %{id: id, name: name, kind: input_kind(kind)}

      {:error, _} ->
        []
    end
  end

  # The plugin's kinds in the contract's (Humdinger.Audio.input/0).
  defp input_kind(kind) when kind in [:builtin_mic, :wired_headset, :bluetooth, :usb], do: kind
  defp input_kind(:bluetooth_a2dp), do: :bluetooth
  defp input_kind(_), do: :other

  @impl true
  def analyze_file(owner, path, _opts) when is_pid(owner) do
    ref = make_ref()

    with :ok <- Analyses.analyze(owner, ref, IO.chardata_to_string(path)) do
      {:ok, ref}
    end
  end

  @impl true
  def cancel_analysis(ref) when is_reference(ref), do: Analyses.cancel(ref)

  @impl true
  def play_piano(owner, notes) when is_pid(owner) and is_list(notes) do
    ref = make_ref()

    # The newer preview preempts: the old stream closes before the NIF
    # takes the new phrase (it refuses with :busy under an open stream).
    serially(:piano, fn ->
      with :ok <- Piano.close(),
           :ok <- nif().piano_prepare(notes, piano_dir()),
           {:ok, _relay} <- Piano.start(owner, ref) do
        {:ok, ref}
      end
    end)
  rescue
    e in ErlangError -> not_loaded(e, __STACKTRACE__)
  end

  @impl true
  def cancel_piano(ref) when is_reference(ref), do: Piano.close(ref)

  @doc """
  Engine diagnostics: `Humdinger.Audio.Nif.info/0` (readings, lag, costs),
  the microphone stream's figures from `MobAudioIo.status/1` (`device`,
  `burst`, `buffer`, `xruns`, `preset` as Android's granted AAudio preset,
  `input_latency_ms` (−1 when the platform has none), `cb_max_us`,
  `gap_max_us`, and the whole map as `stream`, nil while not listening), and
  `analyses`, the file analyses running.
  """
  def info do
    nif().info()
    |> Map.merge(stream_info(Mic.status()))
    |> Map.put(:analyses, Analyses.running())
  end

  defp stream_info(nil),
    do: %{
      device: 0,
      burst: 0,
      buffer: 0,
      xruns: 0,
      preset: 0,
      input_latency_ms: -1.0,
      stream: nil
    }

  defp stream_info(s) do
    %{
      device: s.device_id,
      burst: s.burst,
      buffer: s.buffer,
      xruns: s.xruns,
      preset: s.preset_granted,
      input_latency_ms: s.input_latency_ms || -1.0,
      cb_max_us: s.cb_max_us,
      gap_max_us: s.gap_max_us,
      stream: s
    }
  end

  @doc """
  The input preset the next listen opens with: `:voice_performance` (the
  default, what the app uses; VOICE_RECOGNITION before Android 10),
  `:voice_recognition`, `:unprocessed` or `:generic` (`MobAudioIo`'s
  `:performance`, `:default`, `:unprocessed`, `:generic`). For comparing
  presets on a phone (`scripts/realtime_check.exs`).
  """
  def set_input_preset(preset) when is_map_key(@presets, preset) do
    Application.put_env(:humdinger, :input_preset, preset)
  end

  defp preset,
    do: Map.fetch!(@presets, Application.get_env(:humdinger, :input_preset, :voice_performance))

  @doc false
  # The NIF module: `Humdinger.Audio.Nif`, or a double in host tests
  # (`config :humdinger, :audio_nif`).
  def nif, do: Application.get_env(:humdinger, :audio_nif, Humdinger.Audio.Nif)

  defp serially(what, fun), do: :global.trans({{__MODULE__, what}, self()}, fun, [node()])

  # Off the phone the NIF isn't there.
  defp not_loaded(%ErlangError{original: :nif_not_loaded}, _stacktrace),
    do: {:error, :unsupported}

  defp not_loaded(e, stacktrace), do: reraise(e, stacktrace)

  defp piano_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:humdinger, "priv/piano")
      beams_dir -> Path.join([beams_dir, "priv", "piano"])
    end
  end
end
