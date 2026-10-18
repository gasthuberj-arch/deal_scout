defmodule DealScoutWeb.AnalyticsLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Analytics

  @impl true
  def mount(_params, _session, socket) do
    stats = Analytics.get_deal_intelligence_stats()

    socket =
      socket
      |> assign(:page_title, "Market Intelligence & Deal Analytics")
      |> assign(:stats, stats)

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    stats = Analytics.get_deal_intelligence_stats()

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> put_flash(:info, "Analytics metrics updated.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <!-- Header -->
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <h1 class="text-3xl font-extrabold tracking-tight flex items-center gap-2">
              <.icon name="hero-chart-bar-square" class="size-8 text-primary" />
              <span>Deal Market Intelligence</span>
            </h1>
            <p class="text-sm text-base-content/70 mt-1">
              Aggregated analytics across portals, cross-border deal origins, community temperatures, and deduplication clusters.
            </p>
          </div>

          <div>
            <button
              phx-click="refresh"
              class="btn btn-primary btn-sm flex items-center gap-2"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh Analytics
            </button>
          </div>
        </div>

        <!-- 4 Key KPI Cards -->
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <!-- Total Deals -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Total Deals Ingested</span>
              <.icon name="hero-tag" class="size-4 text-primary" />
            </div>
            <div class="text-3xl font-black text-base-content">
              {@stats.total_deals}
            </div>
            <p class="text-xs text-base-content/60">
              Across all configured RSS feeds
            </p>
          </div>

          <!-- Duplicates Consolidated -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Duplicates Consolidated</span>
              <.icon name="hero-squares-plus" class="size-4 text-emerald-500" />
            </div>
            <div class="text-3xl font-black text-emerald-600 dark:text-emerald-400">
              {@stats.total_duplicates}
            </div>
            <p class="text-xs text-base-content/60">
              Canonical deals grouped: {@stats.canonical_deals}
            </p>
          </div>

          <!-- Ingestion Velocity (Deals / Hour) -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Ingestion Velocity</span>
              <.icon name="hero-bolt" class="size-4 text-orange-500" />
            </div>
            <div class="text-3xl font-black text-orange-500">
              {@stats.deals_per_hour}
              <span class="text-sm font-semibold text-base-content/60">deals/h</span>
            </div>
            <p class="text-xs text-base-content/60">
              {@stats.deals_last_24h} in 24h · ~{@stats.deals_per_min} /min
            </p>
          </div>

          <!-- Cross-Border & Foreign Keyboards -->
          <div class="card bg-base-100 border border-base-300 p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Cross-Border Deals</span>
              <.icon name="hero-globe-europe-africa" class="size-4 text-blue-500" />
            </div>
            <div class="text-3xl font-black text-blue-500">
              {@stats.cross_border_count}
            </div>
            <p class="text-xs text-amber-600 dark:text-amber-400 font-medium">
              {@stats.foreign_kb_count} flagged foreign layout warnings
            </p>
          </div>
        </div>

        <!-- 2 Column Analytics: Feed Volume Breakdown & Top Merchants -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Feed Breakdown -->
          <div class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-bold flex items-center gap-2">
              <.icon name="hero-rss" class="size-5 text-primary" />
              <span>Deals by Community Source</span>
            </h2>

            <div class="space-y-3">
              <%= for feed_stat <- @stats.deals_by_feed do %>
                <% pct =
                  if @stats.total_deals > 0,
                    do: round(feed_stat.deal_count / @stats.total_deals * 100),
                    else: 0 %>
                <div class="space-y-1">
                  <div class="flex justify-between text-xs font-semibold">
                    <span>{feed_stat.feed_name}</span>
                    <span class="text-base-content/70">{feed_stat.deal_count} deals ({pct}%)</span>
                  </div>
                  <div class="w-full bg-base-200 rounded-full h-2 overflow-hidden">
                    <div
                      class="bg-primary h-2 rounded-full transition-all duration-500"
                      style={"width: #{pct}%;"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Top Hottest Merchants -->
          <div class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-bold flex items-center gap-2">
              <.icon name="hero-building-storefront" class="size-5 text-primary" />
              <span>Top Active Merchants</span>
            </h2>

            <div class="overflow-x-auto">
              <table class="table table-sm w-full">
                <thead>
                  <tr class="text-xs text-base-content/60 border-b border-base-200">
                    <th>Merchant</th>
                    <th>Trust Level</th>
                    <th class="text-right">Total Deals</th>
                    <th class="text-right">Avg Temp</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for m <- @stats.top_merchants do %>
                    <tr class="hover:bg-base-200/40">
                      <td class="font-bold">{m.name}</td>
                      <td>
                        <span class={[
                          "badge badge-xs text-[10px] font-semibold",
                          m.trust_level == "verified" && "badge-success text-white",
                          m.trust_level == "high_risk" && "badge-error text-white",
                          m.trust_level == "dropshipper" && "badge-warning",
                          m.trust_level == "neutral" && "badge-ghost"
                        ]}>
                          {m.trust_level}
                        </span>
                      </td>
                      <td class="text-right font-semibold">{m.deal_count}</td>
                      <td class="text-right font-bold text-orange-500">
                        {if m.avg_temp, do: "#{m.avg_temp}°", else: "—"}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Recent Multi-Portal Duplicate Clusters -->
        <%= if @stats.recent_duplicate_clusters != [] do %>
          <div class="card bg-base-100 border border-base-300 rounded-2xl p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-bold flex items-center gap-2">
              <.icon name="hero-arrows-pointing-in" class="size-5 text-emerald-500" />
              <span>Cross-Portal Duplicate Clusters</span>
            </h2>
            <p class="text-xs text-base-content/70">
              Deals identified by DealScout's ASIN matching & token similarity engine as identical offers posted across portals.
            </p>

            <div class="overflow-x-auto">
              <table class="table table-sm w-full">
                <thead>
                  <tr class="text-xs text-base-content/60 border-b border-base-200">
                    <th>Canonical Product Offer</th>
                    <th>Price</th>
                    <th class="text-right">Portals Spotting Offer</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for cluster <- @stats.recent_duplicate_clusters do %>
                    <tr class="hover:bg-base-200/40">
                      <td class="font-bold max-w-md truncate">{cluster.title}</td>
                      <td class="font-bold text-emerald-600 dark:text-emerald-400">
                        {if cluster.price, do: "#{cluster.price} €", else: "—"}
                      </td>
                      <td class="text-right">
                        <span class="badge badge-sm badge-neutral gap-1">
                          <.icon name="hero-squares-plus" class="size-3 text-emerald-400" />
                          <span>+{cluster.duplicate_count} duplicates</span>
                        </span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
