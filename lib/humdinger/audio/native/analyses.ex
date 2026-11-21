defmodule Humdinger.Audio.Native.Analyses do
  @moduledoc """
  `Humdinger.Audio.Native.analyze_file/3`'s jobs. A job decodes the file
  with `MobAudioIo.decode/2` (mono, at the file's rate) and analyses the
  PCM in one-second chunks with the NIF (`analysis_new/push/finish`), in a
  process of its own; this server keeps the rules:

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

  A job (`run/2`) checks its cancel flag between chunks and sends nothing
  once cancelled.

  Started from `Humdinger.App.on_start/0`; `running/0` is what
  `Humdinger.Audio.Native.info/0` reports as `analyses`.
  """

  use GenServer

  require Logger

  alias Humdinger.Audio.Native

  @max_owners 2
  @max_ms 600_000
  # The decode's cap: ten minutes (and the half second the length check
  # allows) of 48 kHz mono floats. A 44.1 kHz file of that size is longer
  # and refused by the length check; a 96 kHz one is refused past 5 minutes.
  @max_bytes div((@max_ms + 500) * 48_000 * 4, 1000)

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
  # cancel (:atomics | nil), cancelled}; workers: worker monitor => ref;
  # owners: owner => its monitor.
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

        job = %{
          owner: owner,
          path: path,
          worker: nil,
          monitor: nil,
          cancel: nil,
          cancelled: false
        }

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
        :atomics.put(job.cancel, 1, 1)
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
    cancel = :atomics.new(1, [])
    server = self()

    {pid, monitor} =
      spawn_monitor(fn -> send(server, {:analysis_done, ref, run(job.path, cancel)}) end)

    %{
      state
      | jobs: Map.put(state.jobs, ref, %{job | worker: pid, monitor: monitor, cancel: cancel}),
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

  defp run(path, cancel) do
    with {:ok, pcm} <- decode(path),
         :ok <- go_on(cancel),
         {:ok, analysis} <- analyse(pcm, cancel) do
      {:analysis, analysis}
    else
      :cancelled -> :cancelled
      {:error, reason} -> {:analysis_error, reason}
    end
  end

  defp decode(path) do
    case MobAudioIo.decode(path, mono: true, max_bytes: @max_bytes) do
      {:ok, %{rate: rate, frames: frames}}
      when frames > div(rate * @max_ms, 1000) + div(rate, 2) ->
        {:error, :too_long}

      {:ok, pcm} ->
        {:ok, pcm}

      {:error, reason} ->
        {:error, decode_error(reason)}
    end
  end

  # MobAudioIo.decode/2's errors in the contract's words (Humdinger.Audio).
  defp decode_error({:invalid_option, :path}), do: :not_found
  defp decode_error({reason, detail}) when is_binary(detail), do: decode_error(reason)
  defp decode_error(:too_large), do: :too_long
  defp decode_error(:no_memory), do: :alloc

  defp decode_error(reason) when reason in [:not_found, :unsupported, :no_audio, :decode_error],
    do: reason

  defp decode_error(_), do: :decode_error

  defp go_on(cancel), do: if(:atomics.get(cancel, 1) == 1, do: :cancelled, else: :ok)

  defp analyse(%{rate: rate, data: data}, cancel) do
    with {:ok, analysis} <- Native.nif().analysis_new(rate),
         :ok <- push(analysis, data, rate * 4, 0, cancel) do
      case Native.nif().analysis_finish(analysis) do
        %{} = result -> {:ok, result}
        {:error, _} = error -> error
      end
    end
  end

  defp push(_analysis, data, _chunk, offset, _cancel) when offset >= byte_size(data), do: :ok

  defp push(analysis, data, chunk, offset, cancel) do
    piece = binary_part(data, offset, min(chunk, byte_size(data) - offset))

    with :ok <- go_on(cancel),
         :ok <- Native.nif().analysis_push(analysis, piece) do
      push(analysis, data, chunk, offset + chunk, cancel)
    end
  end
end
