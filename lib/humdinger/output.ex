defmodule Humdinger.Output do
  @moduledoc """
  Where the MIDI goes. A long-lived GenServer (started from `App.on_start`)
  that takes the Tracker's events, encodes them once on the configured
  channel (`Humdinger.Midi`) and sends them to every destination that is both
  enabled and available:

  | id | name | sends with |
  |---|---|---|
  | `:fmutate` | FMutate | `Humdinger.FMutate.send_midi/1` (Erlang distribution) |
  | `:port` | Humdinger port | `Humdinger.Output.Port` (a virtual MIDI device) |
  | `:usb` | USB MIDI out | `Humdinger.Output.Device`, every USB device plugged in |
  | `:bt` | Bluetooth MIDI | `Humdinger.Output.Device`, the connected BLE-MIDI device |

  Output keeps, per destination, the notes it left sounding (as `{source,
  channel, note}`, the source being `:live` or a session), so turning a
  destination off sends it exactly the note-offs it needs, `panic/0`
  silences everything (those note-offs plus CC 123 on each channel used),
  and a channel change can't strand a note on the old one.

  One source plays at a time. The live source is `send_events/1` (the
  Engine). A session (`acquire/1`, owned and monitored; `Humdinger.Player`
  for phrase playback and the test note) replaces it: on acquire the live
  notes are released and the controllers reset, and live events are dropped
  until the session is released. A newer session preempts an older one (its
  notes released, its owner told `{:output, :session_ended, ref}`); a
  session whose owner dies has its notes released. Output is the one
  arbiter, so this holds across Engine restarts. Followers
  (`follow_session/1`: the Engine) get `{:output, :session, :active |
  :idle}` at once and on change, and start their notes afresh after it.

  Output never leaves a receiver stuck:

  * It traps exits; `terminate/2` (a crash, or its supervisor stopping it)
    sends the panic to every destination directly, each write isolated (a
    destination that raises is logged and skipped). The Engine's own
    release in its `terminate/2` reaches a running Output only: when
    Output is the one that died, this is what silences the notes.
  * A destination that comes back gets CC 123 and the controller resets on
    all 16 channels before any new note: the port when Output starts and
    when the first app opens it again, a USB or Bluetooth output once
    mob_midi reports it open. FMutate does this itself on (re)connect.
  * The port and external outputs refuse bytes while their queue is full behind
    a stalled listener (`{:error, :queue_full}`): Output discards the stale
    queue (`MobMidi.discard/1`), stops sending to that output (other
    destinations carry on and stay tracked), and when `{:midi, :drained, ...}`
    arrives sends the note-offs it still knows of, CC 123 and resets before
    anything new.
  * FMutate dropping MIDI (`{:fmutate, :midi, :resyncing}`) takes it out
    until it has resynced (`:ready`); its notes are FMutate's to release.

  Settings: the channel and the enabled flags are read once at start from
  `Humdinger.Settings.load/0`; the Engine sends channel changes with
  `configure/1` (after the note-offs for the old channel, which the cast
  order keeps first). `set_enabled/2` saves the flags with
  `Humdinger.Settings.update/1`. Without a Settings module (a branch that
  lacks it) the defaults are channel 1, FMutate and port on, USB and
  Bluetooth off.

  Subscribers (`subscribe/1`, monitored) get:

  * `{:output, :destinations, list}` when they subscribe and whenever the
    list changes (see `destinations/0`);
  * `{:output, :sent, summary}`, e.g. `"A4 on · vel 92 · ch 1"`, for what
    was sent, at most every 100 ms (the latest one wins);
  * `{:output, :bluetooth, view}` when the Bluetooth scan or connection
    changes (see `bluetooth/0`).

  The modules it talks to are options, so tests run it against doubles:
  `:fmutate` (default `Application.get_env(:humdinger, :fmutate,
  Humdinger.FMutate)`: `status/0`, `subscribe/1`, `send_midi/1`),
  `:settings` (default `Application.get_env(:humdinger, :settings,
  Humdinger.Settings)`: `load/0`, `update/1`), `:port` (default
  `Humdinger.Output.Port`) and `:device` (default `Humdinger.Output.Device`).
  A module that isn't loaded is left out.
  """

  use GenServer
  require Logger

  alias Humdinger.Midi
  alias Humdinger.Output.{Device, Port}

  @ids [:fmutate, :port, :usb, :bt]
  @default_enabled %{fmutate: true, port: true, usb: false, bt: false}
  @test_note %{start_ms: 0, dur_ms: 300, midi: 69, velocity: 92}
  @scan_ms 10_000
  @sent_interval_ms 100
  @fmutate_retry_ms 1_000

  @type id :: :fmutate | :port | :usb | :bt
  @type destination :: %{
          id: id(),
          name: String.t(),
          detail: String.t(),
          enabled: boolean(),
          available: boolean()
        }
  @type bluetooth :: %{
          scanning: boolean(),
          found: [%{address: String.t(), name: String.t(), rssi: integer()}],
          error: atom() | nil,
          connecting: String.t() | nil,
          paired: %{address: String.t(), name: String.t()} | nil
        }

  defstruct [
    :fmutate,
    # Monitor on the FMutate process: its subscribers die with it.
    :fmutate_ref,
    # The Player that plays test notes (started on the first one).
    :test_player,
    # The test player's clock (nil: the real one); tests drive time with it.
    :clock,
    # The session playing instead of the live source: %{ref, owner, mon}.
    :session,
    :settings,
    :port,
    :device,
    :shown,
    :shown_bluetooth,
    :last_sent,
    :sent_at,
    :sent_timer,
    :connecting,
    :paired,
    channel: 1,
    enabled: @default_enabled,
    fmutate_status: :unpaired,
    # FMutate dropped MIDI and is resynchronising (see the moduledoc).
    fmutate_resync: false,
    # The virtual "Humdinger" port: its mob_midi id once open, the apps
    # listening, and `resync` while its refused queue drains (`gen`: highest
    # queue generation seen, from discard/2 or a handled :drained).
    vport: %{id: nil, available: false, listeners: 0, resync: false, gen: 0},
    # pid => monitor: processes told about sessions (follow_session/1).
    followers: %{},
    # id => Device.t(): the USB and Bluetooth devices Humdinger can send to.
    devices: %{},
    # id => :opening | :open | {:draining, gen} | {:failed, reason}: outputs asked of mob_midi.
    opened: %{},
    # id => highest queue generation seen per USB/BT device.
    device_gens: %{},
    # address => device_id from {:midi, :connected, ...}, so forget can close(id).
    bt_ids: %{},
    sounding: Map.new(@ids, &{&1, MapSet.new()}),
    scanning: false,
    found: [],
    scan_error: nil,
    subscribers: %{},
    sent_interval: @sent_interval_ms
  ]

  # ── API ──────────────────────────────────────────────────────────────────

  @doc """
  Starts Output. Options: `:name` (default `Humdinger.Output`; nil for none),
  `:fmutate`, `:settings`, `:port`, `:device` (see the moduledoc),
  `:sent_interval_ms` (default 100), `:clock` (the test-note player's
  clock, a zero-arity function returning ms; tests use it to drive time).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # Like Task: test doubles called from Output find their test via $callers.
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, {opts, callers}, if(name, do: [name: name], else: []))
  end

  @doc "Sends events (in order) on the configured channel to every enabled, available destination."
  @spec send_events([Midi.event()], GenServer.server()) :: :ok
  def send_events(events, server \\ __MODULE__) when is_list(events),
    do: GenServer.cast(server, {:send_events, events})

  @doc "Changes the channel (`channel: 1..16`). Notes still sounding keep their own channel."
  @spec configure(keyword() | map(), GenServer.server()) :: :ok
  def configure(opts, server \\ __MODULE__),
    do: GenServer.cast(server, {:configure, Map.new(opts)})

  @doc """
  Starts a session for `owner` (see the moduledoc): the live notes are
  released and live events dropped until `release/2` or the owner exits. A
  running session is preempted. The events go through `session_events/3`.
  """
  @spec acquire(pid(), GenServer.server()) :: {:ok, reference()}
  def acquire(owner \\ self(), server \\ __MODULE__) when is_pid(owner),
    do: GenServer.call(server, {:acquire, owner})

  @doc "Sends a session's events (dropped once the session has ended)."
  @spec session_events(reference(), [Midi.event()], GenServer.server()) :: :ok
  def session_events(ref, events, server \\ __MODULE__) when is_list(events),
    do: GenServer.cast(server, {:session_events, ref, events})

  @doc """
  Ends a session: note-offs for whatever it left sounding, then the live
  source is back. Returns once followers have been told.
  """
  @spec release(reference(), GenServer.server()) :: :ok
  def release(ref, server \\ __MODULE__), do: GenServer.call(server, {:release, ref})

  @doc "Sends `pid` `{:output, :session, :active | :idle}` now and on every change, until it exits."
  @spec follow_session(pid(), GenServer.server()) :: :ok
  def follow_session(pid, server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:follow_session, pid})

  @doc """
  The Output board's rows, in order: FMutate, Humdinger port, USB MIDI out,
  Bluetooth MIDI, each `%{id, name, detail, enabled, available}`.
  """
  @spec destinations(GenServer.server()) :: [destination()]
  def destinations(server \\ __MODULE__), do: GenServer.call(server, :destinations)

  @doc """
  Turns a destination on or off and saves it. Turning one off first sends it
  the note-offs for the notes it has sounding.
  """
  @spec set_enabled(id(), boolean(), GenServer.server()) :: :ok
  def set_enabled(id, enabled, server \\ __MODULE__) when id in @ids and is_boolean(enabled),
    do: GenServer.call(server, {:set_enabled, id, enabled})

  @doc """
  Plays A4 at velocity 92 for 300 ms on every enabled, available destination,
  through a `Humdinger.Player` in a session (so the singer stays out while
  it sounds). A tap while it sounds starts it again: the note is struck
  anew and lasts 300 ms from the last tap.
  """
  @spec test_note(GenServer.server()) :: :ok
  def test_note(server \\ __MODULE__) do
    player = GenServer.call(server, :test_player)
    Humdinger.Player.play(player, [@test_note], :test_note)
  end

  @doc """
  Returns once Output has handled everything the caller sent it before (the
  Engine's `terminate/2` uses it so its release goes out before Output is
  stopped).
  """
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc """
  Silences every enabled, available destination: note-offs for the notes Output knows
  are sounding, then CC 123 (All Notes Off) on each channel they use and on
  the current one.
  """
  @spec panic(GenServer.server()) :: :ok
  def panic(server \\ __MODULE__), do: GenServer.call(server, :panic)

  @doc "The line for the last event sent anywhere, or nil."
  @spec last_sent(GenServer.server()) :: String.t() | nil
  def last_sent(server \\ __MODULE__), do: GenServer.call(server, :last_sent)

  @doc "Sends Output's messages to `pid` until it exits (see the moduledoc)."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid, server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:subscribe, pid})

  @doc """
  The Bluetooth-MIDI state for the Output screen: `scanning`, devices `found`
  by the last scan, the last `error`, the address `connecting`, and the
  `paired` device (the last one connected, remembered across launches).
  """
  @spec bluetooth(GenServer.server()) :: bluetooth()
  def bluetooth(server \\ __MODULE__), do: GenServer.call(server, :bluetooth)

  @doc """
  Scans 10 s for Bluetooth-MIDI devices ("Scan Bluetooth"). Scan errors arrive
  in `{:output, :bluetooth, view}` (or immediately on unsupported platforms);
  on `:permission_denied`, request the `:midi_bluetooth` capability with
  `Mob.Permissions.request/2` and retry.
  """
  @spec scan_bluetooth(GenServer.server()) :: :ok | {:error, atom()}
  def scan_bluetooth(server \\ __MODULE__), do: GenServer.call(server, :scan_bluetooth)

  @doc "Ends a Bluetooth scan early."
  @spec stop_bluetooth_scan(GenServer.server()) :: :ok
  def stop_bluetooth_scan(server \\ __MODULE__), do: GenServer.call(server, :stop_bluetooth_scan)

  @doc "Connects a Bluetooth-MIDI device found by the scan, by address."
  @spec connect_bluetooth(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def connect_bluetooth(address, server \\ __MODULE__) when is_binary(address),
    do: GenServer.call(server, {:connect_bluetooth, address})

  @doc "Disconnects and forgets the paired Bluetooth-MIDI device."
  @spec forget_bluetooth(GenServer.server()) :: :ok
  def forget_bluetooth(server \\ __MODULE__), do: GenServer.call(server, :forget_bluetooth)

  # ── Server ───────────────────────────────────────────────────────────────

  @impl GenServer
  def init({opts, callers}) do
    Process.put(:"$callers", callers)
    # Exits from the supervisor reach terminate/2, which silences everything.
    Process.flag(:trap_exit, true)

    state =
      load_settings(%__MODULE__{
        fmutate: module_opt(opts, :fmutate, Humdinger.FMutate),
        settings: module_opt(opts, :settings, Humdinger.Settings),
        port: Keyword.get(opts, :port, Port),
        device: Keyword.get(opts, :device, Device),
        sent_interval: Keyword.get(opts, :sent_interval_ms, @sent_interval_ms),
        clock: Keyword.get(opts, :clock)
      })

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    state = link_fmutate(state)
    _ = state.port.open(Port.name())
    _ = state.device.list()

    state =
      %{state | paired: state.device.recall()}
      |> reconnect_bluetooth()

    {:noreply, %{state | shown: destination_list(state), shown_bluetooth: bluetooth_view(state)}}
  end

  @impl GenServer
  # The live source is out while a session plays.
  def handle_cast({:send_events, _events}, %{session: %{}} = state), do: {:noreply, state}

  def handle_cast({:send_events, events}, state) do
    {:noreply, state |> deliver_events(events, state.channel, :live) |> changed()}
  end

  def handle_cast({:session_events, ref, events}, %{session: %{ref: ref}} = state) do
    {:noreply, state |> deliver_events(events, state.channel, ref) |> changed()}
  end

  def handle_cast({:session_events, _stale, _events}, state), do: {:noreply, state}

  def handle_cast({:configure, %{channel: channel}}, state) when is_integer(channel),
    do: {:noreply, %{state | channel: Midi.channel(channel)}}

  def handle_cast({:configure, _}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(:test_player, _from, %{test_player: nil} = state) do
    {:ok, player} = Humdinger.Player.start_link(test_player_opts(state))
    {:reply, player, %{state | test_player: player}}
  end

  def handle_call(:test_player, _from, state), do: {:reply, state.test_player, state}

  def handle_call({:acquire, owner}, _from, state) do
    state =
      case state.session do
        # A newer session preempts the running one.
        %{} = old ->
          send(old.owner, {:output, :session_ended, old.ref})
          end_session(state)

        # The live source gives way: its notes off, its controllers back.
        nil ->
          state |> release_source(:live, true) |> tell_followers(:active)
      end

    ref = make_ref()
    session = %{ref: ref, owner: owner, mon: Process.monitor(owner)}
    {:reply, {:ok, ref}, changed(%{state | session: session})}
  end

  def handle_call({:release, ref}, _from, %{session: %{ref: ref}} = state),
    do: {:reply, :ok, state |> end_session() |> tell_followers(:idle) |> changed()}

  def handle_call({:release, _stale}, _from, state), do: {:reply, :ok, state}

  def handle_call({:follow_session, pid}, _from, state) do
    followers = Map.put_new_lazy(state.followers, pid, fn -> Process.monitor(pid) end)
    send(pid, {:output, :session, if(state.session, do: :active, else: :idle)})
    {:reply, :ok, %{state | followers: followers}}
  end

  def handle_call(:destinations, _from, state), do: {:reply, destination_list(state), state}
  def handle_call(:last_sent, _from, state), do: {:reply, state.last_sent, state}
  def handle_call(:bluetooth, _from, state), do: {:reply, bluetooth_view(state), state}

  def handle_call({:set_enabled, id, enabled}, _from, state) do
    state =
      if state.enabled[id] == enabled do
        state
      else
        persist_enabled(state, id, enabled)
        toggle(state, id, enabled)
      end

    {:reply, :ok, changed(state)}
  end

  def handle_call(:panic, _from, state), do: {:reply, :ok, state |> panic_all() |> changed()}

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
      end

    send(pid, {:output, :destinations, destination_list(state)})
    {:reply, :ok, state}
  end

  def handle_call(:scan_bluetooth, _from, state) do
    case state.device.scan(@scan_ms) do
      :ok ->
        {:reply, :ok, changed(%{state | scanning: true, found: [], scan_error: nil})}

      {:error, reason} = error ->
        {:reply, error, changed(%{state | scanning: false, scan_error: reason})}
    end
  end

  def handle_call(:stop_bluetooth_scan, _from, state) do
    _ = state.device.stop_scan()
    {:reply, :ok, changed(%{state | scanning: false})}
  end

  # One Bluetooth device at a time: connecting another drops the paired one.
  def handle_call({:connect_bluetooth, address}, _from, state) do
    state =
      case state.paired do
        %{address: ^address} -> state
        %{address: old} -> drop_bluetooth(state, old)
        nil -> state
      end

    case state.device.connect(address) do
      :ok -> {:reply, :ok, changed(%{state | connecting: address, scan_error: nil})}
      {:error, reason} = error -> {:reply, error, changed(%{state | scan_error: reason})}
    end
  end

  def handle_call(:forget_bluetooth, _from, state) do
    state =
      for address <- Enum.uniq([state.paired && state.paired.address, state.connecting]),
          is_binary(address),
          reduce: state do
        acc -> drop_bluetooth(acc, address)
      end

    state.device.remember(nil)
    {:reply, :ok, changed(%{state | paired: nil, connecting: nil})}
  end

  @impl GenServer
  # The test player crashed: the next test note starts another.
  def handle_info({:EXIT, pid, _reason}, %{test_player: pid} = state),
    do: {:noreply, %{state | test_player: nil}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:player, :finished, _tag}, state), do: {:noreply, state}

  # FMutate dropped MIDI: it panics its synth itself and says when it can
  # take MIDI again; until then nothing goes to it.
  def handle_info({:fmutate, :midi, :resyncing}, state) do
    state = put_in(state.sounding[:fmutate], MapSet.new())
    {:noreply, changed(%{state | fmutate_resync: true})}
  end

  def handle_info({:fmutate, :midi, :ready}, state),
    do: {:noreply, changed(%{state | fmutate_resync: false})}

  def handle_info(:flush_sent, state) do
    broadcast(state, {:output, :sent, state.last_sent})
    {:noreply, %{state | sent_at: now(), sent_timer: nil}}
  end

  def handle_info(:link_fmutate, state), do: {:noreply, state |> link_fmutate() |> changed()}

  def handle_info({:fmutate, :status, status}, state),
    do: {:noreply, %{state | fmutate_status: status} |> prune_sounding() |> changed()}

  def handle_info({:midi, :devices, payload}, state) do
    {:noreply, state |> reconcile_devices(Device.parse(payload)) |> changed()}
  end

  def handle_info({:midi, event, _}, state) when event in [:device_added, :device_removed] do
    _ = state.device.list()
    {:noreply, state}
  end

  def handle_info({:midi, :opened, %{device: id, direction: :virtual}}, state) do
    state = %{state | vport: %{state.vport | id: id, available: true, resync: false, gen: 0}}
    {:noreply, changed(state)}
  end

  def handle_info(
        {:midi, :virtual_status, %{device: id, listeners: n}},
        %{vport: %{id: id}} = state
      )
      when is_integer(id) and is_integer(n) and n >= 0 do
    {:noreply, state |> handle_virtual_status(n) |> changed()}
  end

  # The output is open: reset the device before the first note, since it may
  # still hold notes from before it was closed or Humdinger restarted.
  def handle_info({:midi, :opened, %{device: id, direction: :output} = info}, state) do
    if Map.has_key?(state.opened, id) and Map.get(info, :port, 0) == 0 do
      state = %{state | opened: Map.put(state.opened, id, :open)}
      {_, state} = reset_device(state, id)
      {:noreply, changed(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:midi, :drained, %{device: id, generation: gen} = info}, state)
      when is_integer(id) and is_integer(gen) do
    if Map.get(info, :port, 0) == 0 do
      {:noreply, state |> handle_drained(id, gen) |> changed()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:midi, :bluetooth_scan, :started}, state),
    do: {:noreply, changed(%{state | scanning: true, scan_error: nil})}

  def handle_info({:midi, :bluetooth_scan, :stopped}, state),
    do: {:noreply, changed(%{state | scanning: false})}

  def handle_info({:midi, :bluetooth_device, %{address: address} = found}, state) do
    {:noreply, state |> add_bluetooth_found(address, found) |> changed()}
  end

  def handle_info(
        {:midi, :connected, %{device: id, address: address}},
        %{connecting: address} = state
      ) do
    {:noreply, state |> bluetooth_connected(id, address) |> changed()}
  end

  # A connection nobody is waiting for any more (forgotten, or replaced).
  def handle_info({:midi, :connected, %{device: id}}, state) do
    _ = state.device.close(id)
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :open_virtual, reason: reason}}, state) do
    Logger.warning("[output] virtual MIDI port unavailable: #{inspect(reason)}")

    state =
      %{state | vport: %{state.vport | available: false, id: nil, listeners: 0, resync: false}}
      |> prune_sounding()

    {:noreply, changed(state)}
  end

  def handle_info({:midi, :error, %{device: id, op: :open_output, reason: reason}}, state) do
    {:noreply, state |> handle_open_output_error(id, reason) |> changed()}
  end

  def handle_info({:midi, :error, %{op: :scan_bluetooth, reason: reason}}, state) do
    {:noreply, changed(%{state | scanning: false, scan_error: reason})}
  end

  def handle_info(
        {:midi, :error, %{op: :connect_bluetooth, reason: reason}},
        %{connecting: addr} = state
      )
      when is_binary(addr) do
    {:noreply, changed(%{state | connecting: nil, scan_error: reason})}
  end

  def handle_info({:midi, :error, %{op: :list_devices, reason: reason}}, state) do
    Logger.warning("[output] MIDI device list failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:midi, _, _}, state), do: {:noreply, state}

  # FMutate restarted (its supervisor brings it back with no subscribers):
  # treat it as disconnected and subscribe again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{fmutate_ref: ref} = state) do
    send(self(), :link_fmutate)
    state = %{state | fmutate_ref: nil, fmutate_status: :disconnected, fmutate_resync: false}
    {:noreply, state |> prune_sounding() |> changed()}
  end

  # A session's owner died without releasing it: its notes go off here.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{session: %{mon: mon}} = state),
    do: {:noreply, state |> end_session() |> tell_followers(:idle) |> changed()}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | subscribers: Map.delete(state.subscribers, pid),
         followers: Map.delete(state.followers, pid)
     }}
  end

  # Crashed or stopped by its supervisor: silence every destination directly
  # (best effort: each write is guarded, see guarded/2).
  @impl GenServer
  def terminate(_reason, state) do
    panic_all(state)
    :ok
  end

  defp test_player_opts(state) do
    opts = [owner: self(), output: {__MODULE__, self()}]
    if state.clock, do: Keyword.put(opts, :clock, state.clock), else: opts
  end

  # ── Sessions ─────────────────────────────────────────────────────────────

  # Note-offs for the session's notes; the live source is back.
  defp end_session(%{session: session} = state) do
    Process.demonitor(session.mon, [:flush])
    %{release_source(state, session.ref, false) | session: nil}
  end

  defp tell_followers(state, what) do
    for pid <- Map.keys(state.followers), do: send(pid, {:output, :session, what})
    state
  end

  # Note-offs for what `source` has sounding on every destination, and with
  # `reset?` the controllers back to rest on its channels and the current one.
  defp release_source(state, source, reset?) do
    targets = targets(state)

    Enum.reduce(@ids, state, fn id, state ->
      {mine, rest} = Enum.split_with(state.sounding[id], &(elem(&1, 0) == source))
      state = put_in(state.sounding[id], MapSet.new(rest))
      if id in targets, do: release_notes(state, id, mine, reset?), else: state
    end)
  end

  defp release_notes(state, id, notes, reset?) do
    offs = for {_, channel, note} <- notes, do: Midi.encode({:note_off, note}, channel)
    channels = notes |> Enum.map(&elem(&1, 1)) |> Enum.concat([state.channel]) |> Enum.uniq()
    resets = if reset?, do: Enum.flat_map(channels, &Midi.reset_controllers/1), else: []
    state |> write_all(id, offs ++ resets) |> elem(1)
  end

  defp reset_device(state, id), do: write_device_all(state, id, Midi.panic())

  # ── Sending ──────────────────────────────────────────────────────────────

  defp deliver_events(state, [], _channel, _source), do: state

  defp deliver_events(state, events, channel, source) do
    case targets(state) do
      [] ->
        state

      targets ->
        state = Enum.reduce(events, state, &deliver(&2, targets, &1, channel, source))
        note_sent(state, Midi.describe(List.last(events), channel))
    end
  end

  # Each destination is tracked on its own: one that took the message
  # records it; the port refusing it (or an earlier message of this batch)
  # records nothing, and a refused note-off leaves its note sounding, to be
  # released when the port drains.
  defp deliver(state, targets, event, channel, source) do
    bytes = Midi.encode(event, channel)

    Enum.reduce(targets, state, fn id, state ->
      with true <- sendable?(state, id),
           {:ok, state} <- write_all(state, id, [bytes]) do
        update_in(state, [Access.key(:sounding), id], &track(&1, bytes, channel, source))
      else
        false -> state
        {:refused, state} -> state
      end
    end)
  end

  # The note is read back from the bytes, so it is the clamped one.
  defp track(set, <<status, note, _>>, channel, source) when status in 0x90..0x9F,
    do: MapSet.put(set, {source, channel, note})

  defp track(set, <<status, note, _>>, channel, source) when status in 0x80..0x8F,
    do: MapSet.delete(set, {source, channel, note})

  defp track(set, _bytes, _channel, _source), do: set

  # One destination failing (a NIF exception, an adapter process gone) must
  # not stop the others: the failure is logged and the write skipped.
  defp guarded(id, fun) do
    fun.()
  catch
    kind, reason ->
      Logger.warning("[output] write to #{id} failed: " <> Exception.format_banner(kind, reason))
      {:error, :failed}
  end

  # Writes in order: `{:ok, state}`, or `{:refused, state}` when every target
  # output answered `{:error, :queue_full}` (discarded, waiting for :drained),
  # which stops the rest of the batch.
  defp write_all(state, :fmutate, messages) do
    for bytes <- messages, do: guarded(:fmutate, fn -> state.fmutate.send_midi(bytes) end)
    {:ok, state}
  end

  defp write_all(%{vport: %{id: nil}} = state, :port, _messages), do: {:ok, state}

  defp write_all(state, :port, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn bytes, {:ok, state} ->
      write_port(state, bytes)
    end)
  end

  defp write_all(state, id, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn bytes, {:ok, state} ->
      write_destination_devices(state, id, bytes)
    end)
  end

  defp write_port(state, bytes) do
    case guarded(:port, fn -> state.port.send(state.vport.id, bytes) end) do
      {:error, :queue_full} -> {:halt, {:refused, mark_port_refused(state)}}
      _ -> {:cont, {:ok, state}}
    end
  end

  defp write_destination_devices(state, id, bytes) do
    {delivered?, state} =
      Enum.reduce(open_devices(state, id), {false, state}, fn device_id, acc ->
        write_one_device(acc, id, device_id, bytes)
      end)

    if delivered?, do: {:cont, {:ok, state}}, else: {:halt, {:refused, state}}
  end

  defp write_one_device({ok?, state}, id, device_id, bytes) do
    case guarded(id, fn -> state.device.send(device_id, bytes) end) do
      {:error, :queue_full} -> {ok?, mark_device_refused(state, device_id)}
      _ -> {true, state}
    end
  end

  defp write_device_all(state, device_id, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn bytes, {:ok, state} ->
      write_device(state, device_id, bytes)
    end)
  end

  defp write_device(state, device_id, bytes) do
    case guarded(:device, fn -> state.device.send(device_id, bytes) end) do
      {:error, :queue_full} -> {:halt, {:refused, mark_device_refused(state, device_id)}}
      _ -> {:cont, {:ok, state}}
    end
  end

  defp mark_port_refused(state) do
    gen =
      case guarded(:port, fn -> state.port.discard(state.vport.id) end) do
        {:ok, gen} when is_integer(gen) -> max(state.vport.gen, gen)
        _ -> state.vport.gen
      end

    %{state | vport: %{state.vport | resync: true, gen: gen}}
  end

  defp mark_device_refused(state, device_id) do
    prev = Map.get(state.device_gens, device_id, 0)

    gen =
      case guarded(:device, fn -> state.device.discard(device_id) end) do
        {:ok, gen} when is_integer(gen) -> max(prev, gen)
        _ -> prev
      end

    %{
      state
      | opened: Map.put(state.opened, device_id, {:draining, gen}),
        device_gens: Map.put(state.device_gens, device_id, gen)
    }
  end

  # All 16 channels of the port reset when an app may hold notes Output
  # doesn't know of: at start (a previous Output's) and when the first app
  # opens it.
  defp reset_port(state) do
    if listened?(state),
      do: state |> write_all(:port, Midi.panic()) |> elem(1),
      else: state
  end

  defp targets(state), do: Enum.filter(@ids, &(state.enabled[&1] and sendable?(state, &1)))

  defp note_sent(state, summary) do
    state = %{state | last_sent: summary}
    now = now()

    cond do
      state.sent_timer ->
        state

      is_nil(state.sent_at) or now - state.sent_at >= state.sent_interval ->
        broadcast(state, {:output, :sent, summary})
        %{state | sent_at: now}

      true ->
        delay = state.sent_at + state.sent_interval - now
        %{state | sent_timer: Process.send_after(self(), :flush_sent, delay)}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Note-offs for what `id` has sounding (when it can still be reached), then
  # the controllers back to rest on each channel it played on and the current
  # one, so turning it back on later doesn't start out bent or faded.
  defp silence_destination(state, id) do
    state =
      if sendable?(state, id) do
        offs =
          for {_source, channel, note} <- state.sounding[id],
              do: Midi.encode({:note_off, note}, channel)

        resets = Enum.flat_map(channels(state, id), &Midi.reset_controllers/1)
        state |> write_all(id, offs ++ resets) |> elem(1)
      else
        state
      end

    put_in(state.sounding[id], MapSet.new())
  end

  defp panic_all(state) do
    state =
      Enum.reduce(targets(state), state, fn id, state ->
        state |> write_all(id, panic_messages(state, id)) |> elem(1)
      end)

    %{state | sounding: Map.new(@ids, &{&1, MapSet.new()})}
  end

  # Note-offs, CC 123 and the controller resets for `id`, per channel.
  defp panic_messages(state, id) do
    notes = Enum.group_by(state.sounding[id], &elem(&1, 1), &elem(&1, 2))

    Enum.flat_map(channels(state, id), fn channel ->
      Midi.all_notes_off(channel, Map.get(notes, channel, [])) ++ Midi.reset_controllers(channel)
    end)
  end

  defp channels(state, id),
    do:
      state.sounding[id]
      |> Enum.map(&elem(&1, 1))
      |> Enum.concat([state.channel])
      |> Enum.uniq()
      |> Enum.sort()

  defp toggle(state, id, false) do
    state
    |> silence_destination(id)
    |> Map.update!(:enabled, &Map.put(&1, id, false))
    |> sync_devices()
  end

  defp toggle(state, id, true) do
    state = state |> Map.update!(:enabled, &Map.put(&1, id, true)) |> sync_devices()
    if id == :bt, do: reconnect_bluetooth(state), else: state
  end

  # A destination that can't be reached has nothing sounding any more. An
  # output waiting to drain keeps its notes: they are released once it has.
  defp prune_sounding(state) do
    sounding =
      Map.new(state.sounding, fn {id, set} ->
        {id, if(sendable?(state, id) or resyncing?(state, id), do: set, else: MapSet.new())}
      end)

    %{state | sounding: sounding}
  end

  defp resyncing?(state, :port), do: state.vport.resync and listened?(state)

  defp resyncing?(state, id) when id in [:usb, :bt],
    do: Enum.any?(devices_for(state, id), &match?({:draining, _}, state.opened[&1.id]))

  defp resyncing?(_state, _id), do: false

  # ── Availability and the board's rows ─────────────────────────────────────

  defp available?(state, :fmutate), do: match?({:connected, _}, state.fmutate_status)
  defp available?(state, :port), do: state.vport.available
  defp available?(state, id), do: usable_devices(state, id) != []

  # Whether sending reaches anyone. The port exists (its row is available)
  # whether or not an app listens, but with no app connected every send would
  # answer :no_listener; while it drains nothing goes to it. FMutate
  # resynchronising takes no MIDI. A device takes MIDI once its output is open.
  defp sendable?(state, :port), do: listened?(state) and not state.vport.resync

  defp sendable?(state, :fmutate),
    do: available?(state, :fmutate) and not state.fmutate_resync

  defp sendable?(state, id), do: open_devices(state, id) != []

  defp listened?(%{vport: vport}),
    do: vport.available and not is_nil(vport.id) and vport.listeners > 0

  defp devices_for(state, id) do
    for {_, device} <- state.devices, destination(device) == id, do: device
  end

  # Devices not known to have failed to open (the row's "available").
  defp usable_devices(state, id) do
    for device <- devices_for(state, id), not match?({:failed, _}, state.opened[device.id]) do
      device.id
    end
  end

  # Devices whose output is open: the ones sent to.
  defp open_devices(state, id),
    do: for(device <- devices_for(state, id), state.opened[device.id] == :open, do: device.id)

  defp destination(%{type: :usb}), do: :usb
  defp destination(%{type: :bluetooth}), do: :bt

  defp destination_list(state) do
    for id <- @ids do
      %{
        id: id,
        name: name(state, id),
        detail: detail(state, id),
        enabled: state.enabled[id],
        available: available?(state, id)
      }
    end
  end

  defp name(state, :fmutate) do
    case state.fmutate_status do
      {:connected, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> "FMutate"
    end
  end

  defp name(_state, :port), do: "Humdinger port"
  defp name(_state, :usb), do: "USB MIDI out"
  defp name(_state, :bt), do: "Bluetooth MIDI"

  defp detail(state, :fmutate) do
    case state.fmutate_status do
      {:connected, info} -> Enum.join(["sibling app", "connected" | firmware(info)], " · ")
      :disconnected -> "sibling app · not connected"
      _ -> "sibling app · not paired"
    end
  end

  defp detail(%{vport: %{available: false}}, :port), do: "virtual MIDI · not on this phone"
  defp detail(%{vport: %{listeners: 0}}, :port), do: "virtual MIDI · any app can pick it"
  defp detail(%{vport: %{listeners: 1}}, :port), do: "virtual MIDI · 1 app listening"
  defp detail(%{vport: %{listeners: n}}, :port), do: "virtual MIDI · #{n} apps listening"

  defp detail(state, :usb) do
    case devices_for(state, :usb) do
      [] -> "nothing plugged in"
      devices -> Enum.map_join(devices, ", ", &device_label(state, &1))
    end
  end

  defp detail(state, :bt) do
    case devices_for(state, :bt) do
      [] -> bluetooth_detail(state)
      devices -> Enum.map_join(devices, ", ", &device_label(state, &1))
    end
  end

  defp bluetooth_detail(%{connecting: address}) when is_binary(address), do: "connecting…"
  defp bluetooth_detail(%{paired: %{name: name}}), do: "#{name} · not connected"
  defp bluetooth_detail(_state), do: "none paired"

  defp firmware(%{firmware: %{name: name}}) when is_binary(name), do: [name]
  defp firmware(%{firmware: name}) when is_binary(name) and name != "", do: [name]
  defp firmware(_), do: []

  defp device_label(state, device) do
    case state.opened[device.id] do
      {:failed, _} -> "#{device.name} · can't open"
      _ -> device.name
    end
  end

  defp bluetooth_view(state) do
    %{
      scanning: state.scanning,
      found: state.found,
      error: state.scan_error,
      connecting: state.connecting,
      paired: state.paired
    }
  end

  # Tells subscribers what changed since they were last told.
  defp changed(state) do
    destinations = destination_list(state)
    bluetooth = bluetooth_view(state)
    if destinations != state.shown, do: broadcast(state, {:output, :destinations, destinations})
    if bluetooth != state.shown_bluetooth, do: broadcast(state, {:output, :bluetooth, bluetooth})
    %{state | shown: destinations, shown_bluetooth: bluetooth}
  end

  defp broadcast(state, message), do: Enum.each(Map.keys(state.subscribers), &send(&1, message))

  # ── Devices and mob_midi events ──────────────────────────────────────────

  defp reconcile_devices(state, devices) do
    relevant =
      for device <- devices,
          device.type in [:usb, :bluetooth],
          not device.own,
          Device.writable?(device),
          into: %{},
          do: {device.id, device}

    removed = Map.keys(state.devices) -- Map.keys(relevant)
    for id <- removed, Map.has_key?(state.opened, id), do: state.device.close(id)
    bt_ids = Map.reject(state.bt_ids, fn {_addr, id} -> id in removed end)

    %{
      state
      | devices: relevant,
        opened: Map.drop(state.opened, removed),
        device_gens: Map.drop(state.device_gens, removed),
        bt_ids: bt_ids
    }
    |> sync_devices()
    |> prune_sounding()
  end

  # Opens outputs for the devices of enabled destinations; closes the rest.
  defp sync_devices(state) do
    wanted = for {id, device} <- state.devices, state.enabled[destination(device)], do: id

    opened =
      Enum.reduce(wanted, state.opened, fn id, opened ->
        if Map.has_key?(opened, id), do: opened, else: Map.put(opened, id, open(state, id))
      end)

    {keep, drop} = Map.split(opened, wanted)
    dropped = Map.keys(drop)
    for id <- dropped, do: state.device.close(id)
    %{state | opened: keep, device_gens: Map.drop(state.device_gens, dropped)}
  end

  defp open(state, id) do
    case state.device.open(id) do
      :ok -> :opening
      {:error, reason} -> {:failed, reason}
    end
  end

  defp handle_virtual_status(state, n) do
    before = listened?(state)
    # With no listener left the port has nothing to drain into.
    state = %{state | vport: %{state.vport | listeners: n, resync: state.vport.resync and n > 0}}

    # The first app to open the port (again) starts from silence.
    if not before and listened?(state),
      do: reset_port(state),
      else: prune_sounding(state)
  end

  defp handle_drained(%{vport: %{id: id} = vport} = state, id, gen) do
    stale? = if vport.resync, do: gen < vport.gen, else: gen <= vport.gen

    if stale? do
      state
    else
      drain_port(%{state | vport: %{vport | resync: false, gen: max(vport.gen, gen)}})
    end
  end

  defp handle_drained(state, id, gen) do
    case state.opened[id] do
      {:draining, expected} when gen >= expected ->
        drain_device(state, id, gen)

      :open ->
        if gen > Map.get(state.device_gens, id, 0),
          do: drain_device(state, id, gen),
          else: state

      _ ->
        state
    end
  end

  defp drain_port(state) do
    if listened?(state) do
      offs =
        for {_source, channel, note} <- state.sounding[:port],
            do: Midi.encode({:note_off, note}, channel)

      case write_all(state, :port, offs ++ Midi.panic()) do
        {:ok, state} -> put_in(state.sounding[:port], MapSet.new())
        {:refused, state} -> state
      end
    else
      prune_sounding(state)
    end
  end

  defp drain_device(state, device_id, gen) do
    prev = Map.get(state.device_gens, device_id, 0)

    state = %{
      state
      | opened: Map.put(state.opened, device_id, :open),
        device_gens: Map.put(state.device_gens, device_id, max(prev, gen))
    }

    case state.devices[device_id] do
      nil -> state
      device -> flush_drained_device(state, device_id, destination(device))
    end
  end

  defp flush_drained_device(state, device_id, dest) do
    offs =
      for {_source, channel, note} <- state.sounding[dest],
          do: Midi.encode({:note_off, note}, channel)

    case write_device_all(state, device_id, offs ++ Midi.panic()) do
      {:ok, state} -> clear_if_sole_device(state, device_id, dest)
      {:refused, state} -> state
    end
  end

  defp clear_if_sole_device(state, device_id, dest) do
    if open_devices(state, dest) == [device_id],
      do: put_in(state.sounding[dest], MapSet.new()),
      else: state
  end

  defp handle_open_output_error(state, _id, :closed), do: state

  defp handle_open_output_error(state, id, :own_device) do
    %{
      state
      | devices: Map.delete(state.devices, id),
        opened: Map.delete(state.opened, id),
        device_gens: Map.delete(state.device_gens, id)
    }
    |> prune_sounding()
  end

  defp handle_open_output_error(state, id, reason) do
    if Map.has_key?(state.opened, id) do
      Logger.warning("[output] MIDI device #{id} didn't open: #{inspect(reason)}")
      opened = Map.put(state.opened, id, {:failed, reason})
      prune_sounding(%{state | opened: opened})
    else
      state
    end
  end

  defp add_bluetooth_found(state, address, found) do
    if Enum.any?(state.found, &(&1.address == address)) do
      state
    else
      entry = %{
        address: address,
        name: Map.get(found, :name) || "",
        rssi: Map.get(found, :rssi) || 0
      }

      %{state | found: state.found ++ [entry]}
    end
  end

  # Android names a Bluetooth MIDI device after the name its stack cached,
  # which can be missing; the name the scan saw is the better one.
  defp bluetooth_connected(state, id, address) do
    paired = %{address: address, name: bluetooth_name(state, id, address)}
    state.device.remember(paired)
    if not Map.has_key?(state.devices, id), do: state.device.list()
    %{state | paired: paired, connecting: nil, bt_ids: Map.put(state.bt_ids, address, id)}
  end

  defp bluetooth_name(state, id, address) do
    scanned =
      Enum.find_value(state.found, &(&1.address == address and &1.name != "" and &1.name))

    existing = if match?(%{address: ^address}, state.paired), do: state.paired.name
    scanned || existing || device_name(state.devices[id]) || address
  end

  defp device_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp device_name(_), do: nil

  # Releases the Bluetooth notes and closes the device at `address` (which also
  # disconnects it in mob_midi).
  defp drop_bluetooth(state, address) do
    state = silence_destination(state, :bt)
    device_ids = for {id, %{type: :bluetooth, address: ^address}} <- state.devices, do: id
    ids = Enum.uniq(device_ids ++ List.wrap(state.bt_ids[address]))
    for id <- ids, do: state.device.close(id)

    %{
      state
      | devices: Map.drop(state.devices, ids),
        opened: Map.drop(state.opened, ids),
        device_gens: Map.drop(state.device_gens, ids),
        bt_ids: Map.delete(state.bt_ids, address)
    }
  end

  # Reconnects the remembered Bluetooth device when Bluetooth is on.
  defp reconnect_bluetooth(%{paired: %{address: address}, connecting: nil} = state) do
    if state.enabled.bt and devices_for(state, :bt) == [] and state.device.connect(address) == :ok,
      do: %{state | connecting: address},
      else: state
  end

  defp reconnect_bluetooth(state), do: state

  # ── FMutate and Settings ───────────────────────────────────────────────────

  defp module_opt(opts, key, default) do
    module = Keyword.get_lazy(opts, key, fn -> Application.get_env(:humdinger, key, default) end)
    if Code.ensure_loaded?(module), do: module
  end

  # FMutate may start after Output; retry until it's there.
  defp link_fmutate(%{fmutate: nil} = state), do: state

  defp link_fmutate(%{fmutate: fmutate} = state) do
    fmutate.subscribe(self())
    if state.fmutate_ref, do: Process.demonitor(state.fmutate_ref, [:flush])
    ref = if pid = GenServer.whereis(fmutate), do: Process.monitor(pid)
    prune_sounding(%{state | fmutate_status: fmutate.status(), fmutate_ref: ref})
  catch
    :exit, _ ->
      Process.send_after(self(), :link_fmutate, @fmutate_retry_ms)
      state
  end

  defp load_settings(%{settings: nil} = state), do: state

  defp load_settings(%{settings: settings} = state) do
    loaded = settings.load()
    destinations = Map.get(loaded, :destinations) || %{}

    %{
      state
      | channel: Midi.channel(Map.get(loaded, :channel) || 1),
        enabled: Map.merge(@default_enabled, Map.take(destinations, @ids))
    }
  end

  defp persist_enabled(%{settings: nil}, _id, _enabled), do: :ok

  defp persist_enabled(%{settings: settings}, id, enabled) do
    case settings.update(fn s -> Map.update!(s, :destinations, &Map.put(&1, id, enabled)) end) do
      {:ok, _} -> :ok
      other -> Logger.warning("[output] couldn't save #{id} = #{enabled}: #{inspect(other)}")
    end
  end
end
