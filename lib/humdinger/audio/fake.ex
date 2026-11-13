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

  The background service is recorded too: `background/0` shows what it
  shows, `tap_background/1` presses a button.
  """

  @behaviour Humdinger.Audio

  use GenServer

  @inputs [
    %{id: 1, name: "Built-in microphone", kind: :builtin_mic},
    %{id: 7, name: "Headset", kind: :wired_headset}
  ]

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
  def background_start(owner, notice) when is_pid(owner),
    do: call({:background_start, owner, notice})

  @impl Humdinger.Audio
  def background_update(notice), do: call({:background_update, notice})

  @impl Humdinger.Audio
  def background_stop, do: call(:background_stop)

  @impl Humdinger.Audio
  def background_running?, do: background() != nil

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

  @doc "Deliver `{:hum_audio, ref, {:analysis, analysis}}` for an `analyze_file/3` reference."
  def analysis(ref, %{duration_ms: _, waveform: _, readings: _} = analysis),
    do: deliver(ref, {:analysis, analysis})

  @doc "Deliver `{:hum_audio, ref, {:analysis_error, reason}}`."
  def analysis_error(ref, reason), do: deliver(ref, {:analysis_error, reason})

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

  @doc "Grant or deny the microphone permission: denied, `listen/2` answers `{:error, :permission}`."
  def set_permission(granted) when is_boolean(granted), do: call({:permission, granted})

  @doc "`%{owner, notice}` while the background service runs, else nil."
  def background, do: call(:background)

  @doc """
  Press a notification button: sends `{:background, action}` to the
  owner. `{:error, :not_running}` when the service doesn't run.
  """
  def tap_background(action) when action in [:pause, :resume, :record, :record_stop, :stop],
    do: call({:tap_background, action})

  @doc "Forget everything: no listener, permission granted, no service."
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
        raise ArgumentError, "#{inspect(ref)} was never returned by listen/2 or analyze_file/3"

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
      background: nil,
      bg_monitor: nil
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
    ref = make_ref()
    s = %{s | owners: Map.put(s.owners, ref, owner), analyses: [{ref, path} | s.analyses]}
    {:reply, {:ok, ref}, s}
  end

  def handle_call({:owner, ref}, _from, s), do: {:reply, Map.get(s.owners, ref), s}

  def handle_call({:spectrum?, ref}, _from, s),
    do: {:reply, s.current == ref and s.opts.spectrum, s}

  def handle_call(:current, _from, s), do: {:reply, s.current, s}
  def handle_call(:current_opts, _from, s), do: {:reply, s.opts, s}
  def handle_call(:analyses, _from, s), do: {:reply, s.analyses, s}
  def handle_call({:permission, granted}, _from, s), do: {:reply, :ok, %{s | permission: granted}}

  def handle_call({:background_start, _owner, _notice}, _from, %{permission: false} = s),
    do: {:reply, {:error, :permission}, s}

  def handle_call({:background_start, owner, notice}, _from, s) do
    s = stop_background(s)

    if Process.alive?(owner) do
      bg = %{owner: owner, notice: notice}
      {:reply, :ok, %{s | background: bg, bg_monitor: Process.monitor(owner)}}
    else
      {:reply, {:error, :owner_dead}, s}
    end
  end

  def handle_call({:background_update, _notice}, _from, %{background: nil} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:background_update, notice}, _from, s),
    do: {:reply, :ok, put_in(s.background.notice, notice)}

  def handle_call(:background_stop, _from, s), do: {:reply, :ok, stop_background(s)}
  def handle_call(:background, _from, s), do: {:reply, s.background, s}

  def handle_call({:tap_background, _action}, _from, %{background: nil} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:tap_background, action}, _from, s) do
    send(s.background.owner, {:background, action})
    {:reply, :ok, s}
  end

  def handle_call(:reset, _from, s) do
    _ = s |> stop_current() |> stop_background()
    {:reply, :ok, fresh()}
  end

  # The owner died: the phone's NIF stops the microphone, so does this.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = s),
    do: {:noreply, stop_current(s)}

  # The background service's owner died: the NIF stops the service.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{bg_monitor: monitor} = s),
    do: {:noreply, stop_background(s)}

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, s), do: {:noreply, s}

  defp stop_current(%{monitor: nil} = s), do: %{s | current: nil, opts: nil}

  defp stop_current(s) do
    Process.demonitor(s.monitor, [:flush])
    %{s | current: nil, opts: nil, monitor: nil}
  end

  defp stop_background(%{bg_monitor: nil} = s), do: %{s | background: nil}

  defp stop_background(s) do
    Process.demonitor(s.bg_monitor, [:flush])
    %{s | background: nil, bg_monitor: nil}
  end
end
