# FMutate ↔ sibling apps: Erlang distribution contract (v1)

Sibling apps (Humdinger voice app, later a sampler, a Strudel app, a rig/agent host) drive
FMutate over Erlang distribution: on the same phone over loopback, or from another phone on the
same Wi-Fi after pairing. Everything a touch control can do, a remote message can do.

## 1. Pairing

Boards: `boards/Pair.dc.html` (FMutate side). The scanning side lives in each sibling app
(Humdinger: "Pair with FMutate").

### 1.1 What FMutate shows (I/O › Pair an app)

- A QR code and the same pairing as an 8-character code (`KQ7M-X2PD`, Crockford base32, no
  I/O/0/1 confusion), with **Copy code** and **Copy link**.
- QR / link payload:
  ```
  fmutate://pair?v=1&inst=a&node=fmutate_a&host=192.168.1.23&port=45123&fp=<sha256 of FMutate's TLS cert, base64url>&t=<pairing token, 128-bit, base64url>
  ```
- Token and code: **single use, expire after 5 minutes, 5 wrong attempts invalidates them**.
  "New code" makes a fresh pair.
- While this screen is open FMutate advertises itself over mDNS (`_fmutate._tcp`, TXT:
  `inst`, `node`, `port`, `fp`) and accepts pairing connections on the Wi-Fi interface.
  Closing the screen stops advertising and pairing.

### 1.2 What the sibling app does

- **Scan** the QR → has host, port, fingerprint, token.
- **Typed code** → browse mDNS for `_fmutate._tcp`, connect to each candidate's pairing port,
  prove knowledge of the code (SPAKE2 or similar PAKE so the code isn't sent in clear);
  the winning candidate supplies `fp`.
- **Same phone, Copy link → paste**: same as scan, host is `127.0.0.1`.
- Connects to FMutate's **pairing endpoint** (TLS, server cert pinned to `fp`), sends
  `{token | pake proof, app_id, app_name, device_name, signing_cert_sha256}`.

### 1.3 Approval

- FMutate checks the app is one of ours: `signing_cert_sha256` must match our release key
  (same phone: also enforced by the `app.fmutate.permission.PAIR` signature permission on
  the pairing activity/provider).
- FMutate shows "**Humdinger wants to connect** · on Pixel 7 · can play keys and read the
  screen" → Don't allow / Allow. Nothing connects without Allow.
- On Allow FMutate generates a **per-app cookie** (32 random bytes) and returns
  `{node, host, dist_port, cookie, client_cert}` over the pairing TLS channel. The sibling app
  stores it in app-private storage (Android Keystore-wrapped).

```elixir
# FMutate, on Allow
cookie = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) |> String.to_atom()
:erlang.set_cookie(:"humdinger@#{peer_host}", cookie)
Pairings.put(app_id, %{node: peer_node, cookie: cookie, cert_fp: client_cert_fp})

# Sibling app, before connecting
:erlang.set_cookie(:"fmutate_a@#{host}", cookie)
Node.connect(:"fmutate_a@#{host}")
```

### 1.4 After pairing

- The I/O screen lists each paired app with **Disconnect**: `Node.disconnect/1`, delete its
  cookie (`:erlang.set_cookie(node, random)`), forget its client cert.
- Reconnect: sibling app looks FMutate up by mDNS (Wi-Fi) or uses `127.0.0.1` (same phone),
  connects with its stored cookie. If FMutate isn't running on the same phone, the sibling app
  wakes it through a service guarded by the same signature permission.
- IP changes are fine (mDNS); a changed `fp` (FMutate reinstalled) requires pairing again.

## 2. Transport

- **No epmd.** Each app runs its own BEAM; a shared epmd would die with whichever app started it.
  Fixed distribution port per instance, `-start_epmd false`, and a small custom
  `-epmd_module` in sibling apps that returns the port from the pairing record.
- **Same phone:** distribution bound to `127.0.0.1`.
- **Other phone:** TLS distribution (`-proto_dist inet_tls`), FMutate's cert pinned by `fp`,
  client cert issued at pairing. Listen on the Wi-Fi interface only while at least one remote
  app is paired; never on mobile data.
- Node names: `fmutate_<instance>@<host>`, `humdinger@<host>`, etc.

## 3. Trust

Erlang distribution is **full trust**: a connected node can run any code in the other.
That is acceptable only because every peer is our own signed app, the player approved it, and
each has its own revocable cookie. **Anything else** (laptops, browsers, third-party apps)
must use a separate, restricted socket protocol carrying only the messages below
(`:erlang.binary_to_term(bin, [:safe])` or JSON over WebSocket) with its own pairing. Not in v1.

## 4. Messages

All messages: `{:fmutate, 1, instance_id, payload}` to the registered process
`{:global, {:fmutate, "a"}}` (or `:fmutate_instance` on that node).

### 4.1 Inputs (sibling → FMutate), casts

```elixir
{:key, n, :down, velocity}        # n 0..26, velocity 1..127
{:key, n, :up}
{:encoder, id, clicks}            # :select | :presets | :algorithm | :knob1..:knob4, clicks ±int
{:pot, :master, value}            # 0.0..1.0 absolute
{:button, id, :down | :up}        # 14 ids, see HANDOFF §2
{:midi, bytes}                    # raw MIDI into the firmware's MIDI in
```

Remote and touch input merge by HANDOFF §6 rule 7. Keys pressed remotely light **violet**
(`agent` token), and the menu button shows a violet ring + "driven by <app>" for 2 s after the
last remote input.

### 4.2 Subscriptions (FMutate → sibling)

```elixir
{:subscribe, pid, topics}         # topics ⊆ [:screen, :leds, :midi_out, :status, :layout]
{:unsubscribe, pid}
```

Events:

```elixir
{:screen, seq, frame}             # 240×240, emulator's pixel format (assume RGB565, 115 200 B);
                                  # changed frames only, ≤ 30 fps per subscriber, ≤ 10 fps over Wi-Fi
{:leds, keys_bitmap, buttons_map} # 27-bit integer; %{id => :off | :on | :blink}
{:midi_out, bytes}
{:status, status}                 # :booting | :running | :crashed | :safe_mode | {:slow, clock_pct}
{:layout_changed, layout_id}
```

Audio is not sent over distribution.

### 4.3 Calls (sibling → FMutate)

```elixir
{:list_layouts, firmware_id}             # → {:ok, [%{id, name, made_by}]}
{:get_layout, layout_id}                 # → {:ok, json}
{:put_layout, json, opts}                # → {:ok, layout_id} | {:error, reasons}; validated against layout.schema.json
                                         #   opts: [activate: bool, trial: bool]
{:list_firmware}                         # → {:ok, [%{id, name, version, status}]}
{:switch_firmware, firmware_id}          # → :ok | {:error, :not_installed | :quarantined}
{:install_firmware, fwsc_binary, meta}   # → {:ok, firmware_id}
```

`put_layout` with `activate`, `switch_firmware` and `install_firmware` ask the player on the
FMutate side first (sheet naming the app and the change; approve with the device screen lock).
`trial: true` reverts automatically if the player leaves without keeping it.

## 5. Instances

All calls name the instance. v1 rejects anything but `"a"` with `{:error, :no_such_instance}`.
A later second emulator adds `fmutate_b` with its own port, QR and pairings.
