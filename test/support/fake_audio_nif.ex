defmodule Humdinger.Test.FakeAudioNif do
  @moduledoc """
  `Humdinger.Audio.Nif` for host tests (`config :humdinger, :audio_nif`), so
  `Humdinger.Audio.Native` runs on the host over `MobAudioIo.Fake`.

  It records the calls (`calls/0`, oldest first) and answers as scripted:
  `set(:listen, result)`, `set(:prepare, result)`, `positions(list)` (what
  `piano_position/0` answers, one per call, the last one repeated;
  `{:playing, 0, nil}` by default) and `set(:push_delay, ms)` (each
  `analysis_push/2` sleeps that long, so an analysis can be caught running).
  An analysis is an Agent counting the frames pushed; it finishes as
  `%{duration_ms, waveform: <<>>, readings: []}`.

  Like the NIF, `listen/3` refuses with `{:error, :microphone_unavailable}`
  while a `"hum_mic"` stream is open in `MobAudioIo.Fake` (after stopping
  the old listener), and `piano_prepare/2` with `{:error, :busy}` while a
  `"hum_piano"` one is: the order `Humdinger.Audio.Native` closes and arms
  in is what keeps those from happening.

  State is global: `async: false` tests, `reset/0` in `setup`.
  """

  @defaults %{calls: [], listener: nil, listen: :ok, prepare: :ok, positions: [], push_delay: 0}

  @doc "Back to no calls and the default answers."
  def reset, do: update(fn _ -> @defaults end)

  @doc "Script an answer: `:listen`, `:prepare` or `:push_delay`."
  def set(key, value) when key in [:listen, :prepare, :push_delay],
    do: update(&Map.put(&1, key, value))

  @doc "What `piano_position/0` answers, in turn."
  def positions(list), do: update(&%{&1 | positions: list})

  @doc "The calls so far, oldest first: `{:listen, owner, ref, spectrum}`, `{:stop, ref}`, `{:piano_prepare, notes, dir}`, ..."
  def calls, do: get(&Enum.reverse(&1.calls))

  @doc "The ref listening now, or nil."
  def listener, do: get(& &1.listener)

  def listen(owner, ref, spectrum) do
    open? = open?("hum_mic")

    Agent.get_and_update(name(), fn s ->
      s = record(s, {:listen, owner, ref, spectrum})

      cond do
        open? -> {{:error, :microphone_unavailable}, %{s | listener: nil}}
        s.listen == :ok -> {:ok, %{s | listener: ref}}
        true -> {s.listen, s}
      end
    end)
  end

  def stop(ref) do
    update(fn s ->
      s = record(s, {:stop, ref})
      if s.listener == ref, do: %{s | listener: nil}, else: s
    end)
  end

  def set_spectrum(ref, on), do: update(&record(&1, {:set_spectrum, ref, on}))

  def info do
    get(fn s ->
      %{listening: s.listener != nil, rate: 48_000, readings: 0, lag_p95_ms: -1.0, mic_streams: 0}
    end)
  end

  def analysis_new(rate) do
    {:ok, agent} = Agent.start_link(fn -> %{rate: rate, frames: 0} end)
    {:ok, agent}
  end

  def analysis_push(analysis, pcm) do
    Process.sleep(get(& &1.push_delay))
    Agent.update(analysis, &%{&1 | frames: &1.frames + div(byte_size(pcm), 4)})
  end

  def analysis_finish(analysis) do
    %{rate: rate, frames: frames} = Agent.get(analysis, & &1)
    %{duration_ms: round(frames * 1000 / rate), waveform: <<>>, readings: []}
  end

  def piano_prepare(notes, dir) do
    result = if open?("hum_piano"), do: {:error, :busy}, else: get(& &1.prepare)
    update(&record(&1, {:piano_prepare, notes, dir}))
    result
  end

  defp open?(processor),
    do: Enum.any?(MobAudioIo.Fake.status().streams, &(&1.processor == processor))

  def piano_position do
    Agent.get_and_update(name(), fn
      %{positions: [last]} = s -> {last, s}
      %{positions: [next | rest]} = s -> {next, %{s | positions: rest}}
      %{positions: []} = s -> {{:playing, 0, nil}, s}
    end)
  end

  defp record(s, call), do: %{s | calls: [call | s.calls]}

  defp name do
    case Agent.start(fn -> @defaults end, name: __MODULE__) do
      {:ok, _} -> __MODULE__
      {:error, {:already_started, _}} -> __MODULE__
    end
  end

  defp get(fun), do: Agent.get(name(), fun)
  defp update(fun), do: Agent.update(name(), fun)
end
