defmodule Humdinger.Audio.Nif do
  @moduledoc """
  The `hum_audio` NIF (`c_src/hum_audio.c`), statically linked into the app
  (`mob.exs`'s `:static_nifs`): Humdinger's DSP over `mob_audio_io`'s
  streams. Use it through `Humdinger.Audio.Native`.

  Loading it registers two `mob_audio_io` processors (`mai_register`):
  `"hum_mic"` (capture: the microphone into a ring the listen thread reads)
  and `"hum_piano"` (render: the phrase `piano_prepare/2` set up). Their
  streams are opened with `MobAudioIo.open/3` and `module: #{inspect(__MODULE__)}`.

  The listen thread builds every message in its final shape (see
  `Humdinger.Audio`), so nothing on the BEAM side translates readings.

  Off the phone the library isn't there: the module still loads, and every
  function raises `:nif_not_loaded`.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # The NIF only exists in the phone build; elsewhere the stubs below stay.
    _ = :erlang.load_nif(~c"hum_audio", 0)
    :ok
  end

  @doc """
  Arm `"hum_mic"` and start the listen thread for `owner`, its messages
  tagged `ref`; it waits for the stream's first block, so open the stream
  after this. Stops whatever listened before. `:ok` or `{:error,
  :microphone_unavailable | :thread}` (`:microphone_unavailable`: a
  `"hum_mic"` stream is still open).
  """
  def listen(_owner, _ref, _spectrum), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop listening if `ref` is the current listener's; nothing for it starts once this returns. `:ok`."
  def stop(_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Spectrum on or off for the current listener `ref` (ignored if stale). `:ok`."
  def set_spectrum(_ref, _on), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Diagnostics since the last listen: `listening`, the stream's `rate`, the
  capture `callbacks` and `last_callback_frames`, the `readings`, `batches`
  and `spectra` sent, the batches' delivery lag (`lag_mean_ms`,
  `lag_max_ms`, `lag_p50_ms`, `lag_p95_ms`: from the capture callback that
  delivered the newest analysed sample to the send), what one reading and
  one spectrum column cost (`detect_us_mean`/`_max`, `column_us_mean`/`_max`),
  the audio dropped to catch up (`skipped_ms` over `skips` times),
  `priority_raised` (the listen thread's), and `mic_streams` (open
  `"hum_mic"` streams).
  """
  def info, do: :erlang.nif_error(:nif_not_loaded)

  @doc "A file analysis at `rate`: `{:ok, analysis}` or `{:error, :alloc}`."
  def analysis_new(_rate), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Analyse the next mono 32-bit float samples (native byte order). `:ok` or `{:error, :alloc}`."
  def analysis_push(_analysis, _pcm), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The analysis: `%{duration_ms, waveform, readings}` (see `Humdinger.Audio`), or `{:error, :alloc}`."
  def analysis_finish(_analysis), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set up `notes` for the next `"hum_piano"` stream, with the sampled piano
  WAVs in `samples_dir`. `:ok` or `{:error, :empty | :too_many_notes |
  :invalid_notes | :too_long | :samples_unavailable | :busy | :alloc}`
  (`:busy`: a `"hum_piano"` stream is still open).
  """
  def piano_prepare(_notes, _samples_dir), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The prepared phrase's playhead: `:idle` (no stream started on it),
  `{:playing, ms, finish_in_ms | nil}` (`finish_in_ms` once every frame is
  in the stream), `{:finished, ms}` (its end has been heard) or `{:failed,
  reason}`.
  """
  def piano_position, do: :erlang.nif_error(:nif_not_loaded)
end
