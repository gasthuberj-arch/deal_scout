defmodule DealScout.Notifications.PushDiagnosticsTest do
  use DealScout.DataCase, async: false

  alias DealScout.Repo
  alias DealScout.Accounts.User
  alias DealScout.Notifications
  alias DealScout.Notifications.PushSubscription
  alias DealScout.Notifications.PushDeliveryLog
  alias DealScout.Notifications.WebPush.TestTransport

  setup do
    TestTransport.reset()

    user =
      Repo.insert!(%User{
        email: "diag-user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "dummy_password"
      })

    %{user: user}
  end

  test "deliver_push_to_user logs status 'no_subscriptions' when user has no devices", %{
    user: user
  } do
    assert {:ok, []} = Notifications.deliver_push_to_user(user, %{title: "Test", body: "Hello"})

    logs = Notifications.list_push_delivery_logs(user)
    assert length(logs) == 1
    log = hd(logs)
    assert log.status == "no_subscriptions"
    assert log.error_message =~ "0 registered push devices"
  end

  test "deliver_push_to_user logs gateway duration and status 'delivered' on success", %{
    user: user
  } do
    {rec_pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    p256dh = Base.url_encode64(rec_pub, padding: false)
    auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    sub =
      Repo.insert!(%PushSubscription{
        user_id: user.id,
        endpoint:
          "https://fcm.googleapis.com/fcm/send/success-token-#{System.unique_integer([:positive])}",
        p256dh: p256dh,
        auth: auth,
        device_name: "Pixel 9"
      })

    TestTransport.stub_endpoint(sub.endpoint, {:ok, %{status: 201, body: ""}})

    assert {:ok, [res]} =
             Notifications.deliver_push_to_user(user, %{title: "Deal Alert", body: "50% off"})

    assert match?({:ok, %{status: :delivered}}, res)

    logs = Notifications.list_push_delivery_logs(user)
    assert length(logs) == 1
    log = hd(logs)
    assert log.status == "delivered"
    assert log.http_status == 201
    assert log.gateway_duration_ms >= 0
    assert log.push_subscription_id == sub.id
  end

  test "deliver_push_to_user logs 'expired' when gateway returns 410", %{user: user} do
    {rec_pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    p256dh = Base.url_encode64(rec_pub, padding: false)
    auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    sub =
      Repo.insert!(%PushSubscription{
        user_id: user.id,
        endpoint:
          "https://fcm.googleapis.com/fcm/send/expired-token-#{System.unique_integer([:positive])}",
        p256dh: p256dh,
        auth: auth,
        device_name: "iPhone 15"
      })

    TestTransport.stub_endpoint(sub.endpoint, {:ok, %{status: 410, body: "Gone"}})

    assert {:ok, [res]} =
             Notifications.deliver_push_to_user(user, %{title: "Test", body: "Hello"})

    assert match?({:error, %{status: :subscription_expired}}, res)

    logs = Notifications.list_push_delivery_logs(user)
    assert length(logs) == 1
    log = hd(logs)
    assert log.status == "expired"
    assert log.http_status == 410
    assert Repo.get(PushSubscription, sub.id) == nil
  end

  test "record_receipt/3 updates client_received_at and client_delay_ms", %{user: user} do
    log =
      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        tracking_id: "test-tracking-123",
        status: "delivered",
        http_status: 201
      })

    now_ms = System.system_time(:millisecond)
    delay_ms = 450

    assert {:ok, updated} = Notifications.record_receipt("test-tracking-123", now_ms, delay_ms)
    assert %DateTime{} = updated.client_received_at
    assert is_integer(updated.client_delay_ms) and updated.client_delay_ms >= 0

    reloaded = Repo.get!(PushDeliveryLog, log.id)
    assert reloaded.client_delay_ms == updated.client_delay_ms
  end

  test "record_receipt/3 returns {:error, :not_found} without delay for unknown tracking IDs" do
    now_ms = System.system_time(:millisecond)

    assert {:error, :not_found} =
             Notifications.record_receipt("non-existent-tracking-id", now_ms, 300)
  end

  test "record_receipt/3 resolves receipt against pre-dispatched pending log", %{
    user: user
  } do
    tracking_id = "pending-tracking-#{System.unique_integer([:positive])}"
    now_ms = System.system_time(:millisecond)

    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: tracking_id,
      status: "pending"
    })

    assert {:ok, updated} = Notifications.record_receipt(tracking_id, now_ms, 120)
    assert %DateTime{} = updated.client_received_at
    assert is_integer(updated.client_delay_ms)
  end
end
