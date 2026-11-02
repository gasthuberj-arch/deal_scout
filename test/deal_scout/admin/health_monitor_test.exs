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

  describe "swap alarm evaluation" do
    defp base_metrics do
      %{
        memory: %{
          beam_total_mb: 150.0,
          beam_usage_pct: 29.3,
          swap_total_mb: 512.0,
          swap_used_mb: 0.0,
          swap_free_mb: 512.0,
          swap_usage_pct: 0.0,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 250.0
        },
        storage: %{
          wal_bytes: 10_000_000
        }
      }
    end

    test "cold swap usage with healthy available RAM does not trigger an alarm (live profile)" do
      # Exactly matching the live production profile: 122.7 MB used / 512 MB swap (24%), 245.9 MB RAM available
      metrics =
        put_in(base_metrics(), [:memory], %{
          beam_total_mb: 158.0,
          beam_usage_pct: 30.8,
          swap_total_mb: 512.0,
          swap_used_mb: 122.7,
          swap_free_mb: 389.3,
          swap_usage_pct: 24.0,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 245.9
        })

      anomalies = HealthMonitor.evaluate_anomalies(metrics)
      assert Enum.find(anomalies, &(&1.type == :high_swap)) == nil
    end

    test "critical swap exhaustion triggers critical alarm" do
      metrics =
        put_in(base_metrics(), [:memory], %{
          beam_total_mb: 350.0,
          beam_usage_pct: 68.3,
          swap_total_mb: 512.0,
          swap_used_mb: 450.0,
          swap_free_mb: 62.0,
          swap_usage_pct: 87.9,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 120.0
        })

      anomalies = HealthMonitor.evaluate_anomalies(metrics)
      swap_alarm = Enum.find(anomalies, &(&1.type == :high_swap))

      assert swap_alarm != nil
      assert swap_alarm.severity == :critical
      assert swap_alarm.title =~ "Swap Space Critical"
      assert swap_alarm.message =~ "87.9% utilized"
    end

    test "dual memory starvation (elevated swap + depleted RAM) triggers warning alarm" do
      metrics =
        put_in(base_metrics(), [:memory], %{
          beam_total_mb: 320.0,
          beam_usage_pct: 62.5,
          swap_total_mb: 512.0,
          swap_used_mb: 280.0,
          swap_free_mb: 232.0,
          swap_usage_pct: 54.7,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 35.0
        })

      anomalies = HealthMonitor.evaluate_anomalies(metrics)
      swap_alarm = Enum.find(anomalies, &(&1.type == :high_swap))

      assert swap_alarm != nil
      assert swap_alarm.severity == :warning
      assert swap_alarm.title =~ "Memory Starvation"
      assert swap_alarm.message =~ "Physical RAM is depleted"
    end

    test "total RAM exhaustion (avail_ram == 0.0) with elevated swap triggers starvation alarm" do
      metrics =
        put_in(base_metrics(), [:memory], %{
          beam_total_mb: 320.0,
          beam_usage_pct: 62.5,
          swap_total_mb: 512.0,
          swap_used_mb: 280.0,
          swap_free_mb: 232.0,
          swap_usage_pct: 54.7,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 0.0
        })

      anomalies = HealthMonitor.evaluate_anomalies(metrics)
      swap_alarm = Enum.find(anomalies, &(&1.type == :high_swap))

      assert swap_alarm != nil
      assert swap_alarm.severity == :warning
      assert swap_alarm.title =~ "Memory Starvation"
      assert swap_alarm.message =~ "Physical RAM is depleted"
    end

    test "swap disabled (swap_total == 0) produces no swap alarm" do
      metrics =
        put_in(base_metrics(), [:memory], %{
          beam_total_mb: 200.0,
          beam_usage_pct: 39.0,
          swap_total_mb: 0.0,
          swap_used_mb: 0.0,
          swap_free_mb: 0.0,
          swap_usage_pct: 0.0,
          host_mem_total_mb: 470.0,
          host_mem_available_mb: 200.0
        })

      anomalies = HealthMonitor.evaluate_anomalies(metrics)
      assert Enum.find(anomalies, &(&1.type == :high_swap)) == nil
    end
  end
end
