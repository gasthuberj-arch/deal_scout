defmodule DealScout.Notifications.PushAnalyticsTest do
  use DealScout.DataCase, async: false

  alias DealScout.Repo
  alias DealScout.Accounts.User
  alias DealScout.Notifications
  alias DealScout.Notifications.PushDeliveryLog
  alias DealScout.Admin.HealthMonitor

  setup do
    Notifications.invalidate_delivery_metrics_cache(24)

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

    metrics = Notifications.compute_delivery_metrics(24)

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

    Notifications.invalidate_delivery_metrics_cache(24)

    # Warmup query
    _ = Notifications.compute_delivery_metrics(24)

    # Measure single-pass SQLite execution time
    {query_time_us, computed} =
      :timer.tc(fn ->
        Notifications.compute_delivery_metrics(24)
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
    _ = Notifications.get_delivery_metrics(24)

    {cache_time_us, cached} =
      :timer.tc(fn ->
        Notifications.get_delivery_metrics(24)
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

  test "HealthMonitor triggers :push_delivery_degraded alarm when confirmation rate < 50%", %{
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_usec = DateTime.utc_now()

    # Insert 10 delivered logs, with only 2 confirmed (20% confirmation rate)
    for i <- 1..10 do
      confirmed? = i <= 2

      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        tracking_id: "alarm-trk-#{System.unique_integer([:positive])}-#{i}",
        status: "delivered",
        gateway_duration_ms: 100,
        client_delay_ms: if(confirmed?, do: 300, else: nil),
        client_received_at: if(confirmed?, do: now_usec, else: nil),
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
    assert push_alarm.title =~ "Push Delivery Degraded (20.0% confirmed)"
    assert push_alarm.message =~ "Only 2 of 10 push notifications were confirmed"
  end
end
