defmodule DealScoutWeb.DealLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Deals
  alias DealScout.Feeds
  alias DealScout.Feeds.Poller

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Deals.subscribe()
    end

    feeds = Feeds.list_active_feeds()

    socket =
      socket
      |> assign(:page_title, "Live Deals Stream")
      |> assign(:feeds, feeds)
      |> assign(:selected_feed, "all")
      |> assign(:search_query, "")
      |> assign(:loading, false)
      |> load_deals()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_feed = params["feed"] || "all"
    search_query = params["q"] || ""

    socket =
      socket
      |> assign(:selected_feed, selected_feed)
      |> assign(:search_query, search_query)
      |> load_deals()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> push_patch(to: ~p"/?feed=#{socket.assigns.selected_feed}&q=#{query}")}
  end

  @impl true
  def handle_event("select_feed", %{"slug" => slug}, socket) do
    {:noreply,
     socket
     |> push_patch(to: ~p"/?feed=#{slug}&q=#{socket.assigns.search_query}")}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    Poller.poll_now()

    {:noreply,
     socket
     |> put_flash(:info, "Refreshing all deal feeds...")
     |> assign(:loading, true)}
  end

  @impl true
  def handle_info({:new_deal, deal}, socket) do
    # Only prepend to stream if it matches current filter
    if matches_filters?(deal, socket.assigns.selected_feed, socket.assigns.search_query) do
      {:noreply, stream_insert(socket, :deals, deal, at: 0)}
    else
      {:noreply, socket}
    end
  end

  defp load_deals(socket) do
    feed_id =
      case socket.assigns.selected_feed do
        "all" ->
          nil

        slug ->
          case Enum.find(socket.assigns.feeds, &(&1.slug == slug)) do
            %{id: id} -> id
            _ -> nil
          end
      end

    deals =
      Deals.list_deals(
        search: socket.assigns.search_query,
        feed_id: feed_id,
        limit: 80
      )

    stream(socket, :deals, deals, reset: true)
  end

  defp matches_filters?(deal, selected_feed, search_query) do
    matches_feed? =
      selected_feed == "all" or
        (deal.feed && deal.feed.slug == selected_feed)

    matches_search? =
      search_query == "" or
        String.contains?(String.downcase(deal.title), String.downcase(search_query)) or
        String.contains?(String.downcase(deal.clean_text || ""), String.downcase(search_query))

    matches_feed? and matches_search?
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <!-- Hero & Controls Bar -->
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <h1 class="text-3xl font-extrabold tracking-tight flex items-center gap-2">
              <span>Deal Scout</span>
              <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-emerald-500/10 text-emerald-500">
                <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span> Real-Time
              </span>
            </h1>
            <p class="text-sm text-base-content/70 mt-1">
              Aggregated live feeds from MyDealz, DealDoktor, MonsterDealz, Schnäppchenfuchs, and Mein-Deal.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="refresh_now"
              class="btn btn-primary btn-sm flex items-center gap-2"
              phx-disable-with="Checking feeds..."
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="size-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                />
              </svg>
              Refresh Feeds
            </button>
          </div>
        </div>

        <!-- Filter & Search Toolbar -->
        <div class="flex flex-col sm:flex-row gap-3 items-stretch sm:items-center justify-between">
          <!-- Feed Filter Pills -->
          <div class="flex flex-wrap items-center gap-1.5 overflow-x-auto pb-1">
            <button
              phx-click="select_feed"
              phx-value-slug="all"
              class={[
                "btn btn-xs sm:btn-sm rounded-lg",
                @selected_feed == "all" && "btn-neutral",
                @selected_feed != "all" && "btn-ghost"
              ]}
            >
              All Feeds
            </button>
            <%= for feed <- @feeds do %>
              <button
                phx-click="select_feed"
                phx-value-slug={feed.slug}
                class={[
                  "btn btn-xs sm:btn-sm rounded-lg",
                  @selected_feed == feed.slug && "btn-neutral",
                  @selected_feed != feed.slug && "btn-ghost"
                ]}
              >
                {feed.name}
              </button>
            <% end %>
          </div>

          <!-- Instant Search Input -->
          <div class="w-full sm:w-72">
            <form
              id="deal-search-form"
              phx-change="search"
              phx-submit="search"
              onsubmit="return false;"
            >
              <div class="relative">
                <input
                  type="text"
                  name="q"
                  value={@search_query}
                  placeholder="Search deals (e.g. OLED, RTX 4080)..."
                  class="input input-sm input-bordered w-full pl-9 pr-4 rounded-lg"
                  phx-debounce="300"
                />
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="size-4 absolute left-3 top-2 text-base-content/50"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  />
                </svg>
              </div>
            </form>
          </div>
        </div>

        <!-- Deals Stream Grid -->
        <div
          id="deals-stream"
          phx-update="stream"
          class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5"
        >
          <%= for {dom_id, deal} <- @streams.deals do %>
            <div
              id={dom_id}
              class="card bg-base-100 border border-base-300 hover:border-primary/50 hover:shadow-lg transition-all duration-200 overflow-hidden flex flex-col justify-between group"
            >
              <div class="p-5 space-y-3">
                <!-- Card Header: Feed & Time -->
                <div class="flex items-center justify-between text-xs text-base-content/60">
                  <span class={[
                    "badge badge-sm font-medium",
                    feed_badge_class(deal.feed && deal.feed.slug)
                  ]}>
                    {if deal.feed, do: deal.feed.name, else: "Deal"}
                  </span>
                  <span title={DateTime.to_iso8601(deal.published_at)}>
                    {format_time_ago(deal.published_at)}
                  </span>
                </div>

                <!-- Deal Image & Title Row -->
                <div class="flex gap-4">
                  <%= if deal.image_url do %>
                    <div class="shrink-0">
                      <img
                        src={deal.image_url}
                        alt={deal.title}
                        class="size-20 object-cover rounded-xl border border-base-200 bg-base-200 group-hover:scale-105 transition-transform"
                        loading="lazy"
                        onerror="this.style.display='none'"
                      />
                    </div>
                  <% end %>
                  <div class="space-y-1.5 flex-1 min-w-0">
                    <h2 class="font-bold text-sm sm:text-base leading-snug line-clamp-2 text-base-content group-hover:text-primary transition-colors">
                      <a href={deal.url} target="_blank" rel="noopener noreferrer">
                        {deal.title}
                      </a>
                    </h2>

                    <!-- Price & Merchant Row -->
                    <div class="flex flex-wrap items-center gap-2 pt-1">
                      <%= if deal.price do %>
                        <span class="text-base font-black text-emerald-600 dark:text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded-md">
                          {deal.price} €
                        </span>
                      <% end %>
                      <%= if deal.merchant do %>
                        <span class="text-xs font-semibold px-2 py-0.5 rounded bg-base-200 text-base-content/80">
                          {deal.merchant}
                        </span>
                      <% end %>
                    </div>
                  </div>
                </div>

                <!-- Deal Description Snippet -->
                <%= if deal.clean_text && deal.clean_text != "" do %>
                  <p class="text-xs text-base-content/70 line-clamp-3 leading-relaxed">
                    {deal.clean_text}
                  </p>
                <% end %>
              </div>

              <!-- Card Footer: Direct Link Button -->
              <div class="px-5 py-3 border-t border-base-200 bg-base-50/50 dark:bg-base-200/20 flex items-center justify-between">
                <span class="text-[11px] text-base-content/50 truncate max-w-[200px]">
                  {URI.parse(deal.url).host}
                </span>
                <a
                  href={deal.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-xs btn-primary gap-1"
                >
                  <span>Open Deal</span>
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="size-3"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                    />
                  </svg>
                </a>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp feed_badge_class("mydealz"), do: "badge-info badge-outline"
  defp feed_badge_class("dealdoktor"), do: "badge-success badge-outline"
  defp feed_badge_class("monsterdealz"), do: "badge-warning badge-outline"
  defp feed_badge_class("schnaeppchenfuchs"), do: "badge-secondary badge-outline"
  defp feed_badge_class("mein-deal"), do: "badge-error badge-outline"
  defp feed_badge_class(_), do: "badge-ghost"

  defp format_time_ago(datetime) do
    diff_sec = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_sec < 60 -> "just now"
      diff_sec < 3600 -> "#{div(diff_sec, 60)}m ago"
      diff_sec < 86400 -> "#{div(diff_sec, 3600)}h ago"
      true -> "#{div(diff_sec, 86400)}d ago"
    end
  end
end
