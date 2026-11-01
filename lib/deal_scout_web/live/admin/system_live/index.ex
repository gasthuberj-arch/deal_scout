defmodule DealScoutWeb.Admin.SystemLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Analytics
  alias DealScout.Feeds.Poller
  alias DealScout.Alerts
  alias DealScout.Admin.{SystemMetrics, HealthMonitor}
  alias DealScoutWeb.PushNotificationHandler

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DealScoutWeb.Endpoint.subscribe("deals:presence")
      DealScoutWeb.Endpoint.subscribe("admin:system")
      DealScout.Backup.subscribe()
    end

    ops = Analytics.get_system_ops_stats()
    backup_status = DealScout.Backup.get_status()
    auto_paused_rules = Alerts.list_auto_paused_rules()
    slowest_rules = Alerts.list_slowest_rules(10)
    system_metrics = SystemMetrics.get_metrics()
    active_alarms = fetch_streamable_alarms()

    socket =
      socket
      |> PushNotificationHandler.init_push_assigns()
      |> assign(:page_title, "Admin System & Operational Health")
      |> assign(:ops, ops)
      |> assign(:backup, backup_status)
      |> assign(:auto_paused_rules, auto_paused_rules)
      |> assign(:slowest_rules, slowest_rules)
      |> assign(:ebay_status, get_ebay_status())
      |> assign(:system_metrics, system_metrics)
      |> assign(:active_alarms_count, length(active_alarms))
      |> stream(:active_alarms, active_alarms)

    {:ok, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "deals:presence"}, socket) do
    ops = Analytics.get_system_ops_stats()
    {:noreply, assign(socket, :ops, ops)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "admin:system"}, socket) do
    active_alarms = fetch_streamable_alarms()

    {:noreply,
     socket
     |> assign(:system_metrics, SystemMetrics.get_metrics())
     |> assign(:active_alarms_count, length(active_alarms))
     |> stream(:active_alarms, active_alarms, reset: true)}
  end

  @impl true
  def handle_info({:new_backup_file, _path, _full, _size, _sha}, socket) do
    backup_status = DealScout.Backup.get_status()
    {:noreply, assign(socket, :backup, backup_status)}
  end

  # ============================================================================
  # Event Handlers: Safe Non-Destructive Operations & Alarms
  # ============================================================================

  @impl true
  def handle_event("refresh_metrics", _params, socket) do
    ops = Analytics.get_system_ops_stats()
    backup_status = DealScout.Backup.get_status()
    system_metrics = SystemMetrics.get_metrics()
    active_alarms = fetch_streamable_alarms()

    {:noreply,
     socket
     |> assign(:ops, ops)
     |> assign(:backup, backup_status)
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))
     |> assign(:ebay_status, get_ebay_status())
     |> assign(:system_metrics, system_metrics)
     |> assign(:active_alarms_count, length(active_alarms))
     |> stream(:active_alarms, active_alarms, reset: true)
     |> put_flash(:info, "System operations metrics updated.")}
  end

  @impl true
  def handle_event("safe_checkpoint", _params, socket) do
    case SystemMetrics.safe_wal_checkpoint() do
      {:ok, %{status: status, log: log, checkpointed: cp}} ->
        flash_msg =
          case status do
            :sandbox ->
              "SQLite WAL safely verified (PASSIVE; in transaction sandbox)."

            :checkpointed ->
              "SQLite WAL safely checkpointed #{cp} of #{log} frame(s) non-blocking (PASSIVE)."

            :busy ->
              "Checkpoint completed partially; database busy with active reader (#{cp} frames copied)."
          end

        active_alarms = fetch_streamable_alarms()

        {:noreply,
         socket
         |> put_flash(:info, flash_msg)
         |> assign(:system_metrics, SystemMetrics.get_metrics())
         |> assign(:active_alarms_count, length(active_alarms))
         |> stream(:active_alarms, active_alarms, reset: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "WAL checkpoint failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("safe_reclaim_memory", _params, socket) do
    case SystemMetrics.safe_reclaim_memory() do
      {:ok, %{reclaimed_processes: count}} ->
        active_alarms = fetch_streamable_alarms()

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Released SQLite idle pager caches (PRAGMA shrink_memory) and garbage collected #{count} high-memory process(es)."
         )
         |> assign(:system_metrics, SystemMetrics.get_metrics())
         |> assign(:ops, Analytics.get_system_ops_stats())
         |> assign(:active_alarms_count, length(active_alarms))
         |> stream(:active_alarms, active_alarms, reset: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Memory reclamation failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("safe_refresh_cache", _params, socket) do
    case SystemMetrics.safe_refresh_stream_cache() do
      {:ok, :refreshed} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "StreamCache refreshed in-place with zero SQLite read stampedes."
         )
         |> assign(:system_metrics, SystemMetrics.get_metrics())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cache refresh failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("safe_retry_feed", %{"id" => id}, socket) do
    case SystemMetrics.safe_retry_feed(id) do
      {:ok, feed} ->
        DealScout.Feeds.Poller.poll_now()
        active_alarms = fetch_streamable_alarms()

        {:noreply,
         socket
         |> put_flash(:info, "Backoff reset for #{feed.name}; poller cycle triggered.")
         |> assign(:ops, Analytics.get_system_ops_stats())
         |> assign(:active_alarms_count, length(active_alarms))
         |> stream(:active_alarms, active_alarms, reset: true)}

      {:error, :rate_limited, until_dt} ->
        until_str = DateTime.to_iso8601(until_dt) |> String.slice(11..18)

        {:noreply,
         put_flash(
           socket,
           :error,
           "Feed is in remote HTTP 429 rate-limit backoff until #{until_str} UTC. Forcing retry now risks remote domain bans."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not retry feed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("trigger_ebay_poll", _params, socket) do
    if DealScout.Feeds.Ebay.Config.configured?() and DealScout.Feeds.Ebay.Config.enabled?() do
      DealScout.Feeds.Ebay.Poller.poll_now()
      {:noreply, put_flash(socket, :info, "Triggered immediate eBay Sofort-Kauf poll.")}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "eBay integration is not configured. Set EBAY_CLIENT_ID and EBAY_CLIENT_SECRET."
       )}
    end
  end

  @impl true
  def handle_event("trigger_poll", _params, socket) do
    Poller.poll_now()

    {:noreply,
     socket
     |> put_flash(:info, "Triggered immediate background poll for all feeds.")}
  end

  @impl true
  def handle_event("resume_rule", %{"id" => id}, socket) do
    rule = Alerts.get_alert_rule!(id)
    {:ok, _} = Alerts.resume_rule(rule)
    active_alarms = fetch_streamable_alarms()

    {:noreply,
     socket
     |> put_flash(:info, "Alert rule \"#{rule.name}\" resumed successfully.")
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))
     |> assign(:active_alarms_count, length(active_alarms))
     |> stream(:active_alarms, active_alarms, reset: true)}
  end

  @impl true
  def handle_event("pause_rule", %{"id" => id}, socket) do
    rule = Alerts.get_alert_rule!(id)
    {:ok, _} = Alerts.pause_rule(rule, "Manually paused by administrator")
    active_alarms = fetch_streamable_alarms()

    {:noreply,
     socket
     |> put_flash(:info, "Alert rule \"#{rule.name}\" paused.")
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))
     |> assign(:active_alarms_count, length(active_alarms))
     |> stream(:active_alarms, active_alarms, reset: true)}
  end

  # Push Notification delegation
  @impl true
  def handle_event(event, params, socket)
      when event in [
             "push-status",
             "enable_push_notifications",
             "save-push-subscription",
             "open_ios_modal",
             "close_ios_modal",
             "dismiss_push_banner"
           ] do
    case PushNotificationHandler.handle_push_event(event, params, socket) do
      {:handled, updated_socket} -> {:noreply, updated_socket}
      :unhandled -> {:noreply, socket}
    end
  end

  # ============================================================================
  # Template
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <!-- Header -->
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <div class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-error/10 text-error mb-2">
              <.icon name="hero-shield-check" class="size-3.5" />
              <span>Admin Operations Console</span>
            </div>
            <h1 class="text-3xl font-extrabold tracking-tight flex items-center gap-2">
              <span>System & Infrastructure Health</span>
            </h1>
            <p class="text-sm text-base-content/70 mt-1">
              Live concurrent sessions, micro-VM memory/swap limits, SQLite storage health, and feed ingestion states.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2.5">
            <button
              id="trigger-ebay-poll-btn"
              type="button"
              phx-click="trigger_ebay_poll"
              class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl text-xs font-semibold whitespace-nowrap bg-secondary text-secondary-content hover:opacity-90 shadow-xs transition-all cursor-pointer"
            >
              <.icon name="hero-shopping-bag" class="size-4 shrink-0" />
              <span>Poll eBay</span>
            </button>
            <button
              id="trigger-poll-btn"
              type="button"
              phx-click="trigger_poll"
              class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl text-xs font-semibold whitespace-nowrap bg-amber-500/15 text-amber-700 dark:text-amber-300 border border-amber-500/30 hover:bg-amber-500/25 transition-all cursor-pointer"
            >
              <.icon name="hero-arrow-path" class="size-4 shrink-0" />
              <span>Poll Feeds Now</span>
            </button>
            <button
              id="refresh-ops-btn"
              type="button"
              phx-click="refresh_metrics"
              class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl text-xs font-semibold whitespace-nowrap bg-primary text-primary-content hover:opacity-90 shadow-xs transition-all cursor-pointer"
            >
              <.icon name="hero-arrow-path" class="size-4 shrink-0" />
              <span>Refresh Ops</span>
            </button>
          </div>
        </div>

        <!-- Active System Alarms Banner (Streamed collection) -->
        <%= if @active_alarms_count > 0 do %>
          <div
            id="active-alarms-banner"
            class="bg-error/10 border-2 border-error/30 rounded-2xl p-6 shadow-sm space-y-4"
          >
            <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
              <div class="flex items-center gap-3">
                <span class="p-2 rounded-xl bg-error text-error-content shadow-xs">
                  <.icon name="hero-exclamation-triangle" class="size-6 shrink-0" />
                </span>
                <div>
                  <h2 class="text-lg font-bold text-error flex items-center gap-2">
                    <span>Operational Anomalies Detected ({@active_alarms_count})</span>
                  </h2>
                  <p class="text-xs text-base-content/80 mt-0.5">
                    Background monitor invariants have breached safety thresholds. Web Push alerts have been dispatched.
                  </p>
                </div>
              </div>

              <div class="text-xs text-base-content/60 font-mono">
                Throttled: 60m cooldown with auto-resolve
              </div>
            </div>

            <div id="active-alarms-list" phx-update="stream" class="grid grid-cols-1 gap-3 pt-1">
              <div
                :for={{dom_id, alarm} <- @streams.active_alarms}
                id={dom_id}
                class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-4 rounded-xl bg-base-100 border border-error/20"
              >
                <div class="space-y-1">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "px-2 py-0.5 rounded-md text-[11px] font-bold uppercase tracking-wider",
                      alarm.severity == :critical && "bg-error text-error-content",
                      alarm.severity == :warning && "bg-warning/20 text-warning"
                    ]}>
                      {alarm.severity}
                    </span>
                    <span class="text-sm font-bold text-base-content">{alarm.title}</span>
                  </div>
                  <p class="text-xs text-base-content/80">{alarm.message}</p>
                  <div class="text-[11px] text-base-content/50">
                    Detected {DateTime.to_iso8601(alarm.detected_at) |> String.slice(11..18)} UTC
                  </div>
                </div>

                <div class="flex items-center gap-2 shrink-0">
                  <%= cond do %>
                    <% alarm.type == :wal_bloat -> %>
                      <button
                        type="button"
                        phx-click="safe_checkpoint"
                        class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-primary text-primary-content hover:opacity-90 transition-all cursor-pointer shadow-xs"
                      >
                        <.icon name="hero-circle-stack" class="size-3.5" />
                        <span>Safe Checkpoint</span>
                      </button>
                    <% alarm.type in [:high_ram, :high_swap] -> %>
                      <button
                        type="button"
                        phx-click="safe_reclaim_memory"
                        class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-purple-600 text-white hover:opacity-90 transition-all cursor-pointer shadow-xs"
                      >
                        <.icon name="hero-sparkles" class="size-3.5" />
                        <span>Release Memory</span>
                      </button>
                    <% alarm.type == :feed_backoff -> %>
                      <a
                        href="#feeds-health-table"
                        class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-amber-500/15 text-amber-700 dark:text-amber-300 border border-amber-500/30 hover:bg-amber-500/25 transition-all shadow-xs"
                      >
                        <.icon name="hero-arrow-down" class="size-3.5" />
                        <span>View Feeds</span>
                      </a>
                    <% true -> %>
                      <a
                        href="#compute-guard-console"
                        class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-base-200 hover:bg-base-300 text-base-content transition-all"
                      >
                        <span>Review Rules</span>
                        <.icon name="hero-arrow-down" class="size-3.5" />
                      </a>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Admin Web Push Status Card (Connected via PushManager hook) -->
        <div
          id="admin-push-status-card"
          phx-hook="PushManager"
          class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm flex flex-col sm:flex-row sm:items-center justify-between gap-4"
        >
          <div class="flex items-center gap-3.5">
            <div class={[
              "p-2.5 rounded-xl border",
              if(@push_subscribed,
                do: "bg-emerald-500/10 border-emerald-500/30 text-emerald-600 dark:text-emerald-400",
                else: "bg-amber-500/10 border-amber-500/30 text-amber-600 dark:text-amber-400"
              )
            ]}>
              <.icon
                name={if(@push_subscribed, do: "hero-bell-alert", else: "hero-bell-slash")}
                class="size-5"
              />
            </div>
            <div>
              <div class="text-sm font-bold text-base-content flex items-center gap-2">
                <span>Admin Mobile & Browser Alarms</span>
                <%= if @push_subscribed do %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold bg-emerald-500/15 text-emerald-600 dark:text-emerald-400">
                    <span class="size-1.5 rounded-full bg-emerald-500"></span>
                    <span>Subscribed</span>
                  </span>
                <% else %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold bg-amber-500/15 text-amber-600 dark:text-amber-400">
                    <span class="size-1.5 rounded-full bg-amber-500"></span>
                    <span>Not Enabled</span>
                  </span>
                <% end %>
              </div>
              <p class="text-xs text-base-content/60 mt-0.5">
                <%= if @push_subscribed do %>
                  This browser receives Web Push notifications for critical invariants (high RAM/swap, WAL bloat, feed outages).
                <% else %>
                  Enable Web Push notifications to receive immediate alarms even when DealScout is closed.
                <% end %>
              </p>
            </div>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <%= if not @push_subscribed do %>
              <button
                id="enable-admin-push-btn"
                type="button"
                phx-click="enable_push_notifications"
                class="inline-flex items-center gap-1.5 px-3.5 py-1.5 rounded-xl text-xs font-semibold bg-primary text-primary-content hover:opacity-90 transition-all cursor-pointer shadow-xs"
              >
                <.icon name="hero-bell" class="size-3.5" />
                <span>Enable Device Alarms</span>
              </button>
            <% end %>
          </div>
        </div>

        <!-- 5 Key Operational Cards (Custom Tailwind components without DaisyUI card class) -->
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4">
          <!-- Live Active Users -->
          <div class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Active Connected Sessions</span>
              <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span>
            </div>
            <div class="text-3xl font-black text-emerald-600 dark:text-emerald-400">
              {@ops.active_sessions_count}
            </div>
            <p class="text-xs text-base-content/60">
              Phoenix Presence
            </p>
          </div>

          <!-- BEAM Memory -->
          <div class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>BEAM VM Memory</span>
              <.icon name="hero-cpu-chip" class="size-4 text-purple-500" />
            </div>
            <div class={[
              "text-3xl font-black",
              @system_metrics.memory.beam_usage_pct > 80 && "text-error",
              @system_metrics.memory.beam_usage_pct > 70 &&
                @system_metrics.memory.beam_usage_pct <= 80 && "text-warning",
              @system_metrics.memory.beam_usage_pct <= 70 &&
                "text-purple-600 dark:text-purple-400"
            ]}>
              {@system_metrics.memory.beam_total_mb} MB
            </div>
            <p class="text-xs text-base-content/60">
              {@system_metrics.memory.beam_usage_pct}% of 512 MB ceiling
            </p>
          </div>

          <!-- Swap Memory -->
          <div class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Swap Memory</span>
              <.icon name="hero-arrows-right-left" class="size-4 text-blue-500" />
            </div>
            <div class={[
              "text-3xl font-black",
              @system_metrics.memory.swap_used_mb > 100 && "text-error",
              @system_metrics.memory.swap_used_mb > 40 &&
                @system_metrics.memory.swap_used_mb <= 100 && "text-warning",
              @system_metrics.memory.swap_used_mb <= 40 && "text-blue-600 dark:text-blue-400"
            ]}>
              {@system_metrics.memory.swap_used_mb} MB
            </div>
            <p class="text-xs text-base-content/60">
              <%= if @system_metrics.memory.swap_total_mb > 0 do %>
                of {@system_metrics.memory.swap_total_mb} MB ({@system_metrics.memory.swap_usage_pct}%)
              <% else %>
                Swap unconfigured
              <% end %>
            </p>
          </div>

          <!-- Total Registered Users -->
          <div class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Registered Users</span>
              <.icon name="hero-users" class="size-4 text-primary" />
            </div>
            <div class="text-3xl font-black text-base-content">
              {@ops.total_users_count}
            </div>
            <p class="text-xs text-base-content/60">
              User accounts
            </p>
          </div>

          <!-- System Uptime -->
          <div class="bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>System Uptime</span>
              <.icon name="hero-clock" class="size-4 text-emerald-500" />
            </div>
            <div class="text-3xl font-black text-base-content">
              {format_uptime(@ops.uptime_seconds)}
            </div>
            <p class="text-xs text-base-content/60">
              Process wall-clock
            </p>
          </div>
        </div>

        <!-- Micro-VM Memory Allocation & SQLite Storage Deep Metrics -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Card 1: Micro-VM Memory Allocation & Headroom -->
          <div
            id="system-memory-gauge-card"
            class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-5"
          >
            <div class="flex items-center justify-between">
              <div>
                <h2 class="text-lg font-bold flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="size-5 text-purple-500" />
                  <span>Micro-VM RAM & Swap Allocation</span>
                </h2>
                <p class="text-xs text-base-content/70 mt-0.5">
                  512 MB physical container allocation with cgroups v2 memory limits.
                </p>
              </div>

              <button
                id="safe-reclaim-mem-btn"
                type="button"
                phx-click="safe_reclaim_memory"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold bg-purple-500/10 text-purple-700 dark:text-purple-300 border border-purple-500/25 hover:bg-purple-500/20 transition-all cursor-pointer shadow-xs"
                title="Issues PRAGMA shrink_memory on SQLite and runs targeted GC on top-heap processes"
              >
                <.icon name="hero-sparkles" class="size-3.5" />
                <span>Release Memory</span>
              </button>
            </div>

            <!-- RAM Progress Bar -->
            <div class="space-y-1.5">
              <div class="flex items-center justify-between text-xs">
                <span class="font-medium text-base-content/70">BEAM RAM Pressure</span>
                <span class="font-mono font-bold text-base-content">
                  {@system_metrics.memory.beam_total_mb} MB / {@system_metrics.memory.container_limit_mb} MB ({@system_metrics.memory.beam_usage_pct}%)
                </span>
              </div>
              <div class="w-full bg-base-200 h-2.5 rounded-full overflow-hidden">
                <div
                  class={[
                    "h-full transition-all duration-500",
                    @system_metrics.memory.beam_usage_pct > 80 && "bg-error",
                    @system_metrics.memory.beam_usage_pct > 70 &&
                      @system_metrics.memory.beam_usage_pct <= 80 && "bg-warning",
                    @system_metrics.memory.beam_usage_pct <= 70 && "bg-purple-500"
                  ]}
                  style={"width: #{min(100, @system_metrics.memory.beam_usage_pct)}%"}
                >
                </div>
              </div>
            </div>

            <!-- Breakdown Grid -->
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 pt-1">
              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">Process Heaps</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {@system_metrics.memory.beam_processes_mb} MB
                </div>
              </div>
              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">ETS Tables</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {@system_metrics.memory.beam_ets_mb} MB
                </div>
              </div>
              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">Binary Storage</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {@system_metrics.memory.beam_binary_mb} MB
                </div>
              </div>
              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">Atom & Code</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {@system_metrics.memory.beam_atom_mb + @system_metrics.memory.beam_code_mb} MB
                </div>
              </div>
            </div>

            <!-- Swap & Host Linux Mem -->
            <div class="bg-base-200/40 p-3.5 rounded-xl border border-base-300/60 flex flex-col sm:flex-row sm:items-center justify-between gap-2 text-xs">
              <div>
                <span class="font-semibold text-base-content">Swap Shock-Absorber:</span>
                <span class="text-base-content/70 ml-1">
                  <%= if @system_metrics.memory.swap_total_mb > 0 do %>
                    {@system_metrics.memory.swap_used_mb} MB used of {@system_metrics.memory.swap_total_mb} MB
                    <span class={[
                      "font-semibold ml-1",
                      @system_metrics.memory.swap_used_mb > 100 && "text-error",
                      @system_metrics.memory.swap_used_mb <= 100 && "text-base-content/60"
                    ]}>
                      ({@system_metrics.memory.swap_usage_pct}%)
                    </span>
                  <% else %>
                    No swap partition detected
                  <% end %>
                </span>
              </div>
              <div class="text-base-content/60 text-[11px]">
                Host Available: {@system_metrics.memory.host_mem_available_mb} MB
              </div>
            </div>
          </div>

          <!-- Card 2: SQLite Storage & In-Place StreamCache -->
          <div
            id="sqlite-storage-card"
            class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-5"
          >
            <div class="flex items-center justify-between">
              <div>
                <h2 class="text-lg font-bold flex items-center gap-2">
                  <.icon name="hero-circle-stack" class="size-5 text-primary" />
                  <span>SQLite Storage & Cache Engine</span>
                </h2>
                <p class="text-xs text-base-content/70 mt-0.5">
                  Exclusive block volume storage, WAL mutation log, and ETS stream cache.
                </p>
              </div>

              <div class="flex items-center gap-2">
                <button
                  id="safe-refresh-cache-btn"
                  type="button"
                  phx-click="safe_refresh_cache"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold bg-base-200 hover:bg-base-300 text-base-content border border-base-300 transition-all cursor-pointer shadow-xs"
                  title="Refreshes cached stream queries in-place with zero read stampedes"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" />
                  <span>Re-warm Cache</span>
                </button>
                <button
                  id="safe-checkpoint-btn"
                  type="button"
                  phx-click="safe_checkpoint"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold bg-primary text-primary-content hover:opacity-90 transition-all cursor-pointer shadow-xs"
                  title="Executes non-blocking PRAGMA wal_checkpoint(PASSIVE)"
                >
                  <.icon name="hero-circle-stack" class="size-3.5" />
                  <span>Safe Checkpoint</span>
                </button>
              </div>
            </div>

            <!-- Storage Metrics Grid -->
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">Main Database</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {format_bytes(@system_metrics.storage.db_bytes)}
                </div>
                <div class="text-[10px] text-base-content/50 mt-0.5">
                  {@system_metrics.storage.total_deals} deals
                </div>
              </div>

              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">WAL Log File</div>
                <div class={[
                  "text-sm font-bold font-mono mt-0.5",
                  @system_metrics.storage.wal_bytes > 30 * 1024 * 1024 && "text-error",
                  @system_metrics.storage.wal_bytes > 15 * 1024 * 1024 &&
                    @system_metrics.storage.wal_bytes <= 30 * 1024 * 1024 && "text-warning",
                  @system_metrics.storage.wal_bytes <= 15 * 1024 * 1024 &&
                    "text-emerald-600 dark:text-emerald-400"
                ]}>
                  {format_bytes(@system_metrics.storage.wal_bytes)}
                </div>
                <div class="text-[10px] text-base-content/50 mt-0.5">
                  Uncheckpointed writes
                </div>
              </div>

              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">StreamCache Entries</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-primary">
                  {@system_metrics.stream_cache.size} queries
                </div>
                <div class="text-[10px] text-base-content/50 mt-0.5">
                  ETS read concurrency
                </div>
              </div>

              <div class="bg-base-200/50 p-3 rounded-xl border border-base-300/60">
                <div class="text-[11px] text-base-content/60 font-medium">Retention Pruning</div>
                <div class="text-sm font-bold font-mono mt-0.5 text-base-content">
                  {@system_metrics.storage.retention_days} Days
                </div>
                <div class="text-[10px] text-base-content/50 mt-0.5">
                  Incremental auto-vacuum
                </div>
              </div>
            </div>

            <div class="text-xs text-base-content/60 font-mono truncate bg-base-200/30 p-2.5 rounded-lg border border-base-300/40">
              Path: {@system_metrics.storage.db_path}
            </div>
          </div>
        </div>

        <!-- Remote NAS Backup & Replication Health Card -->
        <div class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <div>
              <div class="flex items-center gap-2">
                <h2 class="text-lg font-bold flex items-center gap-2">
                  <.icon name="hero-circle-stack" class="size-5 text-primary" />
                  <span>Remote NAS Backup & Litestream Replication</span>
                </h2>
                <span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-semibold bg-base-200 text-base-content/60">
                  Status Only • No Alarms on NAS Disconnect
                </span>
              </div>
              <p class="text-xs text-base-content/70 mt-0.5">
                Real-time WebSocket streaming of SQLite WAL frames to your NixOS NAS. Zero inbound ports required on the NAS.
              </p>
            </div>

            <div>
              <%= if @backup.client_connected do %>
                <div class="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20">
                  <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span>
                  <span>NAS Client Connected ({get_in(@backup, [:connected_client, :client_id]) ||
                    "NAS"})</span>
                </div>
              <% else %>
                <div class="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-base-200 text-base-content/70 border border-base-300">
                  <span class="size-2 rounded-full bg-base-content/40"></span>
                  <span>Awaiting NAS Outbound Connection</span>
                </div>
              <% end %>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 pt-2">
            <!-- Client Info -->
            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Remote Client Address</div>
              <div class="text-sm font-bold font-mono mt-1 text-base-content">
                <%= if @backup.connected_client do %>
                  {Map.get(@backup.connected_client, :remote_ip, "Unknown")}
                <% else %>
                  <span class="text-base-content/40">Not connected</span>
                <% end %>
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                <%= if @backup.connected_client do %>
                  Connected {DateTime.to_iso8601(@backup.connected_client.connected_at)
                  |> String.slice(11..18)} UTC
                <% else %>
                  Persistent WebSocket channel
                <% end %>
              </div>
            </div>

            <!-- Frames Synced -->
            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Replicated Frames</div>
              <div class="text-sm font-bold mt-1 text-primary">
                {@backup.files_synced_count} frames ({format_bytes(@backup.bytes_synced_count)})
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                Transferred to NAS this session
              </div>
            </div>

            <!-- Last Live Sync -->
            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Last Replicated Frame</div>
              <div
                class="text-sm font-bold font-mono truncate mt-1 text-base-content"
                title={@backup.last_file_sent || "None"}
              >
                <%= if @backup.last_file_sent do %>
                  {Path.basename(@backup.last_file_sent)}
                <% else %>
                  <span class="text-base-content/40 font-sans">No frames synced yet</span>
                <% end %>
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                <%= if @backup.last_sync_at do %>
                  Synced at {DateTime.to_iso8601(@backup.last_sync_at) |> String.slice(11..18)} UTC
                <% else %>
                  Waiting for writes
                <% end %>
              </div>
            </div>

            <!-- Local Replica Generations -->
            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">
                Litestream Replica Generations
              </div>
              <div class="text-sm font-bold mt-1 text-base-content">
                {get_in(@backup, [:replica_summary, :generations_count]) || 0} active
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5 font-mono truncate">
                {@backup.replica_dir}
              </div>
            </div>
          </div>
        </div>

        <!-- Feed Ingestion State Table -->
        <div
          id="feeds-health-table"
          class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4"
        >
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-bold flex items-center gap-2">
                <.icon name="hero-rss" class="size-5 text-primary" />
                <span>RSS & Atom Feed Poller Health</span>
              </h2>
              <p class="text-xs text-base-content/70 mt-0.5">
                Current status, deal throughput, and last ingestion timestamps across registered feeds.
              </p>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm w-full">
              <thead>
                <tr class="text-xs text-base-content/60 border-b border-base-200">
                  <th>Feed Name</th>
                  <th>Status</th>
                  <th>Interval</th>
                  <th>URL</th>
                  <th class="text-right">Ingested Deals</th>
                  <th class="text-right">Last Fetched</th>
                  <th class="text-right">Action</th>
                </tr>
              </thead>
              <tbody>
                <%= for feed <- @ops.feeds_status do %>
                  <tr class="hover:bg-base-200/40">
                    <td class="font-bold whitespace-nowrap">{feed.name}</td>
                    <td class="whitespace-nowrap">
                      <%= cond do %>
                        <% not feed.is_active -> %>
                          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-base-200 text-base-content/70 border border-base-300">
                            <span class="size-1.5 rounded-full bg-base-content/40"></span>
                            <span>Disabled</span>
                          </span>
                        <% feed.backoff_until && DateTime.compare(feed.backoff_until, DateTime.utc_now()) == :gt -> %>
                          <span
                            class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-amber-500/10 text-amber-600 dark:text-amber-400 border border-amber-500/25"
                            title={"Blocked with #{feed.last_error_status || "error"}. Backed off until #{feed.backoff_until}"}
                          >
                            <span class="size-1.5 rounded-full bg-amber-500"></span>
                            <span>Backoff ({feed.last_error_status || "429"})</span>
                          </span>
                        <% true -> %>
                          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/25">
                            <span class="size-1.5 rounded-full bg-emerald-500"></span>
                            <span>Active</span>
                          </span>
                      <% end %>
                    </td>
                    <td class="text-xs text-base-content/70">
                      {div(feed.poll_interval_seconds || 120, 60)}m
                    </td>
                    <td
                      class="text-xs text-base-content/70 font-mono truncate max-w-xs"
                      title={feed.url}
                    >
                      {feed.url}
                    </td>
                    <td class="text-right">
                      <span class="font-bold text-primary">{feed.deal_count}</span>
                      <span class="text-xs text-base-content/60 ml-1">
                        ({Map.get(feed, :deals_last_30d, feed.deal_count)} in 30d)
                      </span>
                    </td>
                    <td class="text-right text-xs text-base-content/70">
                      <%= if feed.last_fetched_at do %>
                        {DateTime.to_iso8601(feed.last_fetched_at) |> String.slice(11..18)} UTC
                      <% else %>
                        Pending poll
                      <% end %>
                    </td>
                    <td class="text-right whitespace-nowrap">
                      <%= if feed.backoff_until && DateTime.compare(feed.backoff_until, DateTime.utc_now()) == :gt do %>
                        <button
                          id={"safe-retry-feed-#{feed.id}"}
                          type="button"
                          phx-click="safe_retry_feed"
                          phx-value-id={feed.id}
                          class="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg text-xs font-semibold bg-amber-500/15 text-amber-700 dark:text-amber-300 border border-amber-500/30 hover:bg-amber-500/25 transition-all cursor-pointer"
                        >
                          <.icon name="hero-arrow-path" class="size-3" />
                          <span>Retry</span>
                        </button>
                      <% else %>
                        <span class="text-[11px] text-base-content/40">—</span>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <!-- eBay Sofort-Kauf Sniper Health Card -->
        <div class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-bold flex items-center gap-2">
                <.icon name="hero-shopping-bag" class="size-5 text-secondary" />
                <span>eBay Sofort-Kauf Sniper Health</span>
              </h2>
              <p class="text-xs text-base-content/70 mt-0.5">
                Demand-driven eBay Browse REST API polling with in-memory filter-first matching (zero SQLite disk bloat).
              </p>
            </div>
            <div>
              <%= cond do %>
                <% not @ebay_status.configured -> %>
                  <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-semibold whitespace-nowrap bg-amber-500/10 text-amber-600 dark:text-amber-400 border border-amber-500/25">
                    <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
                    <span>Credentials Missing</span>
                  </span>
                <% not @ebay_status.enabled -> %>
                  <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-semibold whitespace-nowrap bg-base-200 text-base-content/70 border border-base-300">
                    <span class="size-2 rounded-full bg-base-content/40"></span>
                    <span>Disabled via Config</span>
                  </span>
                <% true -> %>
                  <span class="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold whitespace-nowrap bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/25">
                    <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span>
                    <span>Active</span>
                  </span>
              <% end %>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 pt-2">
            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Marketplace Target</div>
              <div class="text-sm font-bold font-mono mt-1 text-base-content">
                {@ebay_status.marketplace}
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                eBay Germany Browse API
              </div>
            </div>

            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">In-Memory Seen Cache</div>
              <div class="text-sm font-bold mt-1 text-secondary">
                {@ebay_status.seen_items} items in RAM
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                ETS deduplication (~300 KB)
              </div>
            </div>

            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Poll Cycle Interval</div>
              <div class="text-sm font-bold mt-1 text-base-content">
                {@ebay_status.poll_interval}s
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                Demand-driven (active rules only)
              </div>
            </div>

            <div class="bg-base-200/50 p-4 rounded-xl border border-base-300/60">
              <div class="text-xs text-base-content/60 font-medium">Persistence Mode</div>
              <div class="text-sm font-bold mt-1 text-emerald-600 dark:text-emerald-400">
                Match-Only
              </div>
              <div class="text-[11px] text-base-content/50 mt-0.5">
                Non-matching items discarded
              </div>
            </div>
          </div>
        </div>

        <!-- Compute Budget & Alert Query Performance Card -->
        <div
          id="compute-guard-console"
          class="bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-6"
        >
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-base-200">
            <div>
              <div class="flex items-center gap-2">
                <span class="p-1.5 rounded-lg bg-warning/10 text-warning">
                  <.icon name="hero-cpu-chip" class="size-5" />
                </span>
                <h2 class="text-xl font-bold tracking-tight">
                  Compute Budget & Alert Query Performance
                </h2>
              </div>
              <p class="text-xs text-base-content/70 mt-1">
                Telemetry circuit breaker tracking slow alert queries. Rules exceeding 30ms/deal are auto-paused to protect server compute.
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <div class="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-base-200 border border-base-300 text-xs whitespace-nowrap">
                <span class="text-base-content/70 font-medium">Budget Limit:</span>
                <span class="font-mono font-bold text-primary">30.0 ms / deal</span>
              </div>
              <div class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-xl border text-xs font-semibold whitespace-nowrap",
                if(length(@auto_paused_rules) > 0,
                  do: "bg-error/10 border-error/30 text-error",
                  else:
                    "bg-emerald-500/10 border-emerald-500/30 text-emerald-600 dark:text-emerald-400"
                )
              ]}>
                <.icon
                  name={
                    if length(@auto_paused_rules) > 0,
                      do: "hero-exclamation-triangle",
                      else: "hero-check-circle"
                  }
                  class="size-4 shrink-0"
                />
                <span id="auto-paused-count">{length(@auto_paused_rules)} Auto-Paused</span>
              </div>
            </div>
          </div>

          <!-- Section 1: Auto-Paused Rules -->
          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <h3 class="text-sm font-bold uppercase tracking-wider text-base-content/70 flex items-center gap-1.5">
                <.icon name="hero-pause-circle" class="size-4 text-warning" />
                <span>Auto-Paused Slow Rules ({length(@auto_paused_rules)})</span>
              </h3>
            </div>

            <%= if @auto_paused_rules == [] do %>
              <div
                id="no-auto-paused-rules"
                class="text-center py-6 px-4 rounded-xl bg-base-200/40 border border-dashed border-base-300"
              >
                <.icon
                  name="hero-shield-check"
                  class="size-8 text-emerald-500 mx-auto mb-1 opacity-70"
                />
                <p class="text-xs font-semibold text-base-content">
                  All alert rules operating normally
                </p>
                <p class="text-[11px] text-base-content/60 mt-0.5">
                  No rules have exceeded the compute budget threshold.
                </p>
              </div>
            <% else %>
              <div class="overflow-x-auto rounded-xl border border-base-200">
                <table id="auto-paused-rules-table" class="table table-sm w-full">
                  <thead class="bg-base-200/60 text-xs text-base-content/70">
                    <tr>
                      <th>Rule Name</th>
                      <th>User</th>
                      <th>Reason</th>
                      <th class="text-right">Duration</th>
                      <th class="text-right">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for rule <- @auto_paused_rules do %>
                      <tr
                        id={"auto-paused-rule-#{rule.id}"}
                        class="hover:bg-base-200/40 transition-colors"
                      >
                        <td>
                          <div class="font-bold text-sm text-base-content">{rule.name}</div>
                          <div
                            class="text-[11px] text-base-content/60 font-mono mt-0.5 max-w-xs truncate"
                            title={rule.keywords}
                          >
                            Keywords: {rule.keywords}
                          </div>
                        </td>
                        <td class="whitespace-nowrap">
                          <span class="text-xs font-medium text-base-content/80">
                            {if rule.user, do: rule.user.email, else: "User ##{rule.user_id}"}
                          </span>
                        </td>
                        <td class="max-w-md">
                          <span class="text-xs text-error font-medium leading-relaxed block">
                            {rule.pause_reason}
                          </span>
                        </td>
                        <td class="text-right font-mono text-xs font-bold text-error whitespace-nowrap">
                          {format_duration_ms(rule.last_eval_duration_us)}
                        </td>
                        <td class="text-right whitespace-nowrap">
                          <button
                            id={"resume-auto-paused-rule-btn-#{rule.id}"}
                            type="button"
                            phx-click="resume_rule"
                            phx-value-id={rule.id}
                            class="inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold whitespace-nowrap text-emerald-600 dark:text-emerald-400 bg-emerald-500/10 hover:bg-emerald-500/20 border border-emerald-500/25 hover:border-emerald-500/40 transition-all cursor-pointer"
                          >
                            <.icon name="hero-play" class="size-3.5 shrink-0" />
                            <span>Re-enable</span>
                          </button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>

          <!-- Section 2: Top Slowest Rules -->
          <div class="space-y-3 pt-2 border-t border-base-200">
            <div class="flex items-center justify-between">
              <h3 class="text-sm font-bold uppercase tracking-wider text-base-content/70 flex items-center gap-1.5">
                <.icon name="hero-chart-bar" class="size-4 text-primary" />
                <span>Top Slowest Rules by Last Evaluation Duration</span>
              </h3>
            </div>

            <%= if @slowest_rules == [] do %>
              <div
                id="no-slowest-rules"
                class="text-center py-6 px-4 rounded-xl bg-base-200/40 border border-dashed border-base-300"
              >
                <.icon name="hero-clock" class="size-8 text-base-content/30 mx-auto mb-1" />
                <p class="text-xs font-semibold text-base-content">
                  No evaluation telemetry recorded yet
                </p>
                <p class="text-[11px] text-base-content/60 mt-0.5">
                  Metrics will populate as deals are matched against active rules.
                </p>
              </div>
            <% else %>
              <div class="overflow-x-auto rounded-xl border border-base-200">
                <table id="slowest-rules-table" class="table table-sm w-full">
                  <thead class="bg-base-200/60 text-xs text-base-content/70">
                    <tr>
                      <th>Rule Name</th>
                      <th>User</th>
                      <th>Status</th>
                      <th class="text-right">Last Duration (per deal)</th>
                      <th class="text-right">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for rule <- @slowest_rules do %>
                      <tr
                        id={"slowest-rule-#{rule.id}"}
                        class="hover:bg-base-200/40 transition-colors"
                      >
                        <td>
                          <div class="font-bold text-sm text-base-content">{rule.name}</div>
                          <div
                            class="text-[11px] text-base-content/60 font-mono mt-0.5 max-w-xs truncate"
                            title={rule.keywords}
                          >
                            Keywords: {rule.keywords}
                          </div>
                        </td>
                        <td class="whitespace-nowrap">
                          <span class="text-xs font-medium text-base-content/80">
                            {if rule.user, do: rule.user.email, else: "User ##{rule.user_id}"}
                          </span>
                        </td>
                        <td class="whitespace-nowrap">
                          <%= if rule.is_active do %>
                            <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/25">
                              <span class="size-1.5 rounded-full bg-emerald-500"></span>
                              <span>Active</span>
                            </span>
                          <% else %>
                            <%= if rule.pause_reason do %>
                              <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-rose-500/10 text-rose-600 dark:text-rose-400 border border-rose-500/25">
                                <span class="size-1.5 rounded-full bg-rose-500"></span>
                                <span>Auto-Paused</span>
                              </span>
                            <% else %>
                              <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold whitespace-nowrap bg-base-200 text-base-content/70 border border-base-300">
                                <span class="size-1.5 rounded-full bg-base-content/40"></span>
                                <span>Paused</span>
                              </span>
                            <% end %>
                          <% end %>
                        </td>
                        <td class="text-right font-mono text-xs whitespace-nowrap">
                          <span class={[
                            "font-bold",
                            (rule.last_eval_duration_us || 0) > 30_000 && "text-error",
                            ((rule.last_eval_duration_us || 0) > 15_000 and
                               (rule.last_eval_duration_us || 0) <= 30_000) && "text-warning",
                            (rule.last_eval_duration_us || 0) <= 15_000 &&
                              "text-emerald-600 dark:text-emerald-400"
                          ]}>
                            {format_duration_ms(rule.last_eval_duration_us)}
                          </span>
                        </td>
                        <td class="text-right whitespace-nowrap">
                          <%= if rule.is_active do %>
                            <button
                              id={"pause-slowest-rule-btn-#{rule.id}"}
                              type="button"
                              phx-click="pause_rule"
                              phx-value-id={rule.id}
                              class="inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold whitespace-nowrap text-rose-600 dark:text-rose-400 bg-rose-500/10 hover:bg-rose-500/20 border border-rose-500/25 hover:border-rose-500/40 transition-all cursor-pointer"
                            >
                              <.icon name="hero-pause" class="size-3.5 shrink-0" />
                              <span>Pause</span>
                            </button>
                          <% else %>
                            <button
                              id={"resume-slowest-rule-btn-#{rule.id}"}
                              type="button"
                              phx-click="resume_rule"
                              phx-value-id={rule.id}
                              class="inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold whitespace-nowrap text-emerald-600 dark:text-emerald-400 bg-emerald-500/10 hover:bg-emerald-500/20 border border-emerald-500/25 hover:border-emerald-500/40 transition-all cursor-pointer"
                            >
                              <.icon name="hero-play" class="size-3.5 shrink-0" />
                              <span>Re-enable</span>
                            </button>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp fetch_streamable_alarms do
    HealthMonitor.list_active_alarms()
    |> Enum.map(fn alarm ->
      Map.put(alarm, :id, to_string(alarm.type))
    end)
  end

  defp format_duration_ms(nil), do: "—"
  defp format_duration_ms(us) when is_integer(us) and us < 1_000, do: "#{us} µs"
  defp format_duration_ms(us) when is_integer(us), do: "#{Float.round(us / 1000, 2)} ms"

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"

  defp get_ebay_status do
    %{
      configured: DealScout.Feeds.Ebay.Config.configured?(),
      enabled: DealScout.Feeds.Ebay.Config.enabled?(),
      marketplace: DealScout.Feeds.Ebay.Config.marketplace_id(),
      seen_items: DealScout.Feeds.Ebay.SeenCache.size(),
      poll_interval: DealScout.Feeds.Ebay.Config.poll_interval_seconds()
    }
  end
end
