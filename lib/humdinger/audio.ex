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
      {:hum_audio, ref, {:piano_position, ms}}    # sampled piano played ms, monotonic, ≤ 30 Hz
      {:hum_audio, ref, :piano_finished}          # sampled piano finished playing
      {:hum_audio, ref, {:piano_error, reason}}   # sampled piano failed or lost output

  A message whose `ref` isn't the caller's current one is stale: ignore it.
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

  @doc """
  Start the microphone, replacing whatever listened before (its reference
  goes stale). Options: `spectrum: boolean` (default false), `input: id`
  (from `inputs/0`; nil or missing: the system default). Errors:
  `:permission` (no microphone permission yet), `:microphone_unavailable`
  (also: the app is in the background and `MobBackground` isn't
  running, which Android refuses). Listening stops by itself when `owner`
  exits.
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

  One analysis per owner: a new call cancels the owner's previous one (its
  reference goes stale and gets no message). At most two owners analyse at
  once; a third gets `{:error, :busy}`. The analysis is cancelled when
  `owner` exits (`{:error, :owner_dead}` if it already has).
  """
  @callback analyze_file(owner :: pid(), path :: Path.t(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}
  @doc """
  Stop the analysis `ref` names. Nothing for `ref` arrives once this has
  returned. Unknown or finished references are ignored.
  """
  @callback cancel_analysis(reference()) :: :ok

  @doc """
  Synthesizes and plays `notes` using packaged piano samples, sending position
  and completion notifications to `owner`. Preempts any active native preview;
  refuses with `{:error, :stream_stuck}` if a previous output stream could not
  yet be stopped.
  """
  @callback play_piano(owner :: pid(), notes :: [Humdinger.Player.note()]) ::
              {:ok, reference()} | {:error, term()}

  @doc """
  Stops native piano playback for `ref` if active. Idempotent; once it returns,
  no further messages for `ref` are sent. Returns `{:error, :stream_stuck}` if
  the output stream could not be stopped; `play_piano/2` refuses with
  `{:error, :stream_stuck}` until a retry stops it.
  """
  @callback cancel_piano(reference()) :: :ok | {:error, :stream_stuck}

  @doc "Spectrum bins per column."
  def spectrum_bins, do: 128

  @doc "Centre frequency of spectrum bin `i`."
  def bin_hz(i), do: 50 * :math.pow(2, i / 20)

  @doc "The engine in use."
  def impl, do: Application.get_env(:humdinger, :audio, Humdinger.Audio.Native)
end
