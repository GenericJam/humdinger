defmodule Humdinger.PairScreen do
  @moduledoc """
  Pair with FMutate (board `11-pair`), opened from the Output screen.

  Three ways in, all through `Humdinger.FMutate.Pairing` (the module in
  `config :humdinger, :pairing`, default `Humdinger.FMutate.Pairing`):

    * **Scan.** Tapping the viewfinder asks for `:camera`
      (`Mob.Permissions`) and opens `MobScanner.scan(socket, formats:
      [:qr])`, a full-screen scanner; the scanned `fmutate://pair?…` link goes
      through `parse_link/1` to `pair/2`.
    * **Type.** Once `normalize_code/1` accepts the 8 characters typed, the
      field shows them as `KQ7M-X2PD`, turns lime and pairing starts by code
      (for the FMutate tapped in FOUND NEARBY, if any). Until then it keeps
      the keys as typed (Android's field would drop keys in flight).
    * **Paste.** Reads the clipboard (`Mob.Clipboard`, or the module in
      `config :humdinger, :clipboard`): a code fills the field, a whole link
      pairs at once. A link typed into the field works too.

  FOUND NEARBY lists `discover/1`'s candidates (started on mount):
  "FMutate A · X0X" over "Pixel 7 · Wi-Fi · code matches" once FMutate took
  the code (`:matched`). The status card at the bottom has Mimi and the
  state: a hint, "Waiting for Allow…" with Cancel (`Pairing.cancel/0`, then
  discovery again), "Paired with FMutate A" (then back to Output after
  1.5 s), or the failure in plain words with "Try again". Leaving the
  screen (`terminate/2`) cancels discovery and any pairing in progress.
  """

  use Mob.Screen

  import Humdinger.Controls

  alias Humdinger.Style
  alias Humdinger.Views.QrFrame

  # The viewfinder canvas: the board's box (390 − 2 × 20 wide), centred in
  # the content width.
  @scanner_w 350
  @scanner_h 300
  @close_after_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    :ok = pairing().discover(self())

    {:ok,
     Mob.Socket.assign(socket,
       code: "",
       code_valid: false,
       attempted: nil,
       candidates: [],
       matched: nil,
       selected: nil,
       offer: nil,
       status: :idle,
       camera: :unknown,
       scanner: :idle
     )}
  end

  @impl true
  def terminate(_reason, _socket) do
    pairing().cancel()
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    paste = {self(), :paste}
    change = {self(), :code}
    border = if assigns.code_valid, do: Style.fm(), else: Style.line()
    border_w = if assigns.code_valid, do: 2, else: 1

    page(
      [
        header({self(), :back}, "Pair with FMutate", nil, nil, size: 24),
        ~MOB"""
        <Scroll weight={1} show_indicator={false}>
          <Column fill_width={true} gap={14}>
            <Text
              text="In FMutate, open I/O › Pair an app, then scan its code."
              text_size={13}
              text_color={Style.text_2()}
            />
            {scanner(@scanner)}
            <Column fill_width={true} gap={8}>
              {heading("OR ENTER THE CODE")}
              <Row fill_width={true} gap={8} align={:center}>
                <TextField
                  id="code"
                  weight={1}
                  value={@code}
                  placeholder="XXXX-XXXX"
                  on_change={change}
                  on_submit={change}
                  caret="end"
                  font={:mono_bold}
                  text_size={22}
                  letter_spacing={1.3}
                  text_color={Style.text()}
                  placeholder_color={Style.faint()}
                  background={Style.surface()}
                  border_color={border}
                  border_width={border_w}
                  corner_radius={14}
                  padding={14}
                  underline={false}
                />
                {button("Paste", paste, kind: :raised, height: 52, radius: 14, padding: 14, text_size: 14)}
              </Row>
            </Column>
            <Column fill_width={true} gap={6}>
              {heading("FOUND NEARBY")}
              {nearby(shown_candidates(assigns), assigns)}
            </Column>
          </Column>
        </Scroll>
        """,
        status_card(assigns.status, assigns.matched)
      ],
      width: nil,
      gap: 14
    )
  end

  defp scanner(state) do
    scan = {self(), :scan}
    w = @scanner_w
    h = @scanner_h
    ops = scanner_ops(state, w, h)

    chip =
      case state do
        :asking -> "Allow the camera…"
        :scanning -> "Scanning…"
        :found -> "Got it"
        _ -> "Point at the code"
      end

    ~MOB"""
    <Box
      id="scanner"
      fill_width={true}
      height={h}
      corner_radius={18}
      background={0xFF241F2A}
      align="center"
      on_tap={scan}
      on_press_out={held()}
    >
      <Box width={w} height={h} align="bottom_leading">
        <Canvas width={w} height={h} draw={ops} />
        <Box fill_width={false} padding={12}>
          <Box
            fill_width={false}
            corner_radius={10}
            background={Style.bg()}
            padding_left={10}
            padding_right={10}
            padding_top={6}
            padding_bottom={6}
          >
            <Text text={chip} font={:semibold} text_size={12} text_color={Style.text()} />
          </Box>
        </Box>
      </Box>
    </Box>
    """
  end

  @doc """
  The viewfinder's ops in a `w` × `h` canvas: a camera glyph in the target
  square under `Humdinger.Views.QrFrame`'s brackets (`:found` once a code
  was read).
  """
  def scanner_ops(state, w, h) do
    {left, top, side} = QrFrame.square(w, h)
    cx = left + side / 2
    cy = top + side / 2
    ink = Style.alpha(Style.muted(), 0.55)

    camera = [
      Mob.Canvas.rect(cx - 28, cy - 17, 56, 38, color: ink, width: 2, radius: 8),
      Mob.Canvas.rect(cx - 10, cy - 23, 20, 6, color: ink, fill: true, radius: 2),
      Mob.Canvas.circle(cx, cy + 2, 11, color: ink, width: 2)
    ]

    frame = if state == :found, do: :found, else: :scanning
    camera ++ QrFrame.ops(%{state: frame}, w, h)
  end

  defp nearby([], _assigns) do
    ~MOB"""
    <Box
      fill_width={true}
      background={Style.surface()}
      corner_radius={14}
      padding_left={12}
      padding_right={12}
      padding_top={12}
      padding_bottom={12}
    >
      <Text
        text="Looking for FMutate on this Wi-Fi…"
        font={:mono}
        text_size={11}
        text_color={Style.muted()}
      />
    </Box>
    """
  end

  defp nearby(candidates, assigns) do
    Enum.map(candidates, &candidate_row(&1, assigns))
  end

  defp candidate_row(candidate, assigns) do
    pairable = candidate.port != nil
    tap = if pairable, do: {self(), {:candidate, candidate.inst}}
    selected = assigns.selected == candidate.inst
    dot = if pairable, do: Style.fm(), else: Style.faint()
    border = if selected, do: Style.fm(), else: Style.surface()

    ~MOB"""
    <Box
      id={candidate.inst}
      fill_width={true}
      background={Style.surface()}
      border_color={border}
      border_width={1}
      corner_radius={14}
      padding_left={12}
      padding_right={12}
      padding_top={10}
      padding_bottom={10}
      on_tap={tap}
      on_press_out={if(tap, do: held())}
    >
      <Row fill_width={true} gap={12} align={:center}>
        <Box width={10} height={10} corner_radius={5} background={dot} />
        <Column weight={1}>
          <Text
            text={candidate_title(candidate)}
            font={:bold}
            text_size={14}
            text_color={Style.text()}
          />
          <Text
            text={candidate_detail(candidate, assigns.matched)}
            font={:mono}
            text_size={11}
            text_color={Style.muted()}
          />
        </Column>
      </Row>
    </Box>
    """
  end

  @doc "\"FMutate A · X0X\" (with the firmware when FMutate gives it)."
  def candidate_title(%{name: name} = candidate) do
    case Map.get(candidate, :firmware) do
      firmware when is_binary(firmware) and firmware != "" -> "#{name} · #{firmware}"
      _ -> name
    end
  end

  @doc "\"Pixel 7 · Wi-Fi · code matches\": device, how it's reached, where pairing stands."
  def candidate_detail(candidate, matched) do
    device = Map.get(candidate, :device)
    via = if candidate.host == "127.0.0.1", do: "this phone", else: "Wi-Fi"

    state =
      cond do
        matched && matched.inst == candidate.inst -> "code matches"
        candidate.port == nil -> "not showing its code"
        true -> "showing its code"
      end

    [device, via, state]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  # The FMutate pairing by link may not be in the mDNS list: show it anyway.
  defp shown_candidates(%{candidates: candidates, matched: nil}), do: candidates

  defp shown_candidates(%{candidates: candidates, matched: matched}) do
    if Enum.any?(candidates, &(&1.inst == matched.inst)),
      do: candidates,
      else: candidates ++ [matched]
  end

  defp status_card(status, matched) do
    {mimi_state, title, body, action} = status_view(status, matched)

    action_button =
      case action do
        :cancel -> status_action("Cancel", Style.danger_text(), :cancel)
        :retry -> status_action("Try again", Style.fm(), :retry)
        nil -> nil
      end

    ~MOB"""
    <Box id="status" fill_width={true} background={Style.surface()} corner_radius={18} padding={14}>
      <Row fill_width={true} gap={12} align={:center}>
        {mimi(54, 48, 54, Map.put(mimi_state, :note, 69))}
        <Column weight={1} gap={2}>
          <Text text={title} font={:bold} text_size={14} text_color={Style.text()} />
          <Text text={body} text_size={12} text_color={Style.muted()} />
        </Column>
        {action_button}
      </Row>
    </Box>
    """
  end

  defp status_action(label, color, tag),
    do: button(label, {self(), tag}, kind: :header, background: nil, color: color)

  @doc """
  The status card for a pairing state: `{mimi_state, title, body, action}`,
  `action` `:cancel`, `:retry` or nil.
  """
  def status_view(:idle, _matched),
    do:
      {%{mood: :idle}, "Scan or type FMutate's code",
       "FMutate shows both under I/O › Pair an app.", nil}

  def status_view({:notice, title, body}, _matched), do: {%{mood: :idle}, title, body, nil}

  def status_view(:pairing, nil),
    do: {%{mood: :listening}, "Finding FMutate…", "Checking the code over Wi-Fi.", :cancel}

  def status_view(:pairing, matched),
    do:
      {%{mood: :listening}, "Code matches #{matched.name}",
       "Asking #{matched.name} to let Humdinger in.", :cancel}

  def status_view(:waiting, _matched),
    do:
      {%{mood: :listening}, "Waiting for Allow…",
       "Tap Allow on the other phone. Encrypted link, checked against the code.", :cancel}

  def status_view({:paired, info}, _matched),
    do: {%{mood: :aria}, "Paired with #{info.name}", "Humdinger sends it MIDI from now on.", nil}

  def status_view({:failed, reason}, _matched) do
    {title, body} = failure_text(reason)
    {%{mood: :idle, look: {0, 1}}, title, body, :retry}
  end

  @doc "A pairing failure in plain words: `{title, body}`."
  def failure_text({:wrong_code, 1}),
    do: {"Wrong code", "That isn't the code FMutate shows. 1 try left."}

  def failure_text({:wrong_code, left}) when is_integer(left),
    do: {"Wrong code", "That isn't the code FMutate shows. #{left} tries left."}

  def failure_text(:too_many_attempts),
    do: {"Too many tries", "FMutate stopped this code. Open Pair an app again for a new one."}

  def failure_text(:expired),
    do:
      {"The code ran out",
       "Codes last a few minutes. Open Pair an app in FMutate for a fresh one."}

  def failure_text(:invalid_token),
    do: {"That code was already used", "Each code works once. Show a new one in FMutate."}

  def failure_text(:denied),
    do: {"FMutate said no", "Someone tapped Don't allow on the other phone."}

  def failure_text(:unreachable),
    do:
      {"Can't reach FMutate",
       "Check both phones are on the same Wi-Fi and FMutate's Pair screen is open."}

  def failure_text(:fingerprint_mismatch),
    do:
      {"Not the FMutate you scanned",
       "Its identity didn't match the code, so Humdinger stopped. Scan the code again."}

  def failure_text(:not_found),
    do:
      {"No FMutate found", "Open I/O › Pair an app in FMutate, on the same Wi-Fi as this phone."}

  def failure_text(:not_pairing),
    do: {"FMutate isn't pairing", "Open I/O › Pair an app in FMutate first."}

  def failure_text(:busy),
    do: {"FMutate is busy", "It's pairing with another app. Try again in a moment."}

  def failure_text(:timeout), do: {"No answer", "FMutate didn't answer in time."}

  def failure_text(:no_such_instance),
    do: {"That FMutate is gone", "It closed or changed. Scan its code again."}

  def failure_text(:unsupported_version),
    do: {"Update FMutate", "This FMutate pairs a different way. Update both apps."}

  def failure_text({:store, _}),
    do: {"Couldn't save the pairing", "The phone's secure storage refused it. Try again."}

  def failure_text(:invalid_code),
    do: {"Not a code", "FMutate's codes are 8 letters and digits, like KQ7M-X2PD."}

  def failure_text(:not_a_link),
    do: {"That's not FMutate's code", "Scan the QR code on FMutate's Pair an app screen."}

  def failure_text(_other),
    do: {"Pairing didn't work", "Something went wrong talking to FMutate. Try again."}

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:change, :code, text}, socket), do: {:noreply, entered(socket, text, :typed)}

  def handle_info({:submit, :code}, socket) do
    a = socket.assigns
    {:noreply, if(a.code_valid, do: pair(socket, code_offer(a.code, a)), else: socket)}
  end

  def handle_info({:tap, :paste}, socket) do
    case clipboard().get(socket) do
      {:clipboard, :ok, text} ->
        {:noreply, entered(socket, text, :pasted)}

      {:clipboard, :empty} ->
        {:noreply,
         notice(socket, "Nothing to paste", "Copy the code or the link in FMutate first.")}
    end
  end

  def handle_info({:tap, {:candidate, inst}}, socket) do
    a = socket.assigns
    candidate = Enum.find(a.candidates, &(&1.inst == inst))

    cond do
      candidate == nil ->
        {:noreply, socket}

      a.code_valid ->
        socket = Mob.Socket.assign(socket, :selected, inst)
        {:noreply, pair(socket, %{code: a.code, candidate: candidate})}

      true ->
        {:noreply,
         socket
         |> Mob.Socket.assign(:selected, inst)
         |> notice("Type #{candidate.name}'s code", "It's under the QR code in FMutate.")}
    end
  end

  def handle_info({:tap, :scan}, socket) do
    case socket.assigns.camera do
      :granted ->
        {:noreply, open_scanner(socket)}

      _ ->
        if device_calls?(), do: Mob.Permissions.request(socket, :camera)
        {:noreply, Mob.Socket.assign(socket, :scanner, :asking)}
    end
  end

  def handle_info({:permission, :camera, :granted}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:camera, :granted) |> open_scanner()}

  def handle_info({:permission, :camera, _denied}, socket),
    do: {:noreply, camera_off(Mob.Socket.assign(socket, :camera, :denied))}

  def handle_info({:scan, :result, %{value: value}}, socket) do
    {:noreply, socket |> Mob.Socket.assign(:scanner, :found) |> link(value)}
  end

  def handle_info({:scan, :permission_denied}, socket), do: {:noreply, camera_off(socket)}

  def handle_info({:scan, :not_available}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:scanner, :idle)
     |> notice("The camera didn't open", "Type the code instead, or paste FMutate's link.")}
  end

  def handle_info({:scan, _cancelled}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :scanner, :idle)}

  def handle_info({:fmutate_pair, :found, candidates}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :candidates, candidates)}

  def handle_info({:fmutate_pair, :matched, candidate}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :matched, candidate)}

  def handle_info({:fmutate_pair, :waiting}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :status, :waiting)}

  def handle_info({:fmutate_pair, :paired, info}, socket) do
    Process.send_after(self(), :paired_close, @close_after_ms)
    {:noreply, Mob.Socket.assign(socket, status: {:paired, info}, scanner: :found)}
  end

  def handle_info({:fmutate_pair, :failed, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, status: {:failed, reason}, scanner: :idle)}

  def handle_info(:paired_close, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :cancel}, socket) do
    :ok = pairing().cancel()
    :ok = pairing().discover(self())
    {:noreply, reset(socket)}
  end

  def handle_info({:tap, :retry}, socket) do
    case {socket.assigns.status, socket.assigns.offer} do
      {{:failed, reason}, offer} when offer != nil ->
        if fresh_code_needed?(reason),
          do: {:noreply, socket |> reset() |> Mob.Socket.assign(code: "", code_valid: false)},
          else: {:noreply, pair(socket, offer)}

      _ ->
        {:noreply, socket |> reset() |> Mob.Socket.assign(code: "", code_valid: false)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Pairing ────────────────────────────────────────────────────────────────

  # Typed, pasted or submitted text: a link pairs at once, a code pairs once
  # it is complete (and new). While a code is being typed the field keeps the
  # keystrokes as they are: Android's field adopts any value the screen
  # changes, and during a burst of typing that drops the keys still in flight
  # (MobTextSync). It takes the `XXXX-XXXX` form once the code is whole, and
  # pasted text is formatted at once.
  defp entered(socket, text, how) do
    if link?(text) do
      socket |> Mob.Socket.assign(code: "", code_valid: false) |> link(text)
    else
      {formatted, valid} = format_code(text)
      code = if valid or how == :pasted, do: formatted, else: text
      a = socket.assigns
      socket = Mob.Socket.assign(socket, code: code, code_valid: valid)

      if valid and code != a.attempted,
        do: pair(socket, code_offer(code, a)),
        else: socket
    end
  end

  defp link?(text),
    do: text |> String.trim() |> String.downcase() |> String.starts_with?("fmutate:")

  defp link(socket, text) do
    case pairing().parse_link(text) do
      {:ok, offer} -> pair(socket, offer)
      {:error, _} -> Mob.Socket.assign(socket, status: {:failed, :not_a_link}, scanner: :idle)
    end
  end

  defp code_offer(code, assigns) do
    case Enum.find(assigns.candidates, &(&1.inst == assigns.selected)) do
      nil -> %{code: code}
      candidate -> %{code: code, candidate: candidate}
    end
  end

  defp pair(socket, offer) do
    attempted = Map.get(offer, :code, socket.assigns.attempted)
    socket = Mob.Socket.assign(socket, offer: offer, attempted: attempted, matched: nil)

    case pairing().pair(self(), offer) do
      :ok -> Mob.Socket.assign(socket, :status, :pairing)
      {:error, reason} -> Mob.Socket.assign(socket, :status, {:failed, reason})
    end
  end

  @doc """
  The `XXXX-XXXX` form of `text` (upper-cased, letters and digits only, at
  most 8; a pasted code shows it at once) and whether it is a whole valid
  code (then in `Pairing.normalize_code/1`'s form, so `o`/`l` read as `0`/`1`).
  """
  def format_code(text) do
    chars =
      text
      |> String.upcase()
      |> String.replace(~r/[^0-9A-Z]/, "")
      |> String.slice(0, 8)

    case {String.length(chars), pairing().normalize_code(chars)} do
      {8, {:ok, code}} -> {code, true}
      {n, _} when n > 4 -> {String.slice(chars, 0, 4) <> "-" <> String.slice(chars, 4, 4), false}
      _ -> {chars, false}
    end
  end

  # Failures a retry with the same code or link can't fix.
  defp fresh_code_needed?({:wrong_code, _}), do: true

  defp fresh_code_needed?(reason),
    do: reason in [:too_many_attempts, :expired, :invalid_token, :invalid_code, :not_a_link]

  defp reset(socket),
    do: Mob.Socket.assign(socket, status: :idle, matched: nil, attempted: nil, scanner: :idle)

  defp notice(socket, title, body), do: Mob.Socket.assign(socket, :status, {:notice, title, body})

  defp open_scanner(socket) do
    socket |> MobScanner.scan(formats: [:qr]) |> Mob.Socket.assign(:scanner, :scanning)
  end

  defp camera_off(socket) do
    socket
    |> Mob.Socket.assign(:scanner, :idle)
    |> notice(
      "The camera is off for Humdinger",
      "Allow it in the phone's Settings, or type the code instead."
    )
  end

  defp pairing, do: Application.get_env(:humdinger, :pairing, Humdinger.FMutate.Pairing)
  defp clipboard, do: Application.get_env(:humdinger, :clipboard, Mob.Clipboard)
  defp device_calls?, do: Application.get_env(:humdinger, :device_calls, true)
end
