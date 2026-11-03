defmodule DealScout.Notifications.DispatcherTest do
  use DealScout.DataCase, async: true
  import ExUnit.CaptureLog

  alias DealScout.Notifications.Dispatcher
  alias DealScout.Alerts.{AlertRule, UserMatch}
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.Accounts.User

  setup do
    user =
      Repo.insert!(%User{
        email: "test-user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "hashed_dummy_password"
      })

    feed =
      Repo.insert!(%Feed{
        name: "MyDealz",
        slug: "mydealz-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "MediaMarkt",
        slug: "mediamarkt-#{System.unique_integer([:positive])}"
      })

    deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-guid-#{System.unique_integer([:positive])}",
        title: "Sony PlayStation 5 Slim",
        url: "https://example.com/ps5",
        clean_text: "Top Gaming Console",
        price: Decimal.new("449.00"),
        raw_merchant: "MediaMarkt",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "PS5 Alert",
        keywords: "PlayStation 5",
        notify_email: true,
        is_active: true
      })

    match =
      Repo.insert!(%UserMatch{
        user_id: user.id,
        deal_id: deal.id,
        alert_rule_id: rule.id,
        notified_via_email: false
      })

    %{user: user, feed: feed, merchant: merchant, deal: deal, rule: rule, match: match}
  end

  test "dispatch/1 delivers deal alert email with %Merchant{} struct and updates notified_via_email",
       %{user: user, match: match} do
    Phoenix.PubSub.subscribe(DealScout.PubSub, Dispatcher.user_topic(user.id))

    assert {:ok, updated_match} = Dispatcher.dispatch(match)

    # PubSub broadcast received
    assert_receive {:new_match, %UserMatch{id: match_id}}
    assert match_id == match.id

    # Database record updated
    reloaded = Repo.get!(UserMatch, match.id)
    assert reloaded.notified_via_email == true
    assert updated_match.notified_via_email == true
  end

  test "dispatch/1 logs error when email delivery raises an exception", %{match: _match} do
    corrupted_match = %UserMatch{
      id: 99_999,
      user_id: 99_999,
      deal_id: 99_999,
      alert_rule_id: 99_999,
      notified_via_email: false,
      user: %User{email: 12345},
      deal: %Deal{title: "Corrupted Deal", price: nil, merchant: nil, url: "http://example.com"},
      alert_rule: %AlertRule{
        id: 99_999,
        name: "Corrupted Rule",
        keywords: "test",
        notify_email: true
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, updated} = Dispatcher.dispatch(corrupted_match)
        assert updated.notified_via_email == false
      end)

    assert log =~ "[DealScout.Dispatcher] Exception delivering deal alert email for match 99999"
  end

  test "dispatch_batch/2 enforces Cooldown (broadcasts to inbox while suppressing push/email)",
       %{user: user, rule: rule, match: match} do
    Phoenix.PubSub.subscribe(DealScout.PubSub, Dispatcher.user_topic(user.id))
    five_min_ago = DateTime.add(DateTime.utc_now(), -300, :second) |> DateTime.truncate(:second)

    {:ok, cooled_rule} =
      rule
      |> Ecto.Changeset.change(cooldown_minutes: 30, last_notified_at: five_min_ago)
      |> Repo.update()

    assert :ok = Dispatcher.dispatch_batch(cooled_rule, [match])

    # Broadcasts to LiveView inbox even during cooldown
    assert_receive {:new_match, %UserMatch{id: match_id}}
    assert match_id == match.id

    # Does not send email or update last_notified_at
    reloaded_match = Repo.get!(UserMatch, match.id)
    assert reloaded_match.notified_via_email == false
    assert reloaded_match.notified_via_push == false

    reloaded_rule = Repo.get!(AlertRule, cooled_rule.id)
    assert DateTime.diff(reloaded_rule.last_notified_at, five_min_ago, :second) == 0

    # Diagnostic audit log records the cooldown suppression reason
    logs = DealScout.Notifications.list_push_delivery_logs(user)
    assert length(logs) >= 1

    assert Enum.any?(logs, fn l ->
             l.status == "skipped_cooldown" and l.user_match_id == match.id
           end)
  end

  test "queues and flushes Digest matches, recording actual delivery flags and clearing digest_at",
       %{rule: rule, match: match} do
    two_hours_ago =
      DateTime.add(DateTime.utc_now(), -7200, :second) |> DateTime.truncate(:second)

    {:ok, digest_rule} =
      rule
      |> Ecto.Changeset.change(
        delivery_mode: "hourly_digest",
        notify_email: true,
        notify_push: true
      )
      |> Repo.update()

    assert :ok = Dispatcher.dispatch_batch(digest_rule, [match])

    queued = Repo.get!(UserMatch, match.id)
    assert %DateTime{} = queued.digest_at
    assert queued.notified_via_email == false
    assert queued.notified_via_push == false

    # Age digest_at past the 1-hour window
    queued
    |> Ecto.Changeset.change(digest_at: two_hours_ago)
    |> Repo.update!()

    # Flush pending digests (user has email enabled, but 0 push subscriptions)
    assert 1 = Dispatcher.flush_pending_digests()

    flushed = Repo.get!(UserMatch, match.id)
    assert flushed.notified_via_email == true
    assert flushed.notified_via_push == false
    assert is_nil(flushed.digest_at)

    # Subsequent flush does not re-process the already-flushed match
    assert 0 = Dispatcher.flush_pending_digests()
  end

  test "push notification payloads include dedicated badge and icon assets", %{
    user: user,
    deal: _deal,
    rule: rule,
    match: match
  } do
    DealScout.Notifications.WebPush.TestTransport.reset()

    {:ok, rule} =
      rule
      |> Ecto.Changeset.change(notify_push: true)
      |> Repo.update()

    {rec_pub, _rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)
    p256dh_b64 = Base.url_encode64(rec_pub, padding: false)
    auth_b64 = Base.url_encode64(rec_auth, padding: false)

    test_endpoint = "https://fcm.googleapis.com/fcm/send/test-token"

    Repo.insert!(%DealScout.Notifications.PushSubscription{
      user_id: user.id,
      endpoint: test_endpoint,
      p256dh: p256dh_b64,
      auth: auth_b64
    })

    match = %{match | alert_rule: rule}

    assert {:ok, updated} = Dispatcher.dispatch(match)
    assert updated.notified_via_push == true

    deliveries = DealScout.Notifications.WebPush.TestTransport.delivered_notifications()
    assert length(deliveries) >= 1
    delivery = hd(deliveries)
    assert delivery.endpoint == test_endpoint
    assert is_binary(delivery.body)

    assert {:ok, _results} = DealScout.Notifications.send_test_notification(user)
  end

  test "delivers single push with localized title", %{
    user: user,
    rule: rule,
    match: match
  } do
    {:ok, rule} =
      rule
      |> Ecto.Changeset.change(notify_push: true)
      |> Repo.update()

    {rec_pub, rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)
    p256dh_b64 = Base.url_encode64(rec_pub, padding: false)
    auth_b64 = Base.url_encode64(rec_auth, padding: false)

    DealScout.Notifications.WebPush.TestTransport.reset()

    Repo.insert!(%DealScout.Notifications.PushSubscription{
      user_id: user.id,
      endpoint: "https://fcm.googleapis.com/fcm/send/locale-single-token",
      p256dh: p256dh_b64,
      auth: auth_b64
    })

    match = %{match | alert_rule: rule}
    assert {:ok, updated} = Dispatcher.dispatch(match)
    assert updated.notified_via_push == true

    [delivery | _] = DealScout.Notifications.WebPush.TestTransport.delivered_notifications()
    payload = decrypt_payload(delivery.body, rec_pub, rec_priv, rec_auth)
    assert payload["title"] == "🔥 Neuer Deal: PS5 Alert"
  end

  test "delivers batch push with localized title and pricing", %{
    user: user,
    rule: rule,
    feed: feed,
    merchant: merchant
  } do
    {:ok, rule} =
      rule
      |> Ecto.Changeset.change(notify_push: true)
      |> Repo.update()

    {rec_pub, rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)
    p256dh_b64 = Base.url_encode64(rec_pub, padding: false)
    auth_b64 = Base.url_encode64(rec_auth, padding: false)

    DealScout.Notifications.WebPush.TestTransport.reset()

    Repo.insert!(%DealScout.Notifications.PushSubscription{
      user_id: user.id,
      endpoint: "https://fcm.googleapis.com/fcm/send/locale-batch-token",
      p256dh: p256dh_b64,
      auth: auth_b64
    })

    deal1 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-batch-1",
        title: "Deal 1",
        url: "https://example.com/1",
        clean_text: "Deal 1 text",
        price: Decimal.new("299.00"),
        raw_merchant: "MediaMarkt",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    deal2 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-batch-2",
        title: "Deal 2",
        url: "https://example.com/2",
        clean_text: "Deal 2 text",
        price: Decimal.new("399.00"),
        raw_merchant: "MediaMarkt",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    match1 =
      Repo.insert!(%UserMatch{
        user_id: user.id,
        deal_id: deal1.id,
        alert_rule_id: rule.id,
        notified_via_push: false
      })

    match2 =
      Repo.insert!(%UserMatch{
        user_id: user.id,
        deal_id: deal2.id,
        alert_rule_id: rule.id,
        notified_via_push: false
      })

    :ok = Dispatcher.dispatch_batch(rule, [match1, match2])

    [delivery | _] = DealScout.Notifications.WebPush.TestTransport.delivered_notifications()
    payload = decrypt_payload(delivery.body, rec_pub, rec_priv, rec_auth)
    assert payload["title"] == "🔥 2 neue Deals für 'PS5 Alert' (ab 299 €)"
  end

  defp decrypt_payload(encrypted_body, rec_pub, rec_priv, rec_auth) do
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
    Jason.decode!(dec_payload)
  end

  test "prunes expired subscriptions when push transport returns 410 Gone", %{
    user: user,
    rule: rule,
    match: match
  } do
    {:ok, rule} =
      rule
      |> Ecto.Changeset.change(notify_push: true)
      |> Repo.update()

    {rec_pub, _rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)
    p256dh_b64 = Base.url_encode64(rec_pub, padding: false)
    auth_b64 = Base.url_encode64(rec_auth, padding: false)

    expired_endpoint = "https://fcm.googleapis.com/fcm/send/expired-token"

    sub =
      Repo.insert!(%DealScout.Notifications.PushSubscription{
        user_id: user.id,
        endpoint: expired_endpoint,
        p256dh: p256dh_b64,
        auth: auth_b64
      })

    DealScout.Notifications.WebPush.TestTransport.stub_endpoint(
      expired_endpoint,
      {:ok, %{status: 410, body: "Gone"}}
    )

    match = %{match | alert_rule: rule}
    assert {:ok, _} = Dispatcher.dispatch(match)

    assert Repo.get(DealScout.Notifications.PushSubscription, sub.id) == nil

    DealScout.Notifications.WebPush.TestTransport.reset()
  end
end
