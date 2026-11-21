defmodule Humdinger.Audio.Native.Analyses do
  @moduledoc """
  `Humdinger.Audio.Native.analyze_file/3`'s jobs. A job (`run/1`, a process
  of its own) streams the file with `MobAudioIo.decode_stream/3` (mono, at
  the file's rate, a few 4096-frame chunks in flight, so memory stays
  bounded whatever the file's length) and pushes each chunk into the NIF's
  analysis (`analysis_new/push/finish`) as it arrives; this server keeps
  the rules:

    * one analysis per owner: a newer one cancels the owner's running job
      (it ends silently) or replaces the one still waiting, and starts when
      the owner's running job has ended, so an owner never has two decodes
      at once;
    * at most two owners with a running job (cancelled ones too, until they
      end); a third gets `{:error, :busy}`;
    * cancelled by `cancel/1` and by the owner's exit (monitored);
    * the result goes to the owner as `{:hum_audio, ref, {:analysis,
      analysis} | {:analysis_error, reason}}`, sent from here, so nothing
      for a job arrives once `cancel/1` has returned.

  A cancelled job cancels its decode (`MobAudioIo.decode_cancel/1`, within
  one codec buffer) between two chunks and exits; files over 10 minutes
  (and the half second the old engine allowed) are refused by the decode's
  `max_ms`, at once when the container states its length.

  Started from `Humdinger.App.on_start/0`; `running/0` is what
  `Humdinger.Audio.Native.info/0` reports as `analyses`.
  """

  use GenServer

  require Logger

  alias Humdinger.Audio.Native

  @max_owners 2
  # Ten minutes and the half second of slack the old engine allowed.
  @max_ms 600_500

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Analyse `path` for `owner`, answering to `ref`. `:ok` or `{:error, :busy | :owner_dead}`."
  @spec analyze(pid(), reference(), String.t()) :: :ok | {:error, :busy | :owner_dead}
  def analyze(owner, ref, path), do: GenServer.call(__MODULE__, {:analyze, owner, ref, path})

  @doc "Cancel the job `ref` names; nothing for it arrives once this returns. `:ok`."
  @spec cancel(reference()) :: :ok
  def cancel(ref), do: GenServer.call(__MODULE__, {:cancel, ref})

  @doc "Jobs running (cancelled ones too, until they end); 0 when the server isn't running."
  @spec running() :: non_neg_integer()
  def running do
    case GenServer.whereis(__MODULE__) do
      nil -> 0
      pid -> GenServer.call(pid, :running)
    end
  end

  # ── Server ─────────────────────────────────────────────────────────────

  # jobs: ref => %{owner, path, worker (pid | nil: waiting), monitor,
  # cancelled}; workers: worker monitor => ref; owners: owner => its monitor.
  @impl GenServer
  def init(:ok), do: {:ok, %{jobs: %{}, workers: %{}, owners: %{}}}

  @impl GenServer
  def handle_call({:analyze, owner, ref, path}, _from, state) do
    cond do
      not Process.alive?(owner) ->
        {:reply, {:error, :owner_dead}, state}

      running_owners(state, owner) >= @max_owners ->
        {:reply, {:error, :busy}, state}

      true ->
        state = state |> cancel_owner(owner) |> watch(owner)

        job = %{owner: owner, path: path, worker: nil, monitor: nil, cancelled: false}

        state = put_in(state.jobs[ref], job)
        state = if running?(state, owner), do: state, else: start_job(state, ref)
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, ref}, _from, state), do: {:reply, :ok, cancel_job(state, ref)}

  def handle_call(:running, _from, state),
    do: {:reply, Enum.count(state.jobs, fn {_, job} -> job.worker != nil end), state}

  @impl GenServer
  def handle_info({:analysis_done, ref, result}, state) do
    %{monitor: monitor} = state.jobs[ref]
    Process.demonitor(monitor, [:flush])
    {:noreply, finish_job(state, ref, monitor, result)}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.fetch(state.workers, monitor) do
      {:ok, ref} ->
        Logger.error("[hum_audio] analysis worker #{inspect(pid)} died: #{inspect(reason)}")
        {:noreply, finish_job(state, ref, monitor, {:analysis_error, :decode_error})}

      :error ->
        {:noreply, owner_down(state, pid)}
    end
  end

  defp running_owners(state, owner) do
    state.jobs
    |> Enum.filter(fn {_, job} -> job.worker != nil and job.owner != owner end)
    |> Enum.uniq_by(fn {_, job} -> job.owner end)
    |> length()
  end

  defp running?(state, owner),
    do: Enum.any?(state.jobs, fn {_, job} -> job.owner == owner and job.worker != nil end)

  defp watch(state, owner) do
    if Map.has_key?(state.owners, owner),
      do: state,
      else: put_in(state.owners[owner], Process.monitor(owner))
  end

  defp cancel_owner(state, owner) do
    state.jobs
    |> Enum.filter(fn {_, job} -> job.owner == owner end)
    |> Enum.reduce(state, fn {ref, _}, acc -> cancel_job(acc, ref) end)
  end

  # A running job is told to stop and ends silently; a waiting one is dropped.
  defp cancel_job(state, ref) do
    case Map.fetch(state.jobs, ref) do
      {:ok, %{worker: nil}} ->
        drop_job(state, ref)

      {:ok, job} ->
        send(job.worker, :cancel)
        put_in(state.jobs[ref], %{job | cancelled: true})

      :error ->
        state
    end
  end

  defp owner_down(state, owner) do
    state = %{state | owners: Map.delete(state.owners, owner)}
    cancel_owner(state, owner)
  end

  defp start_job(state, ref) do
    job = state.jobs[ref]
    server = self()
    {pid, monitor} = spawn_monitor(fn -> send(server, {:analysis_done, ref, run(job.path)}) end)

    %{
      state
      | jobs: Map.put(state.jobs, ref, %{job | worker: pid, monitor: monitor}),
        workers: Map.put(state.workers, monitor, ref)
    }
  end

  defp finish_job(state, ref, monitor, result) do
    {job, jobs} = Map.pop(state.jobs, ref)
    state = %{state | jobs: jobs, workers: Map.delete(state.workers, monitor)}
    unless result == :cancelled or job.cancelled, do: deliver(job, ref, result)

    # The owner's newer analysis waited for this one's process to end.
    case Enum.find(state.jobs, fn {_, j} -> j.owner == job.owner end) do
      {next, %{worker: nil}} -> start_job(state, next)
      _ -> unwatch_if_idle(state, job.owner)
    end
  end

  defp deliver(job, ref, payload) do
    with {:analysis_error, reason} <- payload do
      Logger.warning("[hum_audio] analysis of #{Path.basename(job.path)}: #{inspect(reason)}")
    end

    send(job.owner, {:hum_audio, ref, payload})
  end

  defp drop_job(state, ref) do
    {job, jobs} = Map.pop(state.jobs, ref)
    unwatch_if_idle(%{state | jobs: jobs}, job.owner)
  end

  defp unwatch_if_idle(state, owner) do
    if Enum.any?(state.jobs, fn {_, job} -> job.owner == owner end) do
      state
    else
      {monitor, owners} = Map.pop(state.owners, owner)
      if monitor, do: Process.demonitor(monitor, [:flush])
      %{state | owners: owners}
    end
  end

  # ── A job ──────────────────────────────────────────────────────────────

  defp run(path) do
    case MobAudioIo.decode_stream(path, self(), mono: true, max_ms: @max_ms) do
      {:ok, decode} -> receive_chunks(decode, nil)
      {:error, reason} -> {:analysis_error, decode_error(reason)}
    end
  end

  # The decode's messages, in order: :decode_started (the rate), :decoded
  # chunks, then one end. A :cancel from the server goes first, ahead of
  # the chunks already queued (up to the decode's window).
  defp receive_chunks(decode, analysis) do
    receive do
      :cancel ->
        _ = MobAudioIo.decode_cancel(decode)
        :cancelled
    after
      0 -> next_chunk(decode, analysis)
    end
  end

  defp next_chunk(decode, analysis) do
    receive do
      :cancel ->
        _ = MobAudioIo.decode_cancel(decode)
        :cancelled

      {:mob_audio_io, :decode_started, ^decode, %{rate: rate}} ->
        case Native.nif().analysis_new(rate) do
          {:ok, analysis} -> receive_chunks(decode, analysis)
          {:error, reason} -> give_up(decode, reason)
        end

      {:mob_audio_io, :decoded, ^decode, pcm} ->
        case Native.nif().analysis_push(analysis, pcm) do
          :ok ->
            _ = MobAudioIo.decode_ack(decode)
            receive_chunks(decode, analysis)

          {:error, reason} ->
            give_up(decode, reason)
        end

      {:mob_audio_io, :decode_done, ^decode, _} ->
        finish(analysis)

      {:mob_audio_io, :decode_error, ^decode, %{reason: reason}} ->
        {:analysis_error, decode_error(reason)}
    end
  end

  defp give_up(decode, reason) do
    _ = MobAudioIo.decode_cancel(decode)
    {:analysis_error, reason}
  end

  defp finish(nil), do: {:analysis_error, :no_audio}

  defp finish(analysis) do
    case Native.nif().analysis_finish(analysis) do
      %{} = result -> {:analysis, result}
      {:error, reason} -> {:analysis_error, reason}
    end
  end

  # The plugin's decode errors in the contract's words (Humdinger.Audio).
  defp decode_error(:no_memory), do: :alloc

  defp decode_error(reason)
       when reason in [:not_found, :unsupported, :no_audio, :decode_error, :too_long],
       do: reason

  defp decode_error({:invalid_option, :path}), do: :not_found
  defp decode_error(_), do: :decode_error
end
