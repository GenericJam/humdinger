defmodule Humdinger.Audio do
  @moduledoc """
  The audio engine contract: the microphone's pitch, level and spectrum, and
  offline analysis of an audio file. `impl/0` is `Humdinger.Audio.Native`
  on a phone (the `hum_audio` NIF, `c_src/hum_audio.c`) and
  `Humdinger.Audio.Fake` in host tests (`config :humdinger, :audio`).

  Everything arrives as messages to the `owner` process, tagged with the
  reference the call returned:

      {:hum_audio, ref, {:readings, [reading]}}   # while listening, every ≤ 12 ms
      {:hum_audio, ref, {:spectrum, spectrum}}    # while listening with spectrum on, ~30/s
      {:hum_audio, ref, {:error, reason}}         # listening ended: :permission, :device_lost, …
      {:hum_audio, ref, {:analysis, analysis}}    # analyze_file/3 finished
      {:hum_audio, ref, {:analysis_error, reason}}

  A message whose `ref` isn't the caller's current one is stale: ignore it.

  Listening in the background (another app in front) needs Android's
  foreground service, driven through `Humdinger.Background`: the
  `background_*` callbacks below.
  """

  @typedoc """
  One pitch reading. `t` is ms since `listen/2` (or since the file's start
  for an analysis) of the middle of the ~42 ms window the reading analysed.
  `hz` is `nil` when nothing pitched was heard. `clarity` is the detector's
  confidence (0..1, YIN's 1 − aperiodicity). `db` is the RMS level of the
  window in dBFS (silence −90). Live readings are ~5.3 ms apart, a file's
  10 ms.
  """
  @type reading :: %{t: non_neg_integer(), hz: float() | nil, clarity: float(), db: float()}

  @typedoc """
  A spectrum column: `bins` holds #{128} bytes, bin `i` centred at
  `50 · 2^(i / 20)` Hz (50 Hz … ~4.2 kHz, 20 bins per octave), each the
  level mapped −90 dBFS → 0 … −10 dBFS → 255.
  """
  @type spectrum :: %{t: non_neg_integer(), bins: binary()}

  @typedoc """
  A whole file: `waveform` is one peak byte (0..255) per 50 ms, `readings`
  as above over the whole file.
  """
  @type analysis :: %{
          duration_ms: non_neg_integer(),
          waveform: binary(),
          readings: [reading()]
        }

  @typedoc "A microphone. `kind`: `:builtin_mic`, `:wired_headset`, `:bluetooth`, `:usb` or `:other`."
  @type input :: %{id: integer(), name: String.t(), kind: atom()}

  @typedoc "What the background notification shows; `state` picks its buttons."
  @type notice :: %{
          title: String.t(),
          text: String.t(),
          state: :listening | :paused | :recording
        }

  @doc """
  Start the microphone, replacing whatever listened before (its reference
  goes stale). Options: `spectrum: boolean` (default false), `input: id`
  (from `inputs/0`; nil or missing: the system default). Errors:
  `:permission` (no microphone permission yet), `:microphone_unavailable`.
  Listening stops by itself when `owner` exits.
  """
  @callback listen(owner :: pid(), opts :: keyword()) :: {:ok, reference()} | {:error, term()}
  @doc "Turn the spectrum stream on or off while listening."
  @callback set_spectrum(reference(), boolean()) :: :ok
  @doc "Stop listening. Idempotent."
  @callback stop(reference()) :: :ok
  @doc "Microphones the phone offers."
  @callback inputs() :: [input()]
  @doc """
  Decode and analyse an audio file in the background (≤ 10 minutes). Errors
  arrive as `{:analysis_error, reason}`: `:not_found`, `:unsupported`,
  `:no_audio`, `:decode_error`, `:too_long`, `:alloc`.
  """
  @callback analyze_file(owner :: pid(), path :: Path.t(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}
  @doc "Start the background-listening service with `notice`; button taps go to `owner`."
  @callback background_start(owner :: pid(), notice()) :: :ok | {:error, term()}
  @doc "Change what the background notification shows."
  @callback background_update(notice()) :: :ok | {:error, :not_running}
  @doc "Stop the background-listening service. Idempotent."
  @callback background_stop() :: :ok
  @doc "Whether the background-listening service runs."
  @callback background_running?() :: boolean()

  @doc "Spectrum bins per column."
  def spectrum_bins, do: 128

  @doc "Centre frequency of spectrum bin `i`."
  def bin_hz(i), do: 50 * :math.pow(2, i / 20)

  @doc "The engine in use."
  def impl, do: Application.get_env(:humdinger, :audio, Humdinger.Audio.Native)
end
