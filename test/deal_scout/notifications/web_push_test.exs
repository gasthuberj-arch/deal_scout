defmodule DealScout.Notifications.WebPushTest do
  use DealScout.DataCase, async: false

  alias DealScout.Notifications
  alias DealScout.Notifications.WebPush
  alias DealScout.AccountsFixtures

  describe "VAPID key generation and JWT signing" do
    test "vapid_public_key/0 returns a valid base64url string" do
      pub_key = WebPush.vapid_public_key()
      assert is_binary(pub_key)
      assert byte_size(pub_key) > 40
    end

    test "generate_vapid_jwt/3 generates a verifiable ES256 JWT" do
      config = WebPush.vapid_config()
      endpoint = "https://updates.push.services.mozilla.com/wpush/v2/gAAAAABk..."
      assert {:ok, jwt} = WebPush.generate_vapid_jwt(endpoint, config.subject, config.private_key)

      [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")

      header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header["alg"] == "ES256"
      assert header["typ"] == "JWT"
      assert claims["aud"] == "https://updates.push.services.mozilla.com"
      assert claims["sub"] == config.subject
      assert claims["exp"] > System.system_time(:second)

      # Verify signature
      raw_sig = Base.url_decode64!(sig_b64, padding: false)
      assert byte_size(raw_sig) == 64
      <<r::binary-size(32), s::binary-size(32)>> = raw_sig

      # Convert raw r || s to ASN.1 DER for :crypto.verify
      r_int = :binary.decode_unsigned(r)
      s_int = :binary.decode_unsigned(s)
      r_asn1 = encode_asn1_integer(r_int)
      s_asn1 = encode_asn1_integer(s_int)
      der_sig = <<0x30, byte_size(r_asn1 <> s_asn1)>> <> r_asn1 <> s_asn1

      signing_input = header_b64 <> "." <> claims_b64

      assert :crypto.verify(:ecdsa, :sha256, signing_input, der_sig, [
               config.public_key,
               :secp256r1
             ])
    end

    defp encode_asn1_integer(val) do
      bytes = :binary.encode_unsigned(val)
      # If high bit is set, prepend zero byte in ASN.1 signed int
      bytes = if :binary.first(bytes) >= 128, do: <<0>> <> bytes, else: bytes
      <<0x02, byte_size(bytes)>> <> bytes
    end
  end

  describe "RFC 8291 payload encryption" do
    test "encrypts payload which decrypts correctly with receiver key" do
      # Simulate receiver browser keypair
      {rec_pub, rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
      rec_auth = :crypto.strong_rand_bytes(16)

      rec_pub_b64 = Base.url_encode64(rec_pub, padding: false)
      rec_auth_b64 = Base.url_encode64(rec_auth, padding: false)

      payload = "{\"title\":\"Hot Deal Alert!\",\"price\":\"299 €\"}"

      assert {:ok, encrypted_body} = WebPush.encrypt_payload(payload, rec_pub_b64, rec_auth_b64)
      assert is_binary(encrypted_body)
      assert byte_size(encrypted_body) > byte_size(payload)

      # Decrypt with receiver private key to verify RFC 8291 compliance
      <<salt::binary-size(16), _rs::binary-size(4), id_len, local_pub::binary-size(id_len),
        ct_and_tag::binary>> = encrypted_body

      ct_len = byte_size(ct_and_tag) - 16
      <<ciphertext::binary-size(^ct_len), tag::binary-size(16)>> = ct_and_tag

      ecdh_secret = :crypto.compute_key(:ecdh, local_pub, rec_priv, :secp256r1)
      prk_key = :crypto.mac(:hmac, :sha256, rec_auth, ecdh_secret)
      key_info = "WebPush: info\0" <> rec_pub <> local_pub
      t1 = :crypto.mac(:hmac, :sha256, prk_key, key_info <> <<1>>)
      ikm = binary_part(t1, 0, 32)

      prk = :crypto.mac(:hmac, :sha256, salt, ikm)

      cek =
        binary_part(
          :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm\0" <> <<1>>),
          0,
          16
        )

      nonce =
        binary_part(:crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce\0" <> <<1>>), 0, 12)

      decrypted =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

      dec_len = byte_size(decrypted) - 1
      <<dec_payload::binary-size(^dec_len), 2>> = decrypted
      assert dec_payload == payload
    end
  end

  describe "Push subscription context" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "creates, lists, and deletes push subscriptions", %{user: user} do
      attrs = %{
        endpoint: "https://push.example.com/sub/123",
        p256dh: "BF4u7z3mR...",
        auth: "k8Fz...",
        device_name: "Pixel 8 Pro",
        user_agent: "Mozilla/5.0 Android"
      }

      assert {:ok, sub} = Notifications.create_or_update_push_subscription(user, attrs)
      assert sub.endpoint == attrs.endpoint
      assert sub.device_name == "Pixel 8 Pro"

      subs = Notifications.list_push_subscriptions_for_user(user.id)
      assert length(subs) == 1
      assert hd(subs).id == sub.id

      # Idempotent update on same endpoint
      updated_attrs = Map.put(attrs, :device_name, "Pixel 8 Pro (Updated)")

      assert {:ok, updated_sub} =
               Notifications.create_or_update_push_subscription(user, updated_attrs)

      assert updated_sub.id == sub.id
      assert updated_sub.device_name == "Pixel 8 Pro (Updated)"

      # Delete subscription
      assert {:ok, _} = Notifications.delete_user_push_subscription(user.id, sub.id)
      assert Notifications.list_push_subscriptions_for_user(user.id) == []
    end
  end
end
