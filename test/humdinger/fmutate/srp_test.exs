defmodule Humdinger.FMutate.SrpTest do
  use ExUnit.Case, async: true

  alias Humdinger.FMutate.Srp

  @fp :crypto.hash(:sha256, "fmutate cert")
  @binding :crypto.hash(:sha256, "tls session")

  defp run(client_code, server_code) do
    salt = Srp.salt()
    verifier = Srp.verifier(server_code, salt)
    {a_pub, _} = client = Srp.client_keys()
    {b_pub, _} = server = Srp.server_keys(verifier)
    {:ok, client_key} = Srp.client_key(client_code, salt, client, b_pub)
    {:ok, server_key} = Srp.server_key(verifier, a_pub, server)
    %{a: a_pub, b: b_pub, client_key: client_key, server_key: server_key}
  end

  test "both sides derive the same key from the same code" do
    s = run("KQ7MX2PD", "KQ7MX2PD")
    assert s.client_key == s.server_key
    m1 = Srp.client_proof(s.client_key, @fp, @binding, s.a, s.b)
    assert Srp.same?(m1, Srp.client_proof(s.server_key, @fp, @binding, s.a, s.b))
  end

  test "a wrong code gives a proof FMutate rejects" do
    s = run("KQ7MX2PE", "KQ7MX2PD")
    refute s.client_key == s.server_key
    m1 = Srp.client_proof(s.client_key, @fp, @binding, s.a, s.b)
    refute Srp.same?(m1, Srp.client_proof(s.server_key, @fp, @binding, s.a, s.b))
  end

  test "the proofs bind the certificate and the TLS session" do
    s = run("KQ7MX2PD", "KQ7MX2PD")
    m1 = Srp.client_proof(s.client_key, @fp, @binding, s.a, s.b)
    m2 = Srp.server_proof(s.server_key, @fp, @binding, s.a, s.b, m1)
    other = :crypto.hash(:sha256, "relay cert")

    refute Srp.same?(m1, Srp.client_proof(s.server_key, other, @binding, s.a, s.b))
    refute Srp.same?(m1, Srp.client_proof(s.server_key, @fp, other, s.a, s.b))
    refute Srp.same?(m2, Srp.server_proof(s.client_key, other, @binding, s.a, s.b, m1))
  end

  test "public values that are 0 mod N are refused" do
    # RFC 5054 2048-bit N: N mod N == 0.
    n =
      Base.decode16!(
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
      )

    salt = Srp.salt()
    verifier = Srp.verifier("KQ7MX2PD", salt)
    server = Srp.server_keys(verifier)

    refute Srp.valid_public?(<<0>>)
    refute Srp.valid_public?(n)
    refute Srp.valid_public?(:binary.copy(<<1>>, 257))
    assert Srp.server_key(verifier, n, server) == :error
    assert Srp.client_key("KQ7MX2PD", salt, Srp.client_keys(), <<0>>) == :error
  end
end
