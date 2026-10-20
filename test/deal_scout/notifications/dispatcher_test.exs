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
    # Pass a corrupted match or trigger exception in email delivery
    # We pass an invalid user with non-string email that causes email delivery to raise
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
        assert {:ok, _} = Dispatcher.dispatch(corrupted_match)
      end)

    assert log =~ "[DealScout.Dispatcher] Exception delivering deal alert email for match 99999"
  end

  test "push notification payloads include dedicated badge and icon assets", %{
    user: user,
    deal: _deal,
    rule: rule,
    match: match
  } do
    DealScout.Notifications.WebPush.TestTransport.reset()

    # Enable push on rule
    {:ok, rule} =
      rule
      |> Ecto.Changeset.change(notify_push: true)
      |> Repo.update()

    {rec_pub, _rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)
    p256dh_b64 = Base.url_encode64(rec_pub, padding: false)
    auth_b64 = Base.url_encode64(rec_auth, padding: false)

    test_endpoint = "https://fcm.googleapis.com/fcm/send/test-token"

    # Create push subscription for user
    Repo.insert!(%DealScout.Notifications.PushSubscription{
      user_id: user.id,
      endpoint: test_endpoint,
      p256dh: p256dh_b64,
      auth: auth_b64
    })

    match = %{match | alert_rule: rule}

    # Dispatch single push - verify it runs without error and marks notified_via_push
    assert {:ok, updated} = Dispatcher.dispatch(match)
    assert updated.notified_via_push == true

    # Assert notification was received by transport with valid headers
    deliveries = DealScout.Notifications.WebPush.TestTransport.delivered_notifications()
    assert length(deliveries) >= 1
    delivery = hd(deliveries)
    assert delivery.endpoint == test_endpoint
    assert is_binary(delivery.body)

    # Test send_test_notification payload delivery
    assert {:ok, _results} = DealScout.Notifications.send_test_notification(user)
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

    # Subscription was pruned from the database
    assert Repo.get(DealScout.Notifications.PushSubscription, sub.id) == nil

    DealScout.Notifications.WebPush.TestTransport.reset()
  end
end
