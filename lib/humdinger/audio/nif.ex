defmodule Humdinger.Audio.Nif do
  @moduledoc """
  The `hum_audio` NIF (`c_src/hum_audio.c`), statically linked into the
  Android app (`mob.exs`'s `:static_nifs`). Use it through
  `Humdinger.Audio.Native` and `Humdinger.Background`.

  The NIF builds every message in its final shape (see `Humdinger.Audio`),
  so nothing on the BEAM side translates readings.

  Off Android the library isn't there: the module still loads, and every
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
  Listen on `input` (a device id, or nil for the default), sending messages
  tagged `ref` to `owner`. Stops whatever listened before. `:ok` or
  `{:error, :permission | :microphone_unavailable | :owner_dead | :thread |
  {:missing, library}}`.
  """
  def listen(_owner, _ref, _input, _spectrum), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop listening if `ref` is the current listener's. `:ok`."
  def stop(_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Spectrum on or off for the current listener `ref` (ignored if stale). `:ok`."
  def set_spectrum(_ref, _on), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Microphones, `[%{id, name, kind}]`."
  def inputs, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Analyse the file at `path` (a binary) on a thread; the result arrives at `owner` tagged `ref`."
  def analyze_file(_owner, _ref, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Start (or update and retarget) the background service. `state` is
  `:listening | :paused | :recording`. `:ok` or `{:error, :permission |
  :refused | :unavailable}`.
  """
  def background_start(_owner, _title, _text, _state), do: :erlang.nif_error(:nif_not_loaded)

  @doc "New notice for the running service. `:ok` or `{:error, :not_running}`."
  def background_update(_title, _text, _state), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop the background service. `:ok`."
  def background_stop, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Whether the background service runs."
  def background_running, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Diagnostics: the input stream (`rate`, `burst`, `buffer`, `low_latency`,
  `xruns`, `device`, `input_latency_ms`), and since the last listen the
  `callbacks`, `readings`, `batches` and `spectra` sent, and the batches'
  delivery lag (`lag_mean_ms`, `lag_max_ms`: from the newest analysed
  sample's arrival to the send).
  """
  def info, do: :erlang.nif_error(:nif_not_loaded)
end
