defmodule DealScoutWeb.Admin.SystemLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Analytics
  alias DealScout.Feeds.Poller
  alias DealScout.Alerts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DealScoutWeb.Endpoint.subscribe("deals:presence")
      DealScout.Backup.subscribe()
    end

    ops = Analytics.get_system_ops_stats()
    backup_status = DealScout.Backup.get_status()
    auto_paused_rules = Alerts.list_auto_paused_rules()
    slowest_rules = Alerts.list_slowest_rules(10)

    socket =
      socket
      |> assign(:page_title, "Admin System & Operational Health")
      |> assign(:ops, ops)
      |> assign(:backup, backup_status)
      |> assign(:auto_paused_rules, auto_paused_rules)
      |> assign(:slowest_rules, slowest_rules)

    {:ok, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "deals:presence"}, socket) do
    ops = Analytics.get_system_ops_stats()
    {:noreply, assign(socket, :ops, ops)}
  end

  @impl true
  def handle_info({:new_backup_file, _path, _full, _size, _sha}, socket) do
    backup_status = DealScout.Backup.get_status()
    {:noreply, assign(socket, :backup, backup_status)}
  end

  @impl true
  def handle_event("refresh_metrics", _params, socket) do
    ops = Analytics.get_system_ops_stats()
    backup_status = DealScout.Backup.get_status()

    {:noreply,
     socket
     |> assign(:ops, ops)
     |> assign(:backup, backup_status)
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))
     |> put_flash(:info, "System operations metrics updated.")}
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

    {:noreply,
     socket
     |> put_flash(:info, "Alert rule \"#{rule.name}\" resumed successfully.")
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))}
  end

  @impl true
  def handle_event("pause_rule", %{"id" => id}, socket) do
    rule = Alerts.get_alert_rule!(id)
    {:ok, _} = Alerts.pause_rule(rule, "Manually paused by administrator")

    {:noreply,
     socket
     |> put_flash(:info, "Alert rule \"#{rule.name}\" paused.")
     |> assign(:auto_paused_rules, Alerts.list_auto_paused_rules())
     |> assign(:slowest_rules, Alerts.list_slowest_rules(10))}
  end

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
              Live concurrent sessions (Phoenix Presence), BEAM runtime resources, and feed poller ingestion states.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="trigger_poll"
              class="btn btn-warning btn-sm flex items-center gap-2"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Poll Feeds Now
            </button>
            <button
              phx-click="refresh_metrics"
              class="btn btn-primary btn-sm flex items-center gap-2"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh Ops
            </button>
          </div>
        </div>

        <!-- 4 Key Operational Cards -->
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <!-- Live Active Users -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Active Connected Sessions</span>
              <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span>
            </div>
            <div class="text-3xl font-black text-emerald-600 dark:text-emerald-400">
              {@ops.active_sessions_count}
            </div>
            <p class="text-xs text-base-content/60">
              Tracked via Phoenix Presence
            </p>
          </div>

          <!-- Total Registered Users -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Registered Accounts</span>
              <.icon name="hero-users" class="size-4 text-primary" />
            </div>
            <div class="text-3xl font-black text-base-content">
              {@ops.total_users_count}
            </div>
            <p class="text-xs text-base-content/60">
              User database accounts
            </p>
          </div>

          <!-- BEAM Memory -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>BEAM VM Memory</span>
              <.icon name="hero-cpu-chip" class="size-4 text-purple-500" />
            </div>
            <div class="text-3xl font-black text-purple-600 dark:text-purple-400">
              {@ops.beam_memory_mb} MB
            </div>
            <p class="text-xs text-base-content/60">
              Erlang VM total heap & runtime
            </p>
          </div>

          <!-- System Uptime -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>System Uptime</span>
              <.icon name="hero-clock" class="size-4 text-blue-500" />
            </div>
            <div class="text-3xl font-black text-blue-600 dark:text-blue-400">
              {format_uptime(@ops.uptime_seconds)}
            </div>
            <p class="text-xs text-base-content/60">
              Process wall-clock time
            </p>
          </div>
        </div>

        <!-- Remote NAS Backup & Replication Health Card -->
        <div class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-bold flex items-center gap-2">
                <.icon name="hero-circle-stack" class="size-5 text-primary" />
                <span>Remote NAS Backup & Litestream Replication</span>
              </h2>
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
                <div class="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-amber-500/10 text-amber-600 dark:text-amber-400 border border-amber-500/20">
                  <span class="size-2 rounded-full bg-amber-500"></span>
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
                  {@backup.connected_client.remote_ip}
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
        <div class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-bold flex items-center gap-2">
                <.icon name="hero-rss" class="size-5 text-primary" />
                <span>RSS & Atom Feed Poller Health</span>
              </h2>
              <p class="text-xs text-base-content/70 mt-0.5">
                Current status, deal throughput, and last ingestion timestamps across all registered providers.
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
                </tr>
              </thead>
              <tbody>
                <%= for feed <- @ops.feeds_status do %>
                  <tr class="hover:bg-base-200/40">
                    <td class="font-bold">{feed.name}</td>
                    <td>
                      <%= cond do %>
                        <% not feed.is_active -> %>
                          <span class="badge badge-ghost badge-xs">Disabled</span>
                        <% feed.backoff_until && DateTime.compare(feed.backoff_until, DateTime.utc_now()) == :gt -> %>
                          <span
                            class="badge badge-warning badge-xs"
                            title={"Blocked with #{feed.last_error_status || "error"}. Backed off until #{feed.backoff_until}"}
                          >
                            Backoff ({feed.last_error_status || "429"})
                          </span>
                        <% true -> %>
                          <span class="badge badge-success badge-xs text-white">Active</span>
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
                    <td class="text-right font-bold text-primary">{feed.deal_count}</td>
                    <td class="text-right text-xs text-base-content/70">
                      <%= if feed.last_fetched_at do %>
                        {DateTime.to_iso8601(feed.last_fetched_at) |> String.slice(11..18)} UTC
                      <% else %>
                        Pending poll
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <!-- Compute Budget & Alert Query Performance Card -->
        <div
          id="compute-guard-console"
          class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-6"
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
                Telemetry circuit breaker tracking slow or pathological alert queries. Rules exceeding the 30ms/deal evaluation budget are auto-paused to protect server compute.
              </p>
            </div>

            <div class="flex items-center gap-3">
              <div class="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-base-200 border border-base-300 text-xs">
                <span class="text-base-content/70 font-medium">Budget Limit:</span>
                <span class="font-mono font-bold text-primary">30.0 ms / deal</span>
              </div>
              <div class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-xl border text-xs font-semibold",
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
                  class="size-4"
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
                        <td>
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
                        <td class="text-right">
                          <button
                            id={"resume-auto-paused-rule-btn-#{rule.id}"}
                            phx-click="resume_rule"
                            phx-value-id={rule.id}
                            class="btn btn-xs btn-success text-white shadow-xs"
                          >
                            <.icon name="hero-play" class="size-3" /> Re-enable
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
                        <td>
                          <span class="text-xs font-medium text-base-content/80">
                            {if rule.user, do: rule.user.email, else: "User ##{rule.user_id}"}
                          </span>
                        </td>
                        <td>
                          <%= if rule.is_active do %>
                            <span class="badge badge-success badge-xs text-white">Active</span>
                          <% else %>
                            <%= if rule.pause_reason do %>
                              <span class="badge badge-error badge-xs text-white">Auto-Paused</span>
                            <% else %>
                              <span class="badge badge-ghost badge-xs">Paused</span>
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
                        <td class="text-right">
                          <%= if rule.is_active do %>
                            <button
                              id={"pause-slowest-rule-btn-#{rule.id}"}
                              phx-click="pause_rule"
                              phx-value-id={rule.id}
                              class="btn btn-xs btn-outline btn-error"
                            >
                              <.icon name="hero-pause" class="size-3" /> Pause
                            </button>
                          <% else %>
                            <button
                              id={"resume-slowest-rule-btn-#{rule.id}"}
                              phx-click="resume_rule"
                              phx-value-id={rule.id}
                              class="btn btn-xs btn-outline btn-success"
                            >
                              <.icon name="hero-play" class="size-3" /> Re-enable
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

  defp format_duration_ms(nil), do: "—"
  defp format_duration_ms(us) when is_integer(us), do: "#{Float.round(us / 1000, 2)} ms"

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end
