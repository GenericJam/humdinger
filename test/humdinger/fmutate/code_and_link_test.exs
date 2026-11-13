defmodule Humdinger.FMutate.CodeAndLinkTest do
  use ExUnit.Case, async: true

  alias Humdinger.FMutate.{Code, Pairing, PairLink}

  doctest Humdinger.FMutate.Code

  describe "codes" do
    test "generated codes are 8 Crockford characters and survive display and retyping" do
      for _ <- 1..200 do
        code = Code.generate()
        assert code =~ ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/
        assert Code.normalize(Code.format(code)) == {:ok, code}
        assert Code.normalize(String.downcase(Code.format(code))) == {:ok, code}
      end
    end

    test "typing is forgiving: separators, case, I/L for 1 and O for 0" do
      assert Pairing.normalize_code("kq7m x2pd") == {:ok, "KQ7M-X2PD"}
      assert Pairing.normalize_code("KQ7M.X2PD\n") == {:ok, "KQ7M-X2PD"}
      assert Pairing.normalize_code("iL0o-0000") == {:ok, "1100-0000"}
    end

    test "wrong lengths, U and other characters are rejected" do
      for bad <- [
            "",
            "KQ7M-X2P",
            "KQ7M-X2PDD",
            "KQ7M-X2PU",
            "KQ7M-X2P!",
            "KQ7M_X2PD",
            "ＫQ7M-X2PD"
          ] do
        assert Pairing.normalize_code(bad) == {:error, :invalid_code}, inspect(bad)
      end
    end
  end

  describe "pairing links" do
    setup do
      fields = %{
        inst: "a",
        node: "fmutate_a",
        host: "192.168.1.23",
        port: 45_123,
        fp: :crypto.strong_rand_bytes(32),
        token: :crypto.strong_rand_bytes(16)
      }

      %{fields: fields, link: PairLink.build(fields)}
    end

    test "a built link parses back to the same offer", %{fields: fields, link: link} do
      assert {:ok, offer} = Pairing.parse_link(link)
      assert offer == Map.put(fields, :via, :link)
    end

    test "surrounding whitespace from a paste is ignored", %{link: link} do
      assert {:ok, _} = Pairing.parse_link("  " <> link <> "\n")
    end

    test "every field is checked", %{link: link} do
      cases = [
        {"https://pair?v=1", :not_a_pairing_link},
        {"fmutate://unpair?v=1", :not_a_pairing_link},
        {"not a link", :not_a_pairing_link},
        {String.replace(link, "v=1", "v=2"), :unsupported_version},
        {String.replace(link, "inst=a", "inst=ab"), {:invalid, :inst}},
        {String.replace(link, "node=fmutate_a", "node=evil"), {:invalid, :node}},
        {String.replace(link, "host=192.168.1.23", "host=example.com"), {:invalid, :host}},
        {String.replace(link, "port=45123", "port=70000"), {:invalid, :port}},
        {Regex.replace(~r/fp=[^&]+/, link, "fp=AAAA"), {:invalid, :fp}},
        {Regex.replace(~r/&t=[^&]+/, link, ""), {:missing, :token}}
      ]

      for {bad, reason} <- cases do
        assert Pairing.parse_link(bad) == {:error, reason}, bad
      end
    end
  end
end
