defmodule Humdinger.Audio.Native do
  @moduledoc """
  The phone's audio engine: `Humdinger.Audio` over the `hum_audio` NIF
  (`c_src/hum_audio.c`, Android).

  The microphone is an AAudio input stream in low-latency mode (mono, the
  device's rate, 48 kHz on the phones tried; VOICE_PERFORMANCE preset, or
  VOICE_RECOGNITION before Android 10, so no automatic gain or noise
  suppression bends the pitch). A thread reads it and runs YIN
  (`c_src/pitch_yin.c`, 60–1600 Hz, from a hummed bass to a whistle) over a
  42 ms window every 5.3 ms, and, while asked, a spectrum column
  (`c_src/spectrum.c`) every 1/30 s. The NIF sends readings in batches of
  two (or one that has waited 6 ms), already as `%{t, hz, clarity, db}`
  maps, so the owner does no decoding. A phone too slow to keep up loses
  readings (the thread skips to the newest audio) rather than delivering
  them late.

  The sensitivity gate is not here: a reading carries `hz` whenever the
  window was pitched at all (above −70 dBFS); the Tracker decides what counts.
  """

  @behaviour Humdinger.Audio

  alias Humdinger.Audio.Nif

  @impl true
  def listen(owner, opts) when is_pid(owner) do
    ref = make_ref()

    case Nif.listen(owner, ref, Keyword.get(opts, :input), Keyword.get(opts, :spectrum, false)) do
      :ok -> {:ok, ref}
      {:error, _} = error -> error
    end
  end

  @impl true
  def set_spectrum(ref, on) when is_reference(ref) and is_boolean(on),
    do: Nif.set_spectrum(ref, on)

  @impl true
  def stop(ref) when is_reference(ref), do: Nif.stop(ref)

  @impl true
  def inputs, do: Nif.inputs()

  @impl true
  def analyze_file(owner, path, _opts) when is_pid(owner) do
    ref = make_ref()

    case Nif.analyze_file(owner, ref, IO.chardata_to_string(path)) do
      :ok -> {:ok, ref}
      {:error, _} = error -> error
    end
  end

  @impl true
  def cancel_analysis(ref) when is_reference(ref), do: Nif.cancel_analysis(ref)

  @impl true
  def background_start(owner, %{title: title, text: text, state: state}) when is_pid(owner),
    do: Nif.background_start(owner, title, text, state)

  @impl true
  def background_update(%{title: title, text: text, state: state}),
    do: Nif.background_update(title, text, state)

  @impl true
  def background_stop, do: Nif.background_stop()

  @impl true
  def background_running?, do: Nif.background_running()

  @impl true
  def play_piano(owner, notes) when is_pid(owner) and is_list(notes) do
    ref = make_ref()

    case Nif.play_piano(owner, ref, notes, piano_dir()) do
      :ok -> {:ok, ref}
      {:error, _} = error -> error
    end
  rescue
    e in ErlangError ->
      case e.original do
        :nif_not_loaded -> {:error, :unsupported}
        _ -> reraise e, __STACKTRACE__
      end
  end

  @impl true
  def cancel_piano(ref) when is_reference(ref) do
    Nif.cancel_piano(ref)
  rescue
    e in ErlangError ->
      case e.original do
        :nif_not_loaded -> :ok
        _ -> reraise e, __STACKTRACE__
      end
  end

  @doc "Engine diagnostics; see `Humdinger.Audio.Nif.info/0`."
  def info, do: Nif.info()

  defp piano_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:humdinger, "priv/piano")
      beams_dir -> Path.join([beams_dir, "priv", "piano"])
    end
  end
end
