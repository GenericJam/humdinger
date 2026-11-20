defmodule Humdinger.Audio.Fake do
  @moduledoc """
  `Humdinger.Audio` for host tests (`config :humdinger, :audio`): no sound,
  the test plays the singer.

  Like the phone, it is one engine for the whole VM: a new `listen/2`
  replaces the old listener (its reference goes stale, `listening?/1` turns
  false), and listening stops when the owner exits. Tests that listen should
  therefore not run `async`.

      {:ok, ref} = Fake.listen(self(), spectrum: true)
      Fake.sing(ref, [%{t: 0, hz: 440.0, clarity: 0.95, db: -20.0}])
      assert_receive {:hum_audio, ^ref, {:readings, [_]}}

  The driving functions (`sing/2`, `spectrum/2`, `fail/2`, `analysis/2`,
  `analysis_error/2`) deliver to the owner of whichever listen or analysis
  returned `ref`, stale or not, so tests can check that stale messages are
  ignored. `fail/2` also ends the listening, as a lost microphone does.
  Analyses follow the phone's rules: one per owner (a newer one cancels the
  older), two owners at once (`{:error, :busy}`), cancelled when the owner
  exits; `analysing?/1` tells whether one still runs.

  `play_piano/2` and `cancel_piano/1` (always `:ok` in `Fake`) drive
  sampled-piano previews.
  """

  @behaviour Humdinger.Audio

  use GenServer

  @inputs [
    %{id: 1, name: "Built-in microphone", kind: :builtin_mic},
    %{id: 7, name: "Headset", kind: :wired_headset}
  ]

  # Like the NIF's MAX_ANALYSES and piano limits.
  @max_analyses 2
  @max_piano_notes 4096
  @max_piano_ms 600_000

  # ── Humdinger.Audio ──────────────────────────────────────────────────────

  @impl Humdinger.Audio
  def listen(owner, opts) when is_pid(owner), do: call({:listen, owner, opts})

  @impl Humdinger.Audio
  def set_spectrum(ref, on) when is_reference(ref) and is_boolean(on),
    do: call({:set_spectrum, ref, on})

  @impl Humdinger.Audio
  def stop(ref) when is_reference(ref), do: call({:stop, ref})

  @impl Humdinger.Audio
  def inputs, do: @inputs

  @impl Humdinger.Audio
  def analyze_file(owner, path, _opts) when is_pid(owner), do: call({:analyze, owner, path})

  @impl Humdinger.Audio
  def cancel_analysis(ref) when is_reference(ref), do: call({:cancel_analysis, ref})

  @impl Humdinger.Audio
  @spec play_piano(pid(), [Humdinger.Player.note()]) :: {:ok, reference()} | {:error, term()}
  def play_piano(owner, notes) when is_pid(owner) and is_list(notes),
    do: call({:play_piano, owner, notes})

  @impl Humdinger.Audio
  @spec cancel_piano(reference()) :: :ok | {:error, :stream_stuck}
  def cancel_piano(ref) when is_reference(ref), do: call({:cancel_piano, ref})

  # ── Driving it from a test ───────────────────────────────────────────────

  @doc "Deliver `{:hum_audio, ref, {:readings, readings}}` to `ref`'s owner."
  def sing(ref, readings) when is_list(readings), do: deliver(ref, {:readings, readings})

  @doc "Deliver `{:hum_audio, ref, {:spectrum, spectrum}}` to `ref`'s owner."
  def spectrum(ref, %{t: _, bins: bins} = spectrum) when byte_size(bins) == 128,
    do: deliver(ref, {:spectrum, spectrum})

  @doc "Deliver `{:hum_audio, ref, {:error, reason}}` and end the listening."
  def fail(ref, reason) do
    :ok = deliver(ref, {:error, reason})
    call({:stop, ref})
  end

  @doc """
  Deliver `{:hum_audio, ref, {:analysis, analysis}}` for an `analyze_file/3`
  reference; the analysis has then finished.
  """
  def analysis(ref, %{duration_ms: _, waveform: _, readings: _} = analysis),
    do: deliver_analysis(ref, {:analysis, analysis})

  @doc "Deliver `{:hum_audio, ref, {:analysis_error, reason}}`; the analysis has then finished."
  def analysis_error(ref, reason), do: deliver_analysis(ref, {:analysis_error, reason})

  defp deliver_analysis(ref, payload) do
    :ok = deliver(ref, payload)
    call({:finish_analysis, ref})
  end

  @doc "Whether `ref` is the current listener."
  def listening?(ref), do: current() == ref

  @doc "Whether `ref` is the current listener with the spectrum on."
  def spectrum?(ref), do: call({:spectrum?, ref})

  @doc "The current listener's reference, or nil."
  def current, do: call(:current)

  @doc "Options the current listener asked for (`spectrum`, `input`), or nil."
  def current_opts, do: call(:current_opts)

  @doc "Paths passed to `analyze_file/3`, newest first, as `{ref, path}`."
  def analyses, do: call(:analyses)

  @doc """
  Whether the analysis `ref` still runs: not yet delivered (`analysis/2`,
  `analysis_error/2`), cancelled, replaced by its owner's next one, or
  ended by its owner's exit.
  """
  def analysing?(ref), do: call({:analysing?, ref})

  @doc "Grant or deny the microphone permission: denied, `listen/2` answers `{:error, :permission}`."
  def set_permission(granted) when is_boolean(granted), do: call({:permission, granted})

  @doc "Deliver `{:hum_audio, ref, {:piano_position, ms}}` to `ref`'s owner."
  def piano_position(ref, ms) when is_reference(ref) and is_number(ms) and ms >= 0,
    do: deliver(ref, {:piano_position, ms})

  @doc "Deliver `{:hum_audio, ref, :piano_finished}` and end piano playback."
  def piano_finished(ref) when is_reference(ref) do
    :ok = deliver(ref, :piano_finished)
    call({:cancel_piano, ref})
  end

  @doc "Deliver `{:hum_audio, ref, {:piano_error, reason}}` and end piano playback."
  def piano_error(ref, reason) when is_reference(ref) do
    :ok = deliver(ref, {:piano_error, reason})
    call({:cancel_piano, ref})
  end

  @doc "Whether `ref` is the current piano playback."
  def piano_playing?(ref) when is_reference(ref), do: current_piano() == ref

  @doc "The current piano playback's reference, or nil."
  def current_piano, do: call(:current_piano)

  @doc "The notes of the current piano playback, or nil."
  def current_piano_notes, do: call(:current_piano_notes)

  @doc "Force `play_piano/2` to fail with `reason`, or `nil` to clear."
  def set_piano_error(reason), do: call({:set_piano_error, reason})

  @doc "Forget everything: no listener, permission granted."
  def reset, do: call(:reset)

  # ── Server ───────────────────────────────────────────────────────────────

  defp call(request) do
    pid =
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, request)
  end

  defp deliver(ref, payload) do
    case call({:owner, ref}) do
      nil ->
        raise ArgumentError,
              "#{inspect(ref)} was never returned by listen/2, analyze_file/3, or play_piano/2"

      owner ->
        send(owner, {:hum_audio, ref, payload})
    end

    :ok
  end

  defp fresh,
    do: %{
      current: nil,
      opts: nil,
      monitor: nil,
      owners: %{},
      analyses: [],
      permission: true,
      piano_ref: nil,
      piano_notes: nil,
      piano_monitor: nil,
      piano_error: nil,
      # analyze_file/3 jobs still "decoding": ref => {owner, monitor}
      running: %{}
    }

  @impl GenServer
  def init(nil), do: {:ok, fresh()}

  @impl GenServer
  def handle_call({:listen, _owner, _opts}, _from, %{permission: false} = s),
    do: {:reply, {:error, :permission}, s}

  def handle_call({:listen, owner, opts}, _from, s) do
    s = stop_current(s)
    ref = make_ref()
    opts = %{spectrum: Keyword.get(opts, :spectrum, false), input: Keyword.get(opts, :input)}

    s = %{
      s
      | current: ref,
        opts: opts,
        monitor: Process.monitor(owner),
        owners: Map.put(s.owners, ref, owner)
    }

    {:reply, {:ok, ref}, s}
  end

  def handle_call({:set_spectrum, ref, on}, _from, %{current: ref} = s),
    do: {:reply, :ok, put_in(s.opts.spectrum, on)}

  def handle_call({:set_spectrum, _ref, _on}, _from, s), do: {:reply, :ok, s}

  def handle_call({:stop, ref}, _from, %{current: ref} = s), do: {:reply, :ok, stop_current(s)}
  def handle_call({:stop, _ref}, _from, s), do: {:reply, :ok, s}

  def handle_call({:analyze, owner, path}, _from, s) do
    others = Enum.count(s.running, fn {_ref, {o, _m}} -> o != owner end)

    cond do
      not Process.alive?(owner) ->
        {:reply, {:error, :owner_dead}, s}

      others >= @max_analyses ->
        {:reply, {:error, :busy}, s}

      true ->
        start_analysis(s, owner, path)
    end
  end

  def handle_call({:cancel_analysis, ref}, _from, s), do: {:reply, :ok, finish(s, ref)}
  def handle_call({:finish_analysis, ref}, _from, s), do: {:reply, :ok, finish(s, ref)}
  def handle_call({:analysing?, ref}, _from, s), do: {:reply, Map.has_key?(s.running, ref), s}

  def handle_call({:owner, ref}, _from, s), do: {:reply, Map.get(s.owners, ref), s}

  def handle_call({:spectrum?, ref}, _from, s),
    do: {:reply, s.current == ref and s.opts.spectrum, s}

  def handle_call(:current, _from, s), do: {:reply, s.current, s}
  def handle_call(:current_opts, _from, s), do: {:reply, s.opts, s}
  def handle_call(:analyses, _from, s), do: {:reply, s.analyses, s}
  def handle_call({:permission, granted}, _from, s), do: {:reply, :ok, %{s | permission: granted}}

  def handle_call({:play_piano, owner, notes}, _from, s) do
    case validate_piano_notes(notes) do
      :ok ->
        cond do
          s.piano_error != nil ->
            {:reply, {:error, s.piano_error}, s}

          not Process.alive?(owner) ->
            {:reply, {:error, :owner_dead}, s}

          true ->
            s = stop_piano(s)
            ref = make_ref()

            s = %{
              s
              | piano_ref: ref,
                piano_notes: notes,
                piano_monitor: Process.monitor(owner),
                owners: Map.put(s.owners, ref, owner)
            }

            {:reply, {:ok, ref}, s}
        end

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  def handle_call({:cancel_piano, ref}, _from, %{piano_ref: ref} = s),
    do: {:reply, :ok, stop_piano(s)}

  def handle_call({:cancel_piano, _ref}, _from, s), do: {:reply, :ok, s}
  def handle_call(:current_piano, _from, s), do: {:reply, s.piano_ref, s}
  def handle_call(:current_piano_notes, _from, s), do: {:reply, s.piano_notes, s}

  def handle_call({:set_piano_error, reason}, _from, s),
    do: {:reply, :ok, %{s | piano_error: reason}}

  def handle_call(:reset, _from, s) do
    _ = s |> stop_current() |> stop_piano()
    Enum.each(s.running, fn {_ref, {_owner, m}} -> Process.demonitor(m, [:flush]) end)
    {:reply, :ok, fresh()}
  end

  # One per owner: the newer one cancels the older.
  defp start_analysis(s, owner, path) do
    older = for {ref, {^owner, _m}} <- s.running, do: ref
    s = Enum.reduce(older, s, &finish(&2, &1))
    ref = make_ref()

    s = %{
      s
      | owners: Map.put(s.owners, ref, owner),
        analyses: [{ref, path} | s.analyses],
        running: Map.put(s.running, ref, {owner, Process.monitor(owner)})
    }

    {:reply, {:ok, ref}, s}
  end

  defp finish(s, ref) do
    case Map.pop(s.running, ref) do
      {nil, _} ->
        s

      {{_owner, m}, running} ->
        Process.demonitor(m, [:flush])
        %{s | running: running}
    end
  end

  # The owner died: the phone's NIF stops the microphone, so does this.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = s),
    do: {:noreply, stop_current(s)}

  # The piano preview's owner died: the NIF stops playback.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{piano_monitor: monitor} = s),
    do: {:noreply, stop_piano(s)}

  # An analysis's owner died: the NIF cancels it.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, s),
    do: {:noreply, %{s | running: Map.reject(s.running, fn {_ref, {_o, m}} -> m == monitor end)}}

  defp stop_current(%{monitor: nil} = s), do: %{s | current: nil, opts: nil}

  defp stop_current(s) do
    Process.demonitor(s.monitor, [:flush])
    %{s | current: nil, opts: nil, monitor: nil}
  end

  defp stop_piano(%{piano_monitor: nil} = s), do: %{s | piano_ref: nil, piano_notes: nil}

  defp stop_piano(s) do
    Process.demonitor(s.piano_monitor, [:flush])
    %{s | piano_ref: nil, piano_notes: nil, piano_monitor: nil}
  end

  defp validate_piano_notes([]), do: {:error, :empty}

  defp validate_piano_notes(notes) when length(notes) > @max_piano_notes,
    do: {:error, :too_many_notes}

  defp validate_piano_notes(notes) do
    Enum.reduce_while(notes, :ok, fn note, :ok ->
      case validate_piano_note(note) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_piano_note(%{start_ms: start_ms, dur_ms: dur_ms, midi: midi} = note)
       when is_number(start_ms) and start_ms >= 0 and is_number(dur_ms) and dur_ms > 0 and
              is_integer(midi) and midi in 0..127 do
    validate_piano_limits(start_ms + dur_ms, Map.get(note, :velocity))
  end

  defp validate_piano_note(_), do: {:error, :invalid_notes}

  defp validate_piano_limits(_end_ms, velocity)
       when not is_nil(velocity) and
              (not is_integer(velocity) or velocity < 1 or velocity > 127),
       do: {:error, :invalid_notes}

  defp validate_piano_limits(end_ms, _velocity) when end_ms > @max_piano_ms,
    do: {:error, :too_long}

  defp validate_piano_limits(_end_ms, _velocity), do: :ok
end
