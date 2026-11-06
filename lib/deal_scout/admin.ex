defmodule DealScout.Admin do
  @moduledoc """
  The Admin context module for DealScout.

  Provides a deep, unified interface for operational health monitoring,
  system metrics aggregation, SQLite storage maintenance, and safe recovery operations.
  Replaces scattered view-layer coordination with cohesive domain operations.
  """

  alias DealScout.Admin.{HealthMonitor, SystemMetrics}
  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Analytics
  alias DealScout.Backup
  alias DealScout.Feeds.Ebay
  alias DealScout.Feeds.Poller

  @doc """
  Gathers the consolidated system operational overview in a single call.
  Combines host memory/swap, SQLite storage, feed statuses, backup lag,
  active alarms, push delivery metrics, and slow/paused alert rules.
  """
  def get_system_overview do
    active_alarms = list_streamable_alarms()

    %{
      system_metrics: SystemMetrics.get_metrics(),
      active_alarms: active_alarms,
      active_alarms_count: length(active_alarms),
      ops: Analytics.get_system_ops_stats(),
      backup: Backup.get_status(),
      auto_paused_rules: Alerts.list_auto_paused_rules(),
      slowest_rules: Alerts.list_slowest_rules(10),
      push_metrics: Analytics.get_delivery_metrics(24),
      ebay_status: get_ebay_status()
    }
  end

  @doc """
  Lists all currently active health alarms with formatted streamable IDs.
  """
  def list_streamable_alarms do
    HealthMonitor.list_active_alarms()
    |> Enum.map(fn alarm ->
      Map.put(alarm, :id, to_string(alarm.type))
    end)
  end

  @doc """
  Lists active alarms directly from the HealthMonitor worker.
  """
  def list_active_alarms do
    HealthMonitor.list_active_alarms()
  end

  @doc """
  Triggers a synchronous check of all operational invariants.
  """
  def check_health_now do
    HealthMonitor.check_now()
  end

  # ============================================================================
  # Recovery & Maintenance Operations
  # ============================================================================

  @doc """
  Executes a non-blocking SQLite PASSIVE checkpoint.
  """
  def safe_checkpoint do
    SystemMetrics.safe_wal_checkpoint()
  end

  @doc """
  Reclaims idle SQLite pager memory and triggers garbage collection on high-memory BEAM processes.
  """
  def safe_reclaim_memory do
    SystemMetrics.safe_reclaim_memory()
  end

  @doc """
  Refreshes the StreamCache ETS table in-place without SQLite read stampedes.
  """
  def safe_refresh_cache do
    SystemMetrics.safe_refresh_stream_cache()
  end

  @doc """
  Resets error backoff for a feed and triggers an immediate background poll.
  """
  def safe_retry_feed(feed_id) do
    case SystemMetrics.safe_retry_feed(feed_id) do
      {:ok, feed} ->
        Poller.poll_now()
        {:ok, feed}

      other ->
        other
    end
  end

  @doc """
  Triggers an immediate background poll cycle for all active RSS feeds.
  """
  def trigger_feed_poll do
    Poller.poll_now()
    :ok
  end

  @doc """
  Triggers an immediate eBay Sofort-Kauf poll if configured and enabled.
  """
  def trigger_ebay_poll do
    if Ebay.configured?() and Ebay.enabled?() do
      Ebay.poll_now()
      {:ok, :triggered}
    else
      {:error, :not_configured}
    end
  end

  # ============================================================================
  # Rule Management
  # ============================================================================

  @doc """
  Resumes an alert rule (accepts an `%AlertRule{}` struct or string/integer ID).
  """
  def resume_rule(%AlertRule{} = rule), do: Alerts.resume_rule(rule)

  def resume_rule(id) when is_binary(id) or is_integer(id) do
    rule = Alerts.get_alert_rule!(id)
    Alerts.resume_rule(rule)
  end

  @doc """
  Pauses an alert rule (accepts an `%AlertRule{}` struct or string/integer ID).
  """
  def pause_rule(
        rule_or_id,
        reason \\ "Manually paused by administrator"
      )

  def pause_rule(%AlertRule{} = rule, reason) do
    Alerts.pause_rule(rule, reason)
  end

  def pause_rule(id, reason) when is_binary(id) or is_integer(id) do
    rule = Alerts.get_alert_rule!(id)
    Alerts.pause_rule(rule, reason)
  end

  # ============================================================================
  # Device Delivery Analytics
  # ============================================================================

  @doc """
  Fetches device delivery metrics filtered by mode (`"all"` or `"pending_only"`).
  """
  def list_device_delivery_metrics(filter \\ "all") do
    all_devices = Analytics.get_device_delivery_metrics(:all, 24)
    pending_count = Enum.count(all_devices, &(&1.pending_count > 0))

    filtered =
      case filter do
        "pending_only" -> Enum.filter(all_devices, &(&1.pending_count > 0))
        _ -> all_devices
      end

    %{
      devices: filtered,
      all_count: length(all_devices),
      pending_count: pending_count
    }
  end

  defp get_ebay_status do
    %{
      configured: Ebay.configured?(),
      enabled: Ebay.enabled?(),
      marketplace: Ebay.marketplace_id(),
      seen_items: Ebay.seen_cache_size(),
      poll_interval: Ebay.poll_interval_seconds()
    }
  end
end
