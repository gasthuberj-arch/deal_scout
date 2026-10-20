defmodule DealScout.Notifications.WebPush do
  @moduledoc """
  Lightweight, dependency-free Web Push implementation adhering to RFC 8291 (Message Encryption
  for Web Push) and RFC 8292 (Voluntary Application Server Identification for Web Push - VAPID).
  Uses Erlang OTP `:crypto` and Phoenix standard `:req`.
  """

  require Logger

  @default_subject "mailto:admin@dealscout.local"

  # Fallback deterministic development/test VAPID P-256 keypair (secp256r1)
  # Public key (65 bytes uncompressed): 0x04 || X (32 bytes) || Y (32 bytes)
  @dev_private_key :crypto.hash(:sha256, "deal_scout_dev_vapid_key_seed")
  # Deterministic public key corresponding to @dev_private_key
  @dev_public_key elem(:crypto.generate_key(:ecdh, :secp256r1, @dev_private_key), 0)

  @doc """
  Returns the VAPID configuration map with keys `:public_key`, `:private_key`, `:subject`.
  """
  def vapid_config do
    app_config = Application.get_env(:deal_scout, :vapid, [])

    subject =
      System.get_env("VAPID_SUBJECT") ||
        Keyword.get(app_config, :subject) ||
        @default_subject

    {pub_bin, priv_bin} =
      case {System.get_env("VAPID_PUBLIC_KEY"), System.get_env("VAPID_PRIVATE_KEY")} do
        {pub_str, priv_str}
        when is_binary(pub_str) and is_binary(priv_str) and pub_str != "" and priv_str != "" ->
          {decode_key(pub_str), decode_key(priv_str)}

        _ ->
          case {Keyword.get(app_config, :public_key), Keyword.get(app_config, :private_key)} do
            {pub_str, priv_str}
            when is_binary(pub_str) and is_binary(priv_str) and pub_str != "" ->
              {decode_key(pub_str), decode_key(priv_str)}

            _ ->
              {@dev_public_key, @dev_private_key}
          end
      end

    %{
      public_key: pub_bin,
      private_key: priv_bin,
      subject: subject
    }
  end

  @doc """
  Returns the URL-safe base64 encoded public key for clients (unpadded).
  """
  def vapid_public_key do
    vapid_config().public_key
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Sends a web push notification to a PushSubscription.
  `payload` can be a map (encoded to JSON) or binary string.
  """
  def send_notification(subscription, payload) do
    config = vapid_config()
    endpoint = subscription.endpoint
    p256dh = subscription.p256dh
    auth = subscription.auth

    json_payload =
      if is_map(payload) do
        Jason.encode!(payload)
      else
        to_string(payload)
      end

    with {:ok, encrypted_body} <- encrypt_payload(json_payload, p256dh, auth),
         {:ok, jwt} <- generate_vapid_jwt(endpoint, config.subject, config.private_key) do
      pub_b64 = Base.url_encode64(config.public_key, padding: false)

      headers = [
        {"content-type", "application/octet-stream"},
        {"content-encoding", "aes128gcm"},
        {"ttl", "86400"},
        {"urgency", "high"},
        {"authorization", "vapid t=#{jwt},k=#{pub_b64}"}
      ]

      case Req.post(endpoint, body: encrypted_body, headers: headers, retry: false) do
        {:ok, %{status: status}} when status in 200..204 ->
          {:ok, :delivered}

        {:ok, %{status: status, body: _body}} when status in [404, 410] ->
          Logger.info("[WebPush] Subscription expired or gone (#{status}): #{endpoint}")
          {:error, :subscription_expired}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[WebPush] Failed delivering to #{endpoint}: HTTP #{status} #{inspect(body)}"
          )

          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("[WebPush] Request error delivering to #{endpoint}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Encrypts payload according to RFC 8291 (aes128gcm).
  """
  def encrypt_payload(plaintext, receiver_p256dh_b64, receiver_auth_b64)
      when is_binary(plaintext) do
    with {:ok, receiver_p256dh} <- decode_base64(receiver_p256dh_b64),
         {:ok, receiver_auth} <- decode_base64(receiver_auth_b64) do
      salt = :crypto.strong_rand_bytes(16)
      {local_public, local_private} = :crypto.generate_key(:ecdh, :secp256r1)

      ecdh_secret = :crypto.compute_key(:ecdh, receiver_p256dh, local_private, :secp256r1)

      # Key derivation (RFC 8291 section 3.2)
      prk_key = :crypto.mac(:hmac, :sha256, receiver_auth, ecdh_secret)
      key_info = "WebPush: info\0" <> receiver_p256dh <> local_public
      ikm = hkdf_expand(prk_key, key_info, 32)

      prk = :crypto.mac(:hmac, :sha256, salt, ikm)
      cek = hkdf_expand(prk, "Content-Encoding: aes128gcm\0", 16)
      nonce = hkdf_expand(prk, "Content-Encoding: nonce\0", 12)

      # Padded plaintext: payload followed by delimiter 0x02
      padded = plaintext <> <<2>>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, <<>>, true)

      body =
        salt <>
          <<4096::big-unsigned-integer-32>> <>
          <<byte_size(local_public)::unsigned-integer-8>> <>
          local_public <>
          ciphertext <>
          tag

      {:ok, body}
    end
  rescue
    e ->
      {:error, {:encryption_error, Exception.message(e)}}
  end

  @doc """
  Generates a signed VAPID JWT (RFC 8292) using ES256.
  """
  def generate_vapid_jwt(endpoint, subject, private_key) do
    origin = extract_origin(endpoint)
    now = System.system_time(:second)
    exp = now + 12 * 3600

    header = %{"typ" => "JWT", "alg" => "ES256"}

    claims = %{
      "aud" => origin,
      "exp" => exp,
      "sub" => subject
    }

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    claims_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signing_input = header_b64 <> "." <> claims_b64

    der_sig = :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, :secp256r1])

    case der_to_raw_sig(der_sig) do
      {:ok, raw_sig} ->
        sig_b64 = Base.url_encode64(raw_sig, padding: false)
        {:ok, signing_input <> "." <> sig_b64}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:jwt_error, Exception.message(e)}}
  end

  defp extract_origin(endpoint) do
    uri = URI.parse(endpoint)

    "#{uri.scheme}://#{uri.host}#{if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""}"
  end

  defp hkdf_expand(prk, info, len) when len <= 32 do
    t1 = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(t1, 0, len)
  end

  defp der_to_raw_sig(
         <<0x30, _seq_len, 0x02, r_len, r::binary-size(r_len), 0x02, s_len,
           s::binary-size(s_len)>>
       ) do
    r_bin = <<:binary.decode_unsigned(r)::unsigned-big-integer-size(256)>>
    s_bin = <<:binary.decode_unsigned(s)::unsigned-big-integer-size(256)>>
    {:ok, r_bin <> s_bin}
  end

  defp der_to_raw_sig(other) do
    {:error, {:invalid_der_signature, other}}
  end

  defp decode_key(str) when is_binary(str) do
    case decode_base64(str) do
      {:ok, bin} -> bin
      _ -> str
    end
  end

  defp decode_base64(str) do
    # Support both standard Base64 and URL-safe Base64, with or without padding
    normalized =
      str
      |> String.replace("-", "+")
      |> String.replace("_", "/")

    padded =
      case rem(byte_size(normalized), 4) do
        2 -> normalized <> "=="
        3 -> normalized <> "="
        _ -> normalized
      end

    case Base.decode64(padded) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  end
end
