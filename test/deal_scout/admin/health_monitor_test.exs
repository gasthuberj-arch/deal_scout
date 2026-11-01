defmodule DealScout.Admin.HealthMonitorTest do
  use DealScout.DataCase, async: false

  alias DealScout.Admin.HealthMonitor
  alias DealScout.AccountsFixtures
  alias DealScout.Notifications
  alias DealScout.Notifications.WebPush.TestTransport
  alias DealScout.Feeds.Feed
  alias DealScout.Alerts.AlertRule

  setup do
    TestTransport.reset()
    admin = AccountsFixtures.admin_fixture()

    {rec_pub, _rec_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    rec_auth = :crypto.strong_rand_bytes(16)

    {:ok, sub} =
      Notifications.create_or_update_push_subscription(admin, %{
        endpoint: "https://push.example.com/sub/admin-#{System.unique_integer([:positive])}",
        p256dh: Base.url_encode64(rec_pub, padding: false),
        auth: Base.url_encode64(rec_auth, padding: false)
      })

    mon_name = :"health_monitor_#{System.unique_integer([:positive])}"

    mon_pid =
      start_supervised!({HealthMonitor, [name: mon_name, skip_timer: true, cooldown_ms: 100]})

    Ecto.Adapters.SQL.Sandbox.allow(DealScout.Repo, self(), mon_pid)

    %{admin: admin, sub: sub, mon_name: mon_name, mon_pid: mon_pid}
  end

  test "detects auto-paused rules and delivers push alert to admin", %{
    admin: admin,
    sub: sub,
    mon_name: mon_name
  } do
    # Create auto-paused rule
    rule =
      Repo.insert!(%AlertRule{
        user_id: admin.id,
        name: "Slow Heavy Regex",
        keywords: "expensive query",
        is_active: false,
        pause_reason: "Auto-paused: Query took 45.0ms (exceeded 30ms compute budget)."
      })

    alarms = HealthMonitor.check_now(mon_name)
    auto_paused_alarm = Enum.find(alarms, &(&1.type == :auto_paused_rules))

    assert auto_paused_alarm != nil
    assert auto_paused_alarm.severity == :warning
    assert auto_paused_alarm.title =~ "Alert Rules Auto-Paused"

    # Verify push notification sent to admin
    deliveries = TestTransport.delivered_notifications()
    assert length(deliveries) >= 1
    last_delivery = List.last(deliveries)
    assert last_delivery.endpoint == sub.endpoint
    assert byte_size(last_delivery.body) > 0

    # Resuming rule resolves the alarm and triggers auto-resolve push notification
    Repo.delete!(rule)

    alarms_after = HealthMonitor.check_now(mon_name)
    assert Enum.find(alarms_after, &(&1.type == :auto_paused_rules)) == nil

    resolve_deliveries = TestTransport.delivered_notifications()
    assert length(resolve_deliveries) > length(deliveries)
    last_resolve = List.last(resolve_deliveries)
    assert last_resolve.endpoint == sub.endpoint
    assert byte_size(last_resolve.body) > 0
  end

  test "detects feed in backoff and honors cooldown window", %{
    mon_name: mon_name
  } do
    future =
      DateTime.utc_now()
      |> DateTime.add(1800, :second)
      |> DateTime.truncate(:second)

    feed =
      Repo.insert!(%Feed{
        name: "Failing Provider",
        slug: "failing-#{System.unique_integer([:positive])}",
        url: "https://example.com/fail",
        is_active: true,
        backoff_until: future,
        last_error_status: 500
      })

    alarms = HealthMonitor.check_now(mon_name)
    feed_alarm = Enum.find(alarms, &(&1.type == :feed_backoff))
    assert feed_alarm != nil
    assert feed_alarm.title =~ "Feed Ingestion Backoff"

    initial_deliveries_count = length(TestTransport.delivered_notifications())
    assert initial_deliveries_count >= 1

    # Immediate second check within cooldown window must NOT spam another push
    HealthMonitor.check_now(mon_name)
    assert length(TestTransport.delivered_notifications()) == initial_deliveries_count

    Repo.delete!(feed)
  end

  test "NAS backup disconnection is NOT treated as an anomaly alarm", %{
    mon_name: mon_name
  } do
    # Ensure no feeds/rules are failing
    alarms = HealthMonitor.check_now(mon_name)
    nas_alarm = Enum.find(alarms, fn a -> a.type in [:nas_disconnected, :backup_disconnected] end)
    assert nas_alarm == nil
  end
end
