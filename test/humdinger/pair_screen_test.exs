defmodule Humdinger.PairScreenTest do
  # The pairing, clipboard and scanner doubles are set in the app env.
  use Mob.ScreenCase, async: false

  import Humdinger.Test.Screens, only: [assert_every_tap_held: 1, tap_tags: 1, texts: 1]

  alias Humdinger.FMutate.PairLink
  alias Humdinger.{PairScreen, Style}

  # Pairing: the real parse_link/normalize_code; the calls are reported to
  # the screen's process (the test's, under Mob.ScreenCase).
  defmodule Pairing do
    defdelegate parse_link(link), to: Humdinger.FMutate.Pairing
    defdelegate normalize_code(code), to: Humdinger.FMutate.Pairing

    def discover(owner) do
      send(self(), {:pairing, :discover, owner})
      :ok
    end

    def pair(owner, offer) do
      send(self(), {:pairing, :pair, owner, offer})
      :ok
    end

    def cancel do
      send(self(), {:pairing, :cancel})
      :ok
    end
  end

  defmodule Clipboard do
    def get(_socket) do
      case :persistent_term.get({__MODULE__, :text}, nil) do
        nil -> {:clipboard, :empty}
        text -> {:clipboard, :ok, text}
      end
    end
  end

  # MobScanner's NIF (MobScanner reads it from `config :mob_scanner, :nif`).
  defmodule ScannerNif do
    def scanner_scan(formats_json) do
      send(self(), {:scanner_opened, IO.iodata_to_binary(formats_json)})
      :ok
    end
  end

  @candidate %{
    name: "FMutate A",
    inst: "a",
    node: "fmutate_a",
    host: "192.168.1.23",
    port: 45_123,
    dist_port: 45_124,
    fp: :crypto.strong_rand_bytes(32),
    firmware: "X0X",
    device: "Pixel 7"
  }

  setup do
    restore = [
      {:humdinger, :pairing, Application.fetch_env(:humdinger, :pairing)},
      {:humdinger, :clipboard, Application.fetch_env(:humdinger, :clipboard)},
      {:mob_scanner, :nif, Application.fetch_env(:mob_scanner, :nif)}
    ]

    Application.put_env(:humdinger, :pairing, Pairing)
    Application.put_env(:humdinger, :clipboard, Clipboard)
    Application.put_env(:mob_scanner, :nif, ScannerNif)

    on_exit(fn ->
      :persistent_term.erase({Clipboard, :text})

      for {app, key, previous} <- restore do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    link =
      PairLink.build(%{
        inst: "a",
        node: "fmutate_a",
        host: "192.168.1.23",
        port: 45_123,
        fp: :crypto.strong_rand_bytes(32),
        token: :crypto.strong_rand_bytes(16)
      })

    %{link: link}
  end

  defp mount do
    view = mount_screen(PairScreen)
    me = self()
    assert_received {:pairing, :discover, ^me}
    view
  end

  defp type(view, text), do: render_info(view, {:change, :code, text})
  defp field(view), do: find(view, :text_field, id: "code")

  defp assert_paired_with(offer) do
    me = self()
    assert_received {:pairing, :pair, ^me, ^offer}
  end

  defp status(view), do: {assigns(view).status, texts(find(view, :box, id: "status"))}

  test "on mount: discovery, the board's parts, an idle hint; every tap target is held" do
    view = mount()
    assert_renderable(view)

    for text <- [
          "Pair with FMutate",
          "In FMutate, open I/O › Pair an app, then scan its code.",
          "Point at the code",
          "OR ENTER THE CODE",
          "Paste",
          "FOUND NEARBY",
          "Looking for FMutate on this Wi-Fi…",
          "Scan or type FMutate's code"
        ] do
      assert text in texts(view), text
    end

    assert field(view).props.placeholder == "XXXX-XXXX"
    assert find(view, :canvas, width: 350, height: 300)

    view =
      view
      |> render_info({:fmutate_pair, :found, [@candidate]})
      |> render_info({:fmutate_pair, :waiting})

    assert_every_tap_held(view)

    assert Enum.sort(tap_tags(view)) ==
             Enum.sort([:back, :scan, :paste, {:candidate, "a"}, :cancel])
  end

  describe "typing the code" do
    test "keeps the keys while typing, groups and lights up once whole and valid, pairs once" do
      # Partial codes stay as typed: changing them would make Android's field
      # drop the keys still in flight.
      view = type(mount(), "kq7m")
      assert field(view).props.value == "kq7m"
      assert field(view).props.border_color == Style.line()

      view = type(view, "kq7mx2")
      assert field(view).props.value == "kq7mx2"
      refute assigns(view).code_valid
      refute_received {:pairing, :pair, _, _}

      view = type(view, "kq7m x2pd")
      assert assigns(view).code == "KQ7M-X2PD"
      assert field(view).props.value == "KQ7M-X2PD"
      assert field(view).props.border_color == Style.fm()
      assert_paired_with(%{code: "KQ7M-X2PD"})
      assert {:pairing, ["Finding FMutate…", _, "Cancel"]} = status(view)

      # The same code again (a re-render echo) doesn't start a second pairing.
      view = type(view, "KQ7M-X2PD")
      refute_received {:pairing, :pair, _, _}

      # Return pairs again on purpose.
      render_info(view, {:submit, :code})
      assert_paired_with(%{code: "KQ7M-X2PD"})
    end

    test "is cut at 8 characters, and reads l as 1 and o as 0" do
      view = type(mount(), "kq7mx2plzzz")
      assert assigns(view).code == "KQ7M-X2P1"
      assert_paired_with(%{code: "KQ7M-X2P1"})

      view = type(view, "o")
      assert assigns(view).code == "o"
      refute assigns(view).code_valid
    end

    test "format_code groups partial codes (what a paste shows)" do
      assert PairScreen.format_code("kq7m") == {"KQ7M", false}
      assert PairScreen.format_code("kq7m-x2") == {"KQ7M-X2", false}
      assert PairScreen.format_code(" kq7m x2pd ") == {"KQ7M-X2PD", true}
      assert PairScreen.format_code("KQ7M-X2PU") == {"KQ7M-X2PU", false}
    end

    test "a character codes never use keeps it unlit" do
      view = type(mount(), "KQ7M-X2PU")
      assert field(view).props.value == "KQ7M-X2PU"
      refute assigns(view).code_valid
      refute_received {:pairing, :pair, _, _}
    end

    test "a whole link typed into the field pairs by link", %{link: link} do
      {:ok, offer} = PairLink.parse(link)
      view = type(mount(), link)
      assert assigns(view).code == ""
      assert_paired_with(offer)
      assert assigns(view).status == :pairing
    end
  end

  describe "paste" do
    test "a code fills the field and pairs" do
      :persistent_term.put({Clipboard, :text}, " kq7m-x2pd\n")
      view = render_info(mount(), {:tap, :paste})
      assert assigns(view).code == "KQ7M-X2PD"
      assert_paired_with(%{code: "KQ7M-X2PD"})
    end

    test "a link pairs at once", %{link: link} do
      :persistent_term.put({Clipboard, :text}, link)
      {:ok, offer} = PairLink.parse(link)
      render_info(mount(), {:tap, :paste})
      assert_paired_with(offer)
    end

    test "an empty clipboard says so" do
      view = render_info(mount(), {:tap, :paste})

      assert {_, ["Nothing to paste", "Copy the code or the link in FMutate first."]} =
               status(view)
    end
  end

  describe "scanning" do
    test "the viewfinder asks for the camera, opens the scanner, and pairs with the scanned link",
         %{link: link} do
      view = render_info(mount(), {:tap, :scan})
      assert assigns(view).scanner == :asking
      assert "Allow the camera…" in texts(view)
      refute_received {:scanner_opened, _}

      view = render_info(view, {:permission, :camera, :granted})
      assert_received {:scanner_opened, ~s(["qr"])}
      assert "Scanning…" in texts(view)

      view = render_info(view, {:scan, :result, %{type: :qr, value: link}})
      {:ok, offer} = PairLink.parse(link)
      assert_paired_with(offer)
      assert assigns(view).scanner == :found
      assert "Got it" in texts(view)

      # Granted once: the next tap opens the scanner straight away.
      render_info(view, {:tap, :scan})
      assert_received {:scanner_opened, _}
    end

    test "a code that isn't FMutate's is refused in plain words, and Try again resets" do
      view =
        mount()
        |> render_info({:permission, :camera, :granted})
        |> render_info({:scan, :result, %{type: :qr, value: "https://example.com"}})

      refute_received {:pairing, :pair, _, _}

      assert {{:failed, :not_a_link},
              [
                "That's not FMutate's code",
                "Scan the QR code on FMutate's Pair an app screen.",
                "Try again"
              ]} = status(view)

      assert {:idle, _} = status(render_info(view, {:tap, :retry}))
    end

    test "a refused or missing camera points at the typed code" do
      view = mount() |> render_info({:tap, :scan}) |> render_info({:permission, :camera, :denied})
      assert {_, ["The camera is off for Humdinger", _]} = status(view)
      assert assigns(view).scanner == :idle

      view = render_info(view, {:scan, :not_available})
      assert {_, ["The camera didn't open", _]} = status(view)

      view = render_info(view, {:scan, :cancelled})
      assert assigns(view).scanner == :idle
    end
  end

  describe "found nearby" do
    test "lists FMutates with device, Wi-Fi and state; matched says the code matches" do
      quiet = %{@candidate | name: "FMutate B", inst: "b", port: nil, firmware: nil, device: nil}
      view = render_info(mount(), {:fmutate_pair, :found, [@candidate, quiet]})

      assert "FMutate A · X0X" in texts(view)
      assert "Pixel 7 · Wi-Fi · showing its code" in texts(view)
      assert "FMutate B" in texts(view)
      assert "Wi-Fi · not showing its code" in texts(view)
      refute {:candidate, "b"} in tap_tags(view)

      view = view |> type("KQ7M-X2PD") |> render_info({:fmutate_pair, :matched, @candidate})
      assert "Pixel 7 · Wi-Fi · code matches" in texts(view)

      assert {:pairing,
              ["Code matches FMutate A", "Asking FMutate A to let Humdinger in.", "Cancel"]} =
               status(view)
    end

    test "a FMutate matched by link but not seen over mDNS is listed too", %{link: link} do
      {:ok, offer} = PairLink.parse(link)
      matched = %{@candidate | firmware: nil, device: nil, host: "127.0.0.1"}
      view = mount() |> type(link) |> render_info({:fmutate_pair, :matched, matched})
      assert_paired_with(offer)
      assert "this phone · code matches" in texts(view)
    end

    test "tapping one before typing picks it; the code then pairs with that FMutate" do
      view =
        mount()
        |> render_info({:fmutate_pair, :found, [@candidate]})
        |> render_info({:tap, {:candidate, "a"}})

      refute_received {:pairing, :pair, _, _}
      assert {_, ["Type FMutate A's code", _]} = status(view)
      assert find(view, :box, id: "a").props.border_color == Style.fm()

      type(view, "KQ7M-X2PD")
      assert_paired_with(%{code: "KQ7M-X2PD", candidate: @candidate})
    end

    test "tapping one with a whole code pairs with it" do
      mount()
      |> type("KQ7M-X2PD")
      |> render_info({:fmutate_pair, :found, [@candidate]})
      |> render_info({:tap, {:candidate, "a"}})

      assert_paired_with(%{code: "KQ7M-X2PD"})
      assert_paired_with(%{code: "KQ7M-X2PD", candidate: @candidate})
    end
  end

  describe "the status card" do
    test "waiting for Allow, then Cancel stops it and looks again" do
      view = mount() |> type("KQ7M-X2PD") |> render_info({:fmutate_pair, :waiting})

      assert {:waiting,
              [
                "Waiting for Allow…",
                "Tap Allow on the other phone. Encrypted link, checked against the code.",
                "Cancel"
              ]} = status(view)

      view = render_info(view, {:tap, :cancel})
      assert_received {:pairing, :cancel}
      me = self()
      assert_received {:pairing, :discover, ^me}
      assert {:idle, _} = status(view)
    end

    test "paired: says so, then goes back to Output" do
      info = %{
        name: "FMutate A",
        device: "Pixel 7",
        firmware: "X0X",
        inst: "a",
        same_phone: false
      }

      view = mount() |> type("KQ7M-X2PD") |> render_info({:fmutate_pair, :paired, info})

      assert {{:paired, ^info}, ["Paired with FMutate A", "Humdinger sends it MIDI from now on."]} =
               status(view)

      assert navigated_to(view) == nil

      assert_receive :paired_close, 2_000
      assert navigated_to(render_info(view, :paired_close)) == {:pop}
    end

    test "every failure reason reads in plain words with Try again" do
      for {reason, title} <- [
            {{:wrong_code, 3}, "Wrong code"},
            {:too_many_attempts, "Too many tries"},
            {:expired, "The code ran out"},
            {:invalid_token, "That code was already used"},
            {:denied, "FMutate said no"},
            {:unreachable, "Can't reach FMutate"},
            {:fingerprint_mismatch, "Not the FMutate you scanned"},
            {:not_found, "No FMutate found"},
            {:not_pairing, "FMutate isn't pairing"},
            {:busy, "FMutate is busy"},
            {:timeout, "No answer"},
            {:no_such_instance, "That FMutate is gone"},
            {:unsupported_version, "Update FMutate"},
            {{:store, :secure_store_unavailable}, "Couldn't save the pairing"},
            {{:protocol, :closed}, "Pairing didn't work"},
            {{:crashed, :boom}, "Pairing didn't work"}
          ] do
        view = mount() |> type("KQ7M-X2PD") |> render_info({:fmutate_pair, :failed, reason})
        assert {{:failed, ^reason}, [^title, _body, "Try again"]} = status(view)
        assert_renderable(view)
      end

      assert PairScreen.failure_text({:wrong_code, 3}) ==
               {"Wrong code", "That isn't the code FMutate shows. 3 tries left."}

      assert PairScreen.failure_text({:wrong_code, 1}) ==
               {"Wrong code", "That isn't the code FMutate shows. 1 try left."}
    end

    test "Try again repeats what can work again, and clears a code that can't" do
      view = mount() |> type("KQ7M-X2PD") |> render_info({:fmutate_pair, :failed, :unreachable})
      assert_paired_with(%{code: "KQ7M-X2PD"})
      view = render_info(view, {:tap, :retry})
      assert_paired_with(%{code: "KQ7M-X2PD"})
      assert assigns(view).status == :pairing

      view =
        view
        |> render_info({:fmutate_pair, :failed, {:wrong_code, 2}})
        |> render_info({:tap, :retry})

      refute_received {:pairing, :pair, _, _}
      assert assigns(view).status == :idle
      assert assigns(view).code == ""

      # The same code typed again is a fresh attempt.
      type(view, "KQ7M-X2PD")
      assert_paired_with(%{code: "KQ7M-X2PD"})
    end
  end

  test "leaving cancels discovery and pairing; back pops" do
    view = mount()
    assert navigated_to(render_info(view, {:tap, :back})) == {:pop}
    PairScreen.terminate(:normal, view.socket)
    assert_received {:pairing, :cancel}
  end
end
