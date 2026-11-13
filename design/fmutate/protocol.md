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
  `inst`, `node`, `port`, `fp`, and `v`, `dport`, `fw`, `dev`, see §1.5) and accepts pairing
  connections on the Wi-Fi interface. Closing the screen stops pairing; advertising goes on
  (without `port`) while a sibling on another phone is paired, so it can follow FMutate to a new
  address.

### 1.2 What the sibling app does

- **Scan** the QR → has host, port, fingerprint, token.
- **Typed code** → browse mDNS for `_fmutate._tcp`, connect to each candidate's pairing port,
  prove knowledge of the code with SRP-6a (§1.5) so the code isn't sent in clear; the winning
  candidate's certificate is the `fp` (the SRP proofs cover it).
- **Same phone, Copy link → paste**: same as scan, host is `127.0.0.1`.
- Connects to FMutate's **pairing endpoint** (TLS 1.3, server cert pinned to `fp`), sends
  `{token | SRP proof, app_id, app_name, device_name, node, client_cert}` (§1.5).

### 1.3 Approval

- FMutate checks what it can of the app (§3: on the same phone the connection's owner and its
  signing certificate; from another phone nothing about the app can be verified, only that the
  sibling holds the current code or QR). A `signing_cert_sha256` sent by the sibling is a claim
  and proves nothing; Humdinger sends `null`.
- FMutate shows "**Humdinger wants to connect** · on Pixel 7 · can play keys and read the
  screen" → Don't allow / Allow. Nothing connects without Allow.
- On Allow FMutate generates a **per-app cookie** (32 random bytes), pins the client
  certificate the sibling made for this pairing, and returns `{node, dist_host, dist_port,
  dist_proto, cookie}` over the pairing TLS channel. The sibling app stores it in app-private
  storage (Android Keystore-wrapped).

```elixir
# FMutate, on Allow
cookie = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) |> String.to_atom()
:erlang.set_cookie(:"#{request.node}", cookie)   # the node name the sibling declared
Pairings.put(request.node, %{app_id: app_id, cookie: cookie, cert_fp: client_cert_fp})

# Sibling app, before connecting (hidden connection, see §1.5 "After pairing")
:erlang.set_cookie(:"fmutate_a@#{host}", cookie)
:net_kernel.hidden_connect_node(:"fmutate_a@#{host}")
```

### 1.4 After pairing

- The I/O screen lists each paired app with **Disconnect**: `Node.disconnect/1`, delete its
  cookie (`:erlang.set_cookie(node, random)`), forget its client cert.
- Reconnect: sibling app looks FMutate up by mDNS (Wi-Fi) or uses `127.0.0.1` (same phone),
  connects with its stored cookie. If FMutate isn't running on the same phone, the sibling app
  wakes it through a service guarded by the same signature permission.
- IP changes are fine (mDNS); a changed `fp` (FMutate reinstalled) requires pairing again.

### 1.5 Pairing wire protocol (implemented)

Implemented on the sibling side by Humdinger (`Humdinger.FMutate.Pairing.Client`) and on the
FMutate side by a reference server in the Humdinger repo (`Humdinger.FMutate.Reference.*`,
which FMutate can copy; the end-to-end tests run it in a separate BEAM). Version 1.

**Certificates.** FMutate has one long-lived self-signed certificate (ECDSA P-256, signed with
SHA-256). `fp` is the SHA-256 of its DER bytes (base64url without padding in the link and
TXT). It serves the pairing endpoint and TLS distribution. The sibling makes its own key pair
and self-signed certificate at pairing and sends the certificate; FMutate pins its SHA-256 for
TLS distribution. Private keys never leave the app that made them (so FMutate does not issue
the client certificate, as §1.3 first had it).

**Connection.** TCP to the pairing port, TLS 1.3 only. FMutate presents its certificate and
asks for none. With a link the sibling pins `fp`: the handshake fails and nothing is sent
unless the certificate matches. With a typed code the sibling accepts the certificate, notes
its SHA-256, and SRP proves it.

**Framing.** Each message is a 4-byte big-endian length, then a UTF-8 JSON object of at most
16 KiB with a `"type"`. Binary values are base64url without padding; SRP's `A` and `B` are
big-endian unsigned integers. Each side gives up on the other after 30 s per step (Humdinger:
15 s), except while FMutate asks the player (FMutate: 120 s; Humdinger: 180 s).

| # | Direction | Message |
|---|---|---|
| 1 | sibling → FMutate | `{"type":"hello","v":1,"inst":"a","auth":"token","token":T}` or `{"type":"hello","v":1,"inst":"a","auth":"srp","A":A}` |
| 2a | FMutate → sibling | token: `{"type":"welcome"}` |
| 2b | FMutate → sibling | SRP: `{"type":"challenge","salt":s,"B":B}`; sibling → `{"type":"proof","M1":M1}`; FMutate → `{"type":"welcome","M2":M2}` |
| 3 | sibling → FMutate | `{"type":"request","app_id":"com.genericjam.humdinger","app_name":"Humdinger","device_name":"moto g power (2021)","node":"humdinger_k3x9pq2m@127.0.0.1","client_cert":DER,"signing_cert_sha256":null}` |
| 4 | FMutate → sibling | `{"type":"pending"}` (the Allow sheet is up) |
| 5 | FMutate → sibling | `{"type":"granted","inst":"a","name":"FMutate A","device":"Pixel 7","firmware":"X0X","node":"fmutate_a@192.168.1.23","dist_host":"192.168.1.23","dist_port":45124,"dist_proto":"inet_tls","cookie":C}` |

Then FMutate closes. Any step can instead get `{"type":"error","reason":R}` and a close:

| `reason` | When |
|---|---|
| `unsupported_version` | `v` isn't 1 |
| `no_such_instance` | `inst` isn't this FMutate's (§5) |
| `expired` | the secret is older than 5 minutes or already used |
| `invalid_token` | wrong token (counts as a failed attempt) |
| `wrong_code` | wrong SRP proof (counts); carries `"attempts_left":n` |
| `too_many_attempts` | 5 failed attempts: the code and token are dead until New code |
| `bad_message` | malformed or unexpected message |
| `denied` | the player tapped Don't allow |
| `timeout` | the player didn't answer |

**SRP-6a** (`Humdinger.FMutate.Srp`; OTP `:crypto` computes it with version `'6a'`):

- group: RFC 5054 2048-bit `N`, `g = 2`; `I = "fmutate"`; `P` = the code's 8 characters,
  uppercase, no dash (Crockford: `I`/`L` → `1`, `O` → `0`);
- `x = SHA-256(salt ‖ SHA-256(I ‖ ":" ‖ P))`, `v = g^x mod N`; FMutate makes a fresh 16-byte
  salt and `v` per connection (it knows the code);
- `k = SHA-1(N ‖ PAD(g))`, `u = SHA-1(PAD(A) ‖ PAD(B))` (RFC 5054); `a`, `b` are 32 random
  bytes; `A = g^a`, `B = k·v + g^b` (mod `N`); either side aborts if the other's value is 0
  mod `N` or `u = 0`;
- `K = SHA-256(PAD(S))`, `PAD` = left-pad with zeros to 256 bytes;
- `M1 = HMAC-SHA-256(K, "fmutate-pair/1 client" ‖ fp ‖ cb ‖ PAD(A) ‖ PAD(B))`,
  `M2 = HMAC-SHA-256(K, "fmutate-pair/1 server" ‖ fp ‖ cb ‖ PAD(A) ‖ PAD(B) ‖ M1)`, with `fp`
  the 32-byte SHA-256 of the certificate *as each side sees it* and `cb` the TLS 1.3 exporter
  (RFC 9266 `tls-exporter`: label `EXPORTER-Channel-Binding`, empty context, 32 bytes).

A relay that terminates TLS itself presents another certificate and has another TLS
session, so its `M1`/`M2` can't match; it learns nothing it could guess the code from offline
and gets one online guess per attempt. The request and grant then travel in the TLS session
the proofs are bound to.

**Secret rules (FMutate).** One secret per Pair screen: the code (40 bits), the token (128
bits), an expiry 5 minutes out, an attempt count. Every failed authentication (wrong token,
wrong `M1`) counts; the 5th kills code and token until New code. A successful authentication
uses the secret up, whatever the player then decides. Compare tokens and proofs in constant
time. A sibling with a typed code tries each FMutate advertising a pairing `port` in turn, so
another FMutate pairing at the same moment counts one wrong attempt.

**Grant.** On Allow: a cookie of 32 random bytes (base64url), set with
`:erlang.set_cookie(:"<request.node>", cookie)` (the atom is made only after Allow); the
client certificate's SHA-256 pinned for TLS distribution; `dist_host` `127.0.0.1` when the
pairing connection came from loopback, else FMutate's Wi-Fi address; `dist_proto`
`inet_tcp` (loopback listener) or `inet_tls`.

**Node names.** The sibling declares its node name in `request.node` and keeps it for the
life of the pairing; FMutate sets the cookie for exactly that name. Humdinger uses
`humdinger_<8 base32>@127.0.0.1` (unique per pairing so two phones don't collide; the host
part is only a label, nothing resolves it), or its development node name in a dev build.
`granted.node` is FMutate's full node name; the sibling connects to exactly that name.

**mDNS.** Service `_fmutate._tcp.local`, instance `FMutate A` (DNS-SD may add ` (2)`), SRV to
FMutate's host, TXT `v=1`, `inst`, `node` (full node name), `fp`, `port` (pairing port, only
while pairing is open), `dport` (distribution port), `fw` (running firmware's name), `dev`
(device name). Siblings browse with one-shot legacy unicast queries (RFC 6762 §5.1: from a
port other than 5353), which responders answer by unicast to the querier, so a sibling never
has to receive multicast (no `WifiManager.MulticastLock`). On Android FMutate advertises with
`NsdManager`; `Humdinger.FMutate.Reference.Responder` is the same thing in Erlang for tests and
hosts.

**After pairing (distribution).**

- The sibling's node is hidden and has no listener (`dist_listen: false`), auto-connect off,
  and a port mapper module (`Humdinger.FMutate.Epmd`) that answers FMutate's node with
  `{dist_host, dist_port}`: no epmd on either side, nothing to connect to on the sibling.
- It connects with `:net_kernel.hidden_connect_node/1`, so the connection is hidden on both
  sides and `global` doesn't mesh the sibling with FMutate's other peers. `{:global, {:fmutate,
  "a"}}` isn't visible over a hidden connection: FMutate must register `:fmutate_instance`
  locally, and siblings send there.
- `inet_tls`: FMutate runs stock `-proto_dist inet_tls` with an `-ssl_dist_optfile` (TLS 1.3,
  its certificate, `verify_peer` + `fail_if_no_peer_cert`, a `verify_fun` accepting only
  pinned client certificates: `Reference.Pairings.write_ssl_dist_optfile/2`). Humdinger can't
  pick its carrier that way (on Android distribution starts at runtime and `-proto_dist` is
  read at boot), so its `inet_tcp` node goes through a loopback tunnel
  (`Humdinger.FMutate.Tunnel`): TLS 1.3 to FMutate with `fp` pinned and the pairing's client
  certificate, accepting only a connection from its own BEAM, reframing the distribution
  handshake (`inet_tcp_dist` frames it with 2-byte lengths, `inet_tls_dist` with 4) and then
  passing bytes through. FMutate needs nothing special for it.
- Reconnect: 1, 2, 5, 10, then every 30 s. For FMutate on another phone the sibling browses
  mDNS from the second failure and adopts a candidate with the same `fp` and `inst` (new
  host, node name, `dport`).
- Forgetting: the sibling calls `{:unpair, node}` (§4), drops the connection, replaces the
  cookie for FMutate's node and deletes its record. FMutate answers `:ok` and then revokes as
  for Disconnect.

## 2. Transport

- **No epmd.** Each app runs its own BEAM; a shared epmd would die with whichever app started it.
  Fixed distribution port per instance, `-start_epmd false`, and a small custom
  `-epmd_module` in sibling apps that returns the port from the pairing record (FMutate's:
  `Humdinger.FMutate.Reference.Epmd` with `-kernel erl_epmd_node_listen_port <port>`).
- **Same phone:** distribution bound to `127.0.0.1`.
- **Other phone:** TLS distribution (`-proto_dist inet_tls`), FMutate's cert pinned by `fp`,
  the sibling's client cert pinned at pairing (§1.5). Listen on the Wi-Fi interface only while
  at least one remote app is paired; never on mobile data.
- Siblings connect out only: hidden node, no listener (§1.5).
- Node names: `fmutate_<instance>@<host>`; siblings declare theirs at pairing (§1.5).

## 3. Trust

Erlang distribution is **full trust**, both ways: a connected node can run any code in the
other (FMutate can `:rpc.call` into a connected sibling as much as the reverse). What actually
stands behind a connection:

- **FMutate to the sibling:** its certificate `fp`, taken from the QR code or the pasted link
  (out of band), or proven with the typed code through SRP (§1.5).
- **The sibling to FMutate:** holding the current secret (QR token or code: single use, 5
  minutes, 5 attempts), then the **player's Allow**. After pairing: the per-app cookie, and for
  TLS distribution the pinned client certificate. Disconnect revokes both.
- **App identity is not verified across devices.** `app_id`, `app_name`, `device_name` and any
  `signing_cert_sha256` in the request are what the sibling says; a client on another phone
  can claim anything. Humdinger sends `signing_cert_sha256: null` for that reason. The Allow
  sheet should present a remote request as "says it is Humdinger on …".
- **On the same phone** FMutate can verify the app: the pairing connection comes from
  loopback, `ConnectivityManager.getConnectionOwnerUid` (API 29+) gives the connecting UID,
  and `PackageManager` gives that package's signing certificate to compare with our release
  key. The `app.fmutate.permission.PAIR` signature permission covers the activity/service
  paths (waking FMutate), not a TCP socket.
- **Loopback distribution** (`inet_tcp`) is unencrypted; other apps can connect to FMutate's
  loopback port but can't pass the cookie challenge (the cookie never crosses the wire), and
  can't observe loopback traffic without root.
- **Secrets at rest:** Humdinger keeps the cookie and its TLS key in Android Keystore-backed
  storage (`mob_secure_store`). FMutate should keep its pairings, cookies and certificate key
  the same way.

**Anything else** (laptops, browsers, third-party apps) must use a separate, restricted
socket protocol carrying only the messages below (`:erlang.binary_to_term(bin, [:safe])` or
JSON over WebSocket) with its own pairing. Not in v1.

## 4. Messages

All messages: `{:fmutate, 1, instance_id, payload}` to the registered process
`{:global, {:fmutate, "a"}}` (or `:fmutate_instance` on that node; siblings on a hidden
connection, which is what §1.5 uses, can only reach `:fmutate_instance`).

Delivery (as implemented): inputs and `subscribe`/`unsubscribe` are `GenServer.cast/2`, calls
are `GenServer.call/3`, and events go to the subscribed pid as plain messages
`{:fmutate, 1, instance_id, event}`. FMutate sends the current `{:status, status}` when a pid
subscribes to `:status`. One call added for siblings: `{:unpair, node}` → `:ok`, after which
FMutate revokes that node's pairing (§1.5).

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
