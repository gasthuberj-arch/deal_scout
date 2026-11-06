defmodule DealScout.Analytics.PushAnalyticsTest do
  use DealScout.DataCase, async: false

  alias DealScout.Repo
  alias DealScout.Accounts.{Scope, User}
  alias DealScout.Analytics
  alias DealScout.Notifications
  alias DealScout.Notifications.{PushDeliveryLog, PushSubscription}
  alias DealScout.Admin.HealthMonitor

  setup do
    Analytics.invalidate_delivery_metrics_cache(24)
    Analytics.invalidate_device_metrics_cache(24)

    user =
      Repo.insert!(%User{
        email: "analytics-user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "dummy_password"
      })

    %{user: user}
  end

  test "compute_delivery_metrics/1 accurately aggregates rates and latencies", %{user: user} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_usec = DateTime.utc_now()

    # 1. Delivered + confirmed
    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "test-trk-1",
      status: "delivered",
      gateway_duration_ms: 120,
      client_delay_ms: 350,
      client_received_at: now_usec,
      inserted_at: now
    })

    # 2. Delivered + pending receipt
    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "test-trk-2",
      status: "delivered",
      gateway_duration_ms: 180,
      client_delay_ms: nil,
      client_received_at: nil,
      inserted_at: now
    })

    # 3. Expired (410)
    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "test-trk-3",
      status: "expired",
      gateway_duration_ms: 90,
      inserted_at: now
    })

    # 4. Old log outside 24h window (should not be counted)
    two_days_ago = DateTime.add(now, -48 * 3600, :second)
    two_days_ago_usec = DateTime.add(now_usec, -48 * 3600, :second)

    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "test-trk-old",
      status: "delivered",
      gateway_duration_ms: 50,
      client_delay_ms: 200,
      client_received_at: two_days_ago_usec,
      inserted_at: two_days_ago
    })

    metrics = Analytics.compute_delivery_metrics(24)

    assert metrics.total == 3
    assert metrics.delivered_to_gateway == 2
    assert metrics.device_confirmed == 1
    assert metrics.pending_confirmation == 1
    assert metrics.expired == 1
    # 1 confirmed out of 2 delivered = 50.0%
    assert metrics.confirmation_rate_pct == 50.0
    assert metrics.avg_client_delay_ms == 350
    assert metrics.avg_gateway_ms == 130
  end

  test "performance proof: single-pass query is fast on 2,000 logs and ETS cache is sub-millisecond",
       %{user: user} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Seed 2,000 logs (1,000 in last 24h, 1,000 older)
    entries =
      Enum.map(1..2000, fn i ->
        age = if rem(i, 2) == 0, do: :rand.uniform(80_000), else: 90_000 + :rand.uniform(400_000)
        ins = DateTime.add(now, -age, :second)
        confirmed? = rem(i, 3) != 0

        client_rec =
          if confirmed? do
            DateTime.add(ins, :rand.uniform(1_500_000), :microsecond)
          else
            nil
          end

        %{
          user_id: user.id,
          tracking_id: "perf-#{System.unique_integer([:positive])}-#{i}",
          status: if(rem(i, 15) == 0, do: "expired", else: "delivered"),
          endpoint: "https://fcm.googleapis.com/fcm/send/perf",
          gateway_duration_ms: :rand.uniform(250),
          client_delay_ms: if(confirmed?, do: :rand.uniform(1500), else: nil),
          client_received_at: client_rec,
          inserted_at: ins,
          updated_at: ins
        }
      end)

    Enum.chunk_every(entries, 500)
    |> Enum.each(&Repo.insert_all(PushDeliveryLog, &1))

    Analytics.invalidate_delivery_metrics_cache(24)

    # Warmup query
    _ = Analytics.compute_delivery_metrics(24)

    # Measure single-pass SQLite execution time
    {query_time_us, computed} =
      :timer.tc(fn ->
        Analytics.compute_delivery_metrics(24)
      end)

    query_ms = query_time_us / 1000

    IO.puts(
      "\n[PERF TEST] SQLite single-pass query on 2,000 rows took #{Float.round(query_ms, 2)}ms"
    )

    assert is_map(computed)
    assert computed.delivered_to_gateway > 0
    # Must comfortably execute within 50ms on shared test runner
    assert query_ms < 50.0

    # Measure ETS cached access time
    # Prime cache
    _ = Analytics.get_delivery_metrics(24)

    {cache_time_us, cached} =
      :timer.tc(fn ->
        Analytics.get_delivery_metrics(24)
      end)

    cache_ms = cache_time_us / 1000

    IO.puts(
      "[PERF TEST] ETS cached lookup took #{Float.round(cache_ms, 3)}ms (#{cache_time_us}µs)"
    )

    assert cached.total == computed.total
    # ETS cache must return in under 1ms (typically 2-10 microseconds)
    assert cache_ms < 1.0
  end

  test "prune_push_delivery_logs/1 purges records older than specified days", %{user: user} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    eight_days_ago = DateTime.add(now, -8 * 86_400, :second)
    six_days_ago = DateTime.add(now, -6 * 86_400, :second)

    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "old-to-prune",
      status: "delivered",
      inserted_at: eight_days_ago
    })

    Repo.insert!(%PushDeliveryLog{
      user_id: user.id,
      tracking_id: "recent-to-keep",
      status: "delivered",
      inserted_at: six_days_ago
    })

    assert {1, nil} = Notifications.prune_push_delivery_logs(7)

    assert Repo.get_by(PushDeliveryLog, tracking_id: "old-to-prune") == nil
    assert Repo.get_by(PushDeliveryLog, tracking_id: "recent-to-keep") != nil
  end

  test "HealthMonitor triggers :push_delivery_degraded alarm when zero receipts confirmed for 10+ deliveries",
       %{
         user: user
       } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Insert 10 delivered logs, with 0 confirmed (total receipt blackout)
    for i <- 1..10 do
      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        tracking_id: "alarm-trk-#{System.unique_integer([:positive])}-#{i}",
        status: "delivered",
        gateway_duration_ms: 100,
        client_delay_ms: nil,
        client_received_at: nil,
        inserted_at: now
      })
    end

    mon_name = :"health_mon_push_#{System.unique_integer([:positive])}"

    mon_pid =
      start_supervised!({HealthMonitor, [name: mon_name, skip_timer: true, cooldown_ms: 100]})

    Ecto.Adapters.SQL.Sandbox.allow(DealScout.Repo, self(), mon_pid)

    alarms = HealthMonitor.check_now(mon_name)
    push_alarm = Enum.find(alarms, &(&1.type == :push_delivery_degraded))

    assert push_alarm != nil
    assert push_alarm.severity == :warning
    assert push_alarm.title =~ "Zero Push Receipts (0 confirmed of 10)"
    assert push_alarm.message =~ "0 device receipt pings were confirmed"
  end

  test "parse_user_agent/1 formats common browser and platform combinations" do
    assert Analytics.parse_user_agent(
             "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Mobile/15E148 Safari/604.1"
           ) == "Safari on iOS"

    assert Analytics.parse_user_agent(
             "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.6312.80 Mobile Safari/537.36"
           ) == "Chrome on Android"

    assert Analytics.parse_user_agent(
             "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:124.0) Gecko/20100101 Firefox/124.0"
           ) == "Firefox on macOS"

    assert Analytics.parse_user_agent(
             "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.2420.65"
           ) == "Edge on Windows"

    assert Analytics.parse_user_agent(nil) == "Web Browser"
    assert Analytics.parse_user_agent("") == "Web Browser"
  end

  test "update_push_subscription_device_name/3 allows updating device nickname", %{user: user} do
    scope = %Scope{user: user}

    sub =
      Repo.insert!(%PushSubscription{
        user_id: user.id,
        endpoint: "https://push.example.com/sub-rename-#{System.unique_integer([:positive])}",
        p256dh: "key_p256dh",
        auth: "key_auth",
        device_name: "Apple iPhone"
      })

    assert {:ok, updated} =
             Notifications.update_push_subscription_device_name(scope, sub.id, "My Work iPhone")

    assert updated.device_name == "My Work iPhone"

    other_user =
      Repo.insert!(%User{
        email: "other-user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "dummy_password"
      })

    other_scope = %Scope{user: other_user}

    assert {:error, :not_found} =
             Notifications.update_push_subscription_device_name(other_scope, sub.id, "Hacked")
  end

  test "get_device_delivery_metrics/2 aggregates pending confirms and sorts by pending count", %{
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_usec = DateTime.utc_now()

    sub_phone =
      Repo.insert!(%PushSubscription{
        user_id: user.id,
        endpoint: "https://push.example.com/phone-#{System.unique_integer([:positive])}",
        p256dh: "key_p256dh",
        auth: "key_auth",
        device_name: "Personal iPhone",
        user_agent:
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1"
      })

    sub_laptop =
      Repo.insert!(%PushSubscription{
        user_id: user.id,
        endpoint: "https://push.example.com/laptop-#{System.unique_integer([:positive])}",
        p256dh: "key_p256dh",
        auth: "key_auth",
        device_name: "MacBook Pro",
        user_agent:
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/123.0 Safari/537.36"
      })

    # Laptop: 2 sent, 2 confirmed (0 pending)
    for i <- 1..2 do
      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        push_subscription_id: sub_laptop.id,
        endpoint: sub_laptop.endpoint,
        tracking_id: "trk-laptop-#{i}-#{System.unique_integer([:positive])}",
        status: "delivered",
        client_received_at: now_usec,
        client_delay_ms: 250,
        inserted_at: now
      })
    end

    # Phone: 3 sent, only 1 confirmed (2 pending confirms!)
    for i <- 1..3 do
      confirmed? = i == 1

      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        push_subscription_id: sub_phone.id,
        endpoint: sub_phone.endpoint,
        tracking_id: "trk-phone-#{i}-#{System.unique_integer([:positive])}",
        status: "delivered",
        client_received_at: if(confirmed?, do: now_usec, else: nil),
        client_delay_ms: if(confirmed?, do: 310, else: nil),
        inserted_at: now
      })
    end

    # Query global device metrics (admin mode)
    metrics = Analytics.get_device_delivery_metrics(nil, 24)

    # Phone has 2 pending, Laptop has 0 pending. Phone must be sorted first!
    phone_metric = Enum.find(metrics, &(&1.subscription_id == sub_phone.id))
    laptop_metric = Enum.find(metrics, &(&1.subscription_id == sub_laptop.id))

    assert phone_metric != nil
    assert laptop_metric != nil

    assert phone_metric.sent_count == 3
    assert phone_metric.confirmed_count == 1
    assert phone_metric.pending_count == 2
    assert phone_metric.browser_info == "Safari on iOS"

    assert laptop_metric.sent_count == 2
    assert laptop_metric.confirmed_count == 2
    assert laptop_metric.pending_count == 0
    assert laptop_metric.browser_info == "Chrome on macOS"

    # Sorted with pending first
    assert hd(metrics).subscription_id == sub_phone.id

    # Query scoped to user
    scope = %Scope{user: user}
    user_metrics = Analytics.get_device_delivery_metrics(scope, 24)
    assert length(user_metrics) == 2
    assert hd(user_metrics).subscription_id == sub_phone.id
  end

  test "get_device_delivery_metrics/2 performance benchmark with composite index and ETS caching",
       %{
         user: user
       } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_usec = DateTime.utc_now()

    # Create 5 distinct subscriptions
    subs =
      for i <- 1..5 do
        Repo.insert!(%PushSubscription{
          user_id: user.id,
          endpoint:
            "https://push.example.com/perf-dev-#{i}-#{System.unique_integer([:positive])}",
          p256dh: "key_p256dh",
          auth: "key_auth",
          device_name: "Device ##{i}",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) Safari/604.1"
        })
      end

    # Insert 1,500 logs distributed across the 5 devices
    sub_ids = Enum.map(subs, & &1.id)

    logs =
      Enum.map(1..1500, fn i ->
        sub_id = Enum.at(sub_ids, rem(i, 5))
        confirmed? = rem(i, 3) == 0

        %{
          user_id: user.id,
          push_subscription_id: sub_id,
          endpoint: "https://push.example.com/perf-endpoint",
          tracking_id: "perf-dev-trk-#{System.unique_integer([:positive])}-#{i}",
          status: "delivered",
          client_received_at: if(confirmed?, do: now_usec, else: nil),
          client_delay_ms: if(confirmed?, do: 200, else: nil),
          gateway_duration_ms: 100,
          inserted_at: now,
          updated_at: now
        }
      end)

    {1500, nil} = Repo.insert_all(PushDeliveryLog, logs)

    # Invalidate cache
    Analytics.invalidate_device_metrics_cache(24)

    # Warmup query
    _ = Analytics.get_device_delivery_metrics(nil, 24)
    Analytics.invalidate_device_metrics_cache(24)

    # Measure uncached single-pass SQLite execution time on 1,500+ records
    {query_time_us, computed} =
      :timer.tc(fn ->
        Analytics.get_device_delivery_metrics(nil, 24)
      end)

    query_ms = query_time_us / 1000

    assert length(computed) >= 5

    # Bounded query performance: must comfortably execute within 250ms even on slow virtualized runners
    assert query_ms < 250.0

    # Measure ETS cached access time
    {cache_time_us, cached} =
      :timer.tc(fn ->
        Analytics.get_device_delivery_metrics(nil, 24)
      end)

    cache_ms = cache_time_us / 1000

    assert length(cached) == length(computed)
    # ETS cache should return in low milliseconds
    assert cache_ms < 5.0
  end
end
