defmodule DealScoutWeb.Admin.SystemLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Analytics
  alias DealScout.Feeds.Poller

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DealScoutWeb.Endpoint.subscribe("deals:presence")
    end

    ops = Analytics.get_system_ops_stats()

    socket =
      socket
      |> assign(:page_title, "Admin System & Operational Health")
      |> assign(:ops, ops)

    {:ok, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "deals:presence"}, socket) do
    ops = Analytics.get_system_ops_stats()
    {:noreply, assign(socket, :ops, ops)}
  end

  @impl true
  def handle_event("refresh_metrics", _params, socket) do
    ops = Analytics.get_system_ops_stats()

    {:noreply,
     socket
     |> assign(:ops, ops)
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
                      <%= if feed.is_active do %>
                        <span class="badge badge-success badge-xs text-white">Active</span>
                      <% else %>
                        <span class="badge badge-ghost badge-xs">Disabled</span>
                      <% end %>
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
      </div>
    </Layouts.app>
    """
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
end
