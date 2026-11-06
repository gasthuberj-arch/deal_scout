defmodule DealScout.Admin.HealthMonitor do
  @moduledoc """
  Lightweight background supervisor worker that monitors production invariants
  every 60 seconds (RAM headroom, swap pressure, SQLite WAL bloat, feed backoffs,
  and alert budget auto-pauses).

  Dispatches Web Push notifications to all administrator devices when anomalies
  are detected, throttles repeat notifications with a 60-minute cooldown,
  and sends an auto-resolution notification when healthy conditions return.
  """

  use GenServer
  require Logger
  import Ecto.Query, warn: false

  alias DealScout.Repo
  alias DealScout.Accounts
  alias DealScout.Analytics
  alias DealScout.Notifications
  alias DealScout.Admin.SystemMetrics
  alias DealScout.Feeds.Feed
  alias DealScout.Alerts

  @default_interval_ms 60_000
  @default_cooldown_ms 3_600_000

  # Memory & Storage Invariant Thresholds
  @ram_limit_mb 400.0
  @swap_critical_pct 80.0
  @swap_min_free_mb 64.0
  @swap_starvation_pct 50.0
  @min_available_ram_mb 50.0
  @wal_limit_bytes 250 * 1024 * 1024

  # ============================================================================
  # Public Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a list of currently active alarms.
  """
  def list_active_alarms(server \\ __MODULE__) do
    if GenServer.whereis(server) do
      GenServer.call(server, :list_active_alarms)
    else
      []
    end
  catch
    :exit, _ -> []
  end

  @doc """
  Triggers an immediate synchronous check of all invariants and returns the updated alarms list.
  Useful for tests and manual console refreshes.
  """
  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check_now)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)

    skip_timer =
      Keyword.get(
        opts,
        :skip_timer,
        Application.get_env(:deal_scout, :skip_health_monitor_timer, false)
      )

    state = %{
      interval_ms: interval_ms,
      cooldown_ms: cooldown_ms,
      alarms: %{},
      timer_ref: nil
    }

    state =
      if skip_timer do
        state
      else
        schedule_check(state)
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:list_active_alarms, _from, state) do
    active_list =
      state.alarms
      |> Map.values()
      |> Enum.sort_by(& &1.detected_at, {:desc, DateTime})

    {:reply, active_list, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    new_state = run_health_check(state)

    active_list =
      new_state.alarms
      |> Map.values()
      |> Enum.sort_by(& &1.detected_at, {:desc, DateTime})

    {:reply, active_list, new_state}
  end

  @impl true
  def handle_info(:check_health, state) do
    new_state =
      state
      |> run_health_check()
      |> schedule_check()

    {:noreply, new_state}
  end

  # ============================================================================
  # Health Invariant Evaluation
  # ============================================================================

  defp run_health_check(state) do
    now = DateTime.utc_now()
    metrics = SystemMetrics.get_metrics()
    detected_anomalies = evaluate_anomalies(metrics)

    # 1. Process new or persistent anomalies
    updated_alarms =
      Enum.reduce(detected_anomalies, state.alarms, fn anomaly, acc_alarms ->
        key = anomaly.type

        case Map.get(acc_alarms, key) do
          nil ->
            # Fresh anomaly: record and notify immediately
            new_record =
              Map.merge(anomaly, %{
                detected_at: now,
                last_notified_at: now
              })

            dispatch_admin_push(new_record, :alarm)
            broadcast_alarm(new_record, :triggered)

            Map.put(acc_alarms, key, new_record)

          existing ->
            # Anomaly is ongoing: check if cooldown has elapsed
            diff_ms = DateTime.diff(now, existing.last_notified_at, :millisecond)

            if diff_ms >= state.cooldown_ms do
              updated_record = %{existing | last_notified_at: now, message: anomaly.message}
              dispatch_admin_push(updated_record, :reminder)
              Map.put(acc_alarms, key, updated_record)
            else
              # Still within cooldown window; keep previous last_notified_at
              updated_record = %{existing | message: anomaly.message}
              Map.put(acc_alarms, key, updated_record)
            end
        end
      end)

    # 2. Check for resolved anomalies (were active previously, but no longer detected)
    detected_keys = MapSet.new(Enum.map(detected_anomalies, & &1.type))

    final_alarms =
      Enum.reduce(state.alarms, updated_alarms, fn {key, existing_alarm}, acc_alarms ->
        if MapSet.member?(detected_keys, key) do
          acc_alarms
        else
          # Anomaly has resolved!
          dispatch_admin_push(existing_alarm, :resolved)
          broadcast_alarm(existing_alarm, :resolved)
          Map.delete(acc_alarms, key)
        end
      end)

    %{state | alarms: final_alarms}
  end

  @doc false
  def evaluate_anomalies(metrics) do
    anomalies = []

    # 1. BEAM RAM pressure (> 400 MB of 512 MB micro-VM limit)
    anomalies =
      if metrics.memory.beam_total_mb > @ram_limit_mb do
        [
          %{
            type: :high_ram,
            severity: :critical,
            title: "High RAM Usage (#{metrics.memory.beam_total_mb} MB)",
            message:
              "BEAM memory is #{metrics.memory.beam_total_mb} MB (#{metrics.memory.beam_usage_pct}% of the 512 MB container limit)."
          }
          | anomalies
        ]
      else
        anomalies
      end

    # 2. Swap pressure / distress evaluation
    anomalies =
      case evaluate_swap_anomaly(metrics.memory) do
        nil -> anomalies
        anomaly -> [anomaly | anomalies]
      end

    # 3. SQLite WAL bloat (> 250 MB)
    anomalies =
      if metrics.storage.wal_bytes > @wal_limit_bytes do
        wal_mb = Float.round(metrics.storage.wal_bytes / (1024 * 1024), 1)

        [
          %{
            type: :wal_bloat,
            severity: :warning,
            title: "SQLite WAL Bloat (#{wal_mb} MB)",
            message:
              "SQLite WAL file is #{wal_mb} MB (exceeds 250 MB threshold without checkpointing)."
          }
          | anomalies
        ]
      else
        anomalies
      end

    # 4. Feed poller disruption (active feeds stuck in backoff)
    now = DateTime.utc_now()

    backed_off_feeds =
      from(f in Feed,
        where: f.is_active == true and not is_nil(f.backoff_until) and f.backoff_until > ^now,
        select: %{id: f.id, name: f.name, last_error_status: f.last_error_status}
      )
      |> Repo.all()

    anomalies =
      if backed_off_feeds != [] do
        names = Enum.map_join(backed_off_feeds, ", ", & &1.name)

        [
          %{
            type: :feed_backoff,
            severity: :warning,
            title: "Feed Ingestion Backoff (#{length(backed_off_feeds)} feeds)",
            message: "#{length(backed_off_feeds)} feed(s) in error backoff: #{names}."
          }
          | anomalies
        ]
      else
        anomalies
      end

    # 5. Alert rule compute budget auto-pauses (> 0)
    auto_paused = Alerts.list_auto_paused_rules()

    anomalies =
      if auto_paused != [] do
        [
          %{
            type: :auto_paused_rules,
            severity: :warning,
            title: "Alert Rules Auto-Paused (#{length(auto_paused)})",
            message:
              "#{length(auto_paused)} alert rule(s) exceeded the 30ms/deal evaluation budget and were paused."
          }
          | anomalies
        ]
      else
        anomalies
      end

    # 6. Web push gateway failure or complete receipt blackout
    # Differentiates healthy client sleep/doze from actual gateway infrastructure breakdown.
    push_metrics = Analytics.get_delivery_metrics(24)
    gateway_errors = push_metrics.http_error + push_metrics.network_error

    anomalies =
      cond do
        gateway_errors > 0 ->
          [
            %{
              type: :push_delivery_degraded,
              severity: :critical,
              title: "Push Gateway Errors (#{gateway_errors} failures)",
              message:
                "Web Push gateway reported #{push_metrics.http_error} HTTP error(s) and #{push_metrics.network_error} network error(s) in the last 24h."
            }
            | anomalies
          ]

        push_metrics.delivered_to_gateway >= 10 and push_metrics.device_confirmed == 0 ->
          [
            %{
              type: :push_delivery_degraded,
              severity: :warning,
              title: "Zero Push Receipts (0 confirmed of #{push_metrics.delivered_to_gateway})",
              message:
                "#{push_metrics.delivered_to_gateway} notifications were delivered to the push gateway, but 0 device receipt pings were confirmed. Browser Service Worker or receipt endpoint may be blocked."
            }
            | anomalies
          ]

        true ->
          anomalies
      end

    Enum.reverse(anomalies)
  end

  defp evaluate_swap_anomaly(memory) do
    swap_total = memory.swap_total_mb
    swap_used = memory.swap_used_mb
    swap_free = memory.swap_free_mb
    swap_pct = memory.swap_usage_pct
    avail_ram = memory.host_mem_available_mb

    cond do
      # Swap disabled or unconfigured
      swap_total <= 0 ->
        nil

      # Case 1: Critical swap space exhaustion (near OOM limit)
      swap_pct >= @swap_critical_pct or swap_free < @swap_min_free_mb ->
        %{
          type: :high_swap,
          severity: :critical,
          title: "Swap Space Critical (#{swap_used} MB)",
          message:
            "Swap space is #{swap_pct}% utilized (#{swap_used} MB / #{swap_total} MB, #{swap_free} MB remaining). Risk of out-of-memory crash."
        }

      # Case 2: Memory starvation: elevated swap combined with depleted physical RAM
      swap_pct >= @swap_starvation_pct and is_number(avail_ram) and
          avail_ram < @min_available_ram_mb ->
        %{
          type: :high_swap,
          severity: :warning,
          title: "Memory Starvation (#{swap_used} MB swap, #{avail_ram} MB RAM free)",
          message:
            "Physical RAM is depleted (#{avail_ram} MB available) and swap is elevated (#{swap_used} MB / #{swap_total} MB, #{swap_pct}%)."
        }

      # Normal: cold pages in swap with sufficient RAM and swap headroom
      true ->
        nil
    end
  end

  # ============================================================================
  # Notifications & PubSub
  # ============================================================================

  defp dispatch_admin_push(%{type: :push_delivery_degraded}, _action) do
    # Operational health alarms about push delivery degradation must never dispatch via push
    # to prevent recursive, self-reinforcing feedback loops when admin devices are sleeping/offline.
    :ok
  end

  defp dispatch_admin_push(alarm, action) do
    admin_users = Accounts.list_admin_users()

    {title, body} =
      case action do
        :alarm ->
          {"🚨 Alert: " <> alarm.title, alarm.message}

        :reminder ->
          {"⚠️ Reminder: " <> alarm.title, alarm.message}

        :resolved ->
          {"✅ Resolved: " <> alarm.title, "Metric has returned to normal operational limits."}
      end

    payload = %{
      title: title,
      body: body,
      url: "/admin/system",
      tag: "admin-health-#{alarm.type}",
      icon: "/images/icon-192.png"
    }

    Enum.each(admin_users, fn admin ->
      Notifications.deliver_push_to_user(admin.id, payload)
    end)
  rescue
    e ->
      Logger.error("[HealthMonitor] Failed dispatching admin push: #{Exception.message(e)}")
      :error
  end

  defp broadcast_alarm(alarm, event_type) do
    DealScoutWeb.Endpoint.broadcast("admin:system", "health_alarm_#{event_type}", alarm)
  rescue
    _ -> :ok
  end

  defp schedule_check(state) do
    ref = Process.send_after(self(), :check_health, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
