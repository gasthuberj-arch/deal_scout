defmodule DealScoutWeb.DealLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Deals
  alias DealScout.Feeds

  @page_size 30

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
      |> assign(:selected_merchant, "all")
      |> assign(:hide_dropshippers, false)
      |> assign(:group_deals, true)
      |> assign(:min_temperature, nil)
      |> assign(:search_query, "")
      |> assign(:loading, false)
      |> assign(:interstitial_deal, nil)
      |> assign(:page_offset, 0)
      |> assign(:has_more?, true)
      |> stream(:deals, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_feed = params["feed"] || "all"
    selected_merchant = params["merchant"] || "all"
    search_query = params["q"] || ""
    hide_dropshippers = params["no_dropship"] == "true"
    group_deals = params["group"] != "false"

    min_temperature =
      case Integer.parse(params["temp"] || "") do
        {val, ""} -> val
        _ -> nil
      end

    socket =
      socket
      |> assign(:selected_feed, selected_feed)
      |> assign(:selected_merchant, selected_merchant)
      |> assign(:search_query, search_query)
      |> assign(:hide_dropshippers, hide_dropshippers)
      |> assign(:group_deals, group_deals)
      |> assign(:min_temperature, min_temperature)
      |> load_deals()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch_with_filters(socket, %{q: query})}
  end

  @impl true
  def handle_event("select_feed", %{"slug" => slug}, socket) do
    overrides =
      if slug != "mydealz-hot" and socket.assigns.min_temperature do
        %{feed: slug, temp: nil}
      else
        %{feed: slug}
      end

    {:noreply, push_patch_with_filters(socket, overrides)}
  end

  @impl true
  def handle_event("select_merchant", %{"slug" => slug}, socket) do
    new_merchant = if socket.assigns.selected_merchant == slug, do: "all", else: slug
    {:noreply, push_patch_with_filters(socket, %{merchant: new_merchant})}
  end

  @impl true
  def handle_event("clear_merchant", _params, socket) do
    {:noreply, push_patch_with_filters(socket, %{merchant: "all"})}
  end

  @impl true
  def handle_event("toggle_dropshippers", _params, socket) do
    new_val = !socket.assigns.hide_dropshippers

    {:noreply,
     push_patch_with_filters(socket, %{no_dropship: if(new_val, do: "true", else: "false")})}
  end

  @impl true
  def handle_event("toggle_group_deals", _params, socket) do
    new_val = !socket.assigns.group_deals

    {:noreply, push_patch_with_filters(socket, %{group: if(new_val, do: "true", else: "false")})}
  end

  @impl true
  def handle_event("set_min_temp", %{"temp" => temp_str}, socket) do
    val = if temp_str == "all" || temp_str == "", do: nil, else: temp_str
    {:noreply, push_patch_with_filters(socket, %{temp: val})}
  end

  @impl true
  def handle_event("open_high_risk_modal", %{"id" => deal_id}, socket) do
    deal = Deals.get_deal!(deal_id)
    {:noreply, assign(socket, :interstitial_deal, deal)}
  end

  @impl true
  def handle_event("dismiss_interstitial", _params, socket) do
    {:noreply, assign(socket, :interstitial_deal, nil)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more? do
      new_offset = socket.assigns.page_offset + @page_size
      more_deals = Deals.list_deals(stream_filter_opts(socket.assigns, new_offset))
      has_more? = length(more_deals) >= @page_size

      {:noreply,
       socket
       |> assign(:page_offset, new_offset)
       |> assign(:has_more?, has_more?)
       |> stream(:deals, more_deals)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_deal, deal}, socket) do
    if Deals.matches_stream?(deal, stream_filter_opts(socket.assigns, 0)) do
      {:noreply, stream_insert(socket, :deals, deal, at: 0)}
    else
      {:noreply, socket}
    end
  end

  defp push_patch_with_filters(socket, overrides) do
    assigns = socket.assigns

    feed = Map.get(overrides, :feed, assigns.selected_feed)
    merchant = Map.get(overrides, :merchant, assigns.selected_merchant)
    query = Map.get(overrides, :q, assigns.search_query)

    no_dropship =
      Map.get(
        overrides,
        :no_dropship,
        if(assigns.hide_dropshippers, do: "true", else: "false")
      )

    group =
      Map.get(
        overrides,
        :group,
        if(assigns.group_deals, do: "true", else: "false")
      )

    temp =
      Map.get(
        overrides,
        :temp,
        if(assigns.min_temperature, do: to_string(assigns.min_temperature), else: nil)
      )

    params =
      [
        {"feed", feed != "all" && feed},
        {"merchant", merchant != "all" && merchant},
        {"q", query != "" && query},
        {"no_dropship", no_dropship == "true" && "true"},
        {"group", group == "false" && "false"},
        {"temp", temp}
      ]
      |> Enum.reject(fn {_k, v} -> !v end)
      |> URI.encode_query()

    decoded = URI.decode_query(params)

    if map_size(decoded) > 0 do
      push_patch(socket, to: ~p"/?#{decoded}")
    else
      push_patch(socket, to: ~p"/")
    end
  end

  defp load_deals(socket) do
    deals = Deals.list_deals(stream_filter_opts(socket.assigns, 0))

    socket
    |> assign(:page_offset, 0)
    |> assign(:has_more?, length(deals) >= @page_size)
    |> stream(:deals, deals, reset: true)
  end

  defp stream_filter_opts(assigns, offset) do
    [
      search: assigns.search_query,
      feed: assigns.selected_feed,
      merchant: assigns.selected_merchant,
      exclude_dropshippers: assigns.hide_dropshippers,
      min_temperature: assigns.min_temperature,
      group_deals: assigns.group_deals,
      limit: @page_size,
      offset: offset
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <!-- Filter & Search Toolbar (Classic Setup) -->
        <div class="space-y-3">
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

          <!-- Secondary Filters Row: Search, Temperature & Dropshipper Guard -->
          <div class="flex flex-col lg:flex-row gap-3 items-stretch lg:items-center justify-between bg-base-100 p-3 rounded-xl border border-base-200">
            <!-- Left: Search Bar -->
            <div class="w-full lg:w-72">
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
                  <.icon
                    name="hero-magnifying-glass"
                    class="size-4 absolute left-3 top-2 text-base-content/50"
                  />
                </div>
              </form>
            </div>

            <!-- Right: Filter Toggles -->
            <div class="flex flex-wrap items-center gap-2">
              <%= if @selected_feed == "mydealz-hot" || not is_nil(@min_temperature) do %>
                <div class="join border border-base-300 rounded-lg overflow-hidden">
                  <button
                    phx-click="set_min_temp"
                    phx-value-temp="all"
                    class={[
                      "join-item btn btn-xs",
                      is_nil(@min_temperature) && "btn-primary",
                      not is_nil(@min_temperature) && "btn-ghost"
                    ]}
                  >
                    All Temp
                  </button>
                  <button
                    phx-click="set_min_temp"
                    phx-value-temp="50"
                    class={[
                      "join-item btn btn-xs",
                      @min_temperature == 50 && "btn-primary",
                      @min_temperature != 50 && "btn-ghost"
                    ]}
                  >
                    🔥 50°+
                  </button>
                  <button
                    phx-click="set_min_temp"
                    phx-value-temp="100"
                    class={[
                      "join-item btn btn-xs",
                      @min_temperature == 100 && "btn-primary",
                      @min_temperature != 100 && "btn-ghost"
                    ]}
                  >
                    🔥 100°+
                  </button>
                  <button
                    phx-click="set_min_temp"
                    phx-value-temp="200"
                    class={[
                      "join-item btn btn-xs",
                      @min_temperature == 200 && "btn-primary",
                      @min_temperature != 200 && "btn-ghost"
                    ]}
                  >
                    🔥 200°+
                  </button>
                </div>
              <% end %>

              <button
                phx-click="toggle_dropshippers"
                class={[
                  "btn btn-xs rounded-lg gap-1",
                  @hide_dropshippers && "btn-warning",
                  !@hide_dropshippers && "btn-ghost border border-base-300"
                ]}
                title="Hide marketplace dropshippers"
              >
                <.icon name="hero-shield-check" class="size-3.5" />
                <span>Hide Dropshippers</span>
              </button>

              <button
                phx-click="toggle_group_deals"
                class={[
                  "btn btn-xs rounded-lg gap-1",
                  @group_deals && "btn-neutral",
                  !@group_deals && "btn-ghost border border-base-300"
                ]}
                title="Consolidate duplicate deals"
              >
                <.icon name="hero-squares-plus" class="size-3.5" />
                <span>Group Duplicates</span>
              </button>

              <%= if @selected_merchant != "all" do %>
                <div class="badge badge-primary gap-1 py-3 px-2 text-xs font-semibold">
                  <span>Merchant: {@selected_merchant}</span>
                  <button
                    phx-click="clear_merchant"
                    class="btn btn-ghost btn-circle btn-xs size-4 min-h-0"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Deals Stream Grid (Classic Setup) -->
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
                <div class="flex items-center justify-between text-xs text-base-content/60">
                  <div class="flex items-center gap-1.5 flex-wrap">
                    <span class="inline-flex items-center text-xs font-semibold px-2 py-0.5 rounded-md border tracking-tight shadow-xs bg-base-200 border-base-300">
                      {if deal.feed, do: deal.feed.name, else: "Deal"}
                    </span>
                    <%= if deal.temperature do %>
                      <span class="inline-flex items-center gap-1 text-xs font-bold px-2 py-0.5 rounded-md border shadow-xs bg-amber-500/20 text-amber-700 dark:text-amber-300 border-amber-500/40">
                        <.icon name="hero-fire" class="size-3" />
                        {deal.temperature}°
                      </span>
                    <% end %>
                    <%= if deal.country do %>
                      <% country_flag = deal.country[:flag] || deal.country["flag"] %>
                      <% country_name = deal.country[:name] || deal.country["name"] %>
                      <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-md border border-base-300 bg-base-200/60 text-base-content/80 shadow-xs">
                        <span>{country_flag}</span>
                        <span>{country_name}</span>
                      </span>
                    <% end %>
                  </div>
                  <span>{format_time_ago(deal.published_at)}</span>
                </div>

                <!-- Foreign Keyboard Layout Warning Banner -->
                <%= if deal.keyboard_warning do %>
                  <% kb_message = deal.keyboard_warning[:message] || deal.keyboard_warning["message"] %>
                  <div class="bg-amber-500/10 border border-amber-500/30 text-amber-700 dark:text-amber-400 px-2.5 py-1.5 rounded-lg text-xs font-semibold flex items-center gap-1.5">
                    <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-amber-500" />
                    <span>Foreign Keyboard Layout: {kb_message}</span>
                  </div>
                <% end %>

                <div class="flex gap-4">
                  <.deal_image
                    src={deal.image_url}
                    alt={deal.title}
                    class="size-20 shrink-0"
                    img_class="group-hover:scale-105 transition-transform"
                  />
                  <div class="space-y-1 flex-1 min-w-0">
                    <h2 class="font-bold text-xs sm:text-sm leading-snug line-clamp-2 text-base-content group-hover:text-primary transition-colors">
                      <a href={deal.url} target="_blank" rel="noopener noreferrer">
                        {deal.title}
                      </a>
                    </h2>

                    <div class="flex flex-wrap items-center gap-2 pt-1">
                      <%= if deal.price do %>
                        <span class="text-base font-black text-emerald-600 dark:text-emerald-400 bg-emerald-500/10 px-2 py-0.5 rounded-md">
                          {deal.price} €
                        </span>
                      <% end %>

                      <%= if deal.merchant do %>
                        <button
                          type="button"
                          phx-click="select_merchant"
                          phx-value-slug={deal.merchant.slug}
                          class="inline-flex items-center gap-1 text-xs font-semibold px-2 py-0.5 rounded-md border bg-base-200 text-base-content/80 border-base-300"
                        >
                          <.icon name={merchant_icon(deal.merchant.trust_level)} class="size-3" />
                          <span>{deal.merchant.name}</span>
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%= if deal.clean_text && deal.clean_text != "" do %>
                  <p class="text-xs text-base-content/70 line-clamp-2 leading-relaxed">
                    {deal.clean_text}
                  </p>
                <% end %>

                <!-- Duplicate Deals Pills -->
                <%= if Ecto.assoc_loaded?(deal.duplicates) && deal.duplicates != [] do %>
                  <div class="pt-2 flex flex-wrap items-center gap-1.5 border-t border-base-200/60">
                    <span class="text-[11px] font-medium text-base-content/60">Also on:</span>
                    <%= for dup <- deal.duplicates do %>
                      <a
                        href={dup.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-all text-[11px]"
                        title={"Open offer on #{if dup.feed, do: dup.feed.name, else: "portal"}"}
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="size-2.5 opacity-60" />
                        <span>{if dup.feed, do: dup.feed.name, else: "Other"}</span>
                        <%= if dup.price do %>
                          <span class="font-semibold text-emerald-600 dark:text-emerald-400">· {dup.price} €</span>
                        <% end %>
                      </a>
                    <% end %>
                  </div>
                <% end %>

                <!-- Comparison Links (Idealo & Geizhals) -->
                <%= if deal.idealo_url || deal.geizhals_url do %>
                  <div class="pt-2 flex flex-wrap items-center gap-1.5 border-t border-base-200/60">
                    <%= if deal.idealo_url do %>
                      <a
                        href={deal.idealo_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-xs btn-outline border-blue-500/30 hover:bg-blue-500/10 text-blue-600 dark:text-blue-400 gap-1 rounded-lg"
                        title="Open verified Idealo price comparison & 1-year price chart"
                      >
                        <.icon name="hero-chart-bar" class="size-3" />
                        <span>Idealo Chart</span>
                      </a>
                    <% end %>

                    <%= if deal.geizhals_url do %>
                      <a
                        href={deal.geizhals_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-xs btn-outline border-orange-500/30 hover:bg-orange-500/10 text-orange-600 dark:text-orange-400 gap-1 rounded-lg"
                        title="Open verified Geizhals price history & specs"
                      >
                        <.icon name="hero-arrow-trending-up" class="size-3" />
                        <span>Geizhals History</span>
                      </a>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="p-4 pt-0">
                <%= if deal.merchant && deal.merchant.trust_level == "high_risk" do %>
                  <button
                    type="button"
                    phx-click="open_high_risk_modal"
                    phx-value-id={deal.id}
                    class="btn btn-xs btn-error gap-1 text-white shadow-sm w-full"
                  >
                    <.icon name="hero-shield-exclamation" class="size-3" />
                    <span>Open Deal</span>
                  </button>
                <% else %>
                  <a
                    href={deal.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn btn-xs btn-primary w-full gap-1"
                  >
                    <span>Open Deal</span>
                    <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </a>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Infinite Scroll Sentinel -->
        <div
          id="infinite-scroll-marker"
          phx-hook=".InfiniteScroll"
          class="py-8 flex flex-col items-center justify-center gap-2"
        >
          <%= if @has_more? do %>
            <button
              phx-click="load_more"
              class="btn btn-ghost btn-sm text-base-content/60 gap-2 border border-base-300"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
              <span>Loading more deals...</span>
            </button>
          <% else %>
            <div class="text-xs text-base-content/40 font-medium py-4 flex items-center gap-1.5">
              <.icon name="hero-check-circle" class="size-4 text-emerald-500" />
              <span>You have caught up with all live deals</span>
            </div>
          <% end %>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".InfiniteScroll">
          export default {
            mounted() {
              this.observer = new IntersectionObserver((entries) => {
                const target = entries[0];
                if (target && target.isIntersecting) {
                  this.pushEvent("load_more", {});
                }
              }, { threshold: 0.1, rootMargin: "250px" });
              this.observer.observe(this.el);
            },
            destroyed() {
              if (this.observer) this.observer.disconnect();
            }
          }
        </script>

        <!-- Safety Interstitial Modal for High-Risk Deals -->
        <%= if @interstitial_deal do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm">
            <div class="card bg-base-100 w-full max-w-md shadow-2xl border-2 border-error">
              <div class="p-6 space-y-4">
                <div class="flex items-center gap-3 text-error">
                  <div class="size-12 rounded-full bg-error/10 flex items-center justify-center shrink-0">
                    <.icon name="hero-shield-exclamation" class="size-7" />
                  </div>
                  <div>
                    <h3 class="font-bold text-lg text-base-content">Security Notice</h3>
                    <p class="text-xs text-error font-semibold">Unverified or Flagged Merchant</p>
                  </div>
                </div>

                <div class="p-3 bg-base-200/60 rounded-xl space-y-2 text-xs text-base-content/80">
                  <p>
                    You are leaving DealScout for:
                    <strong class="text-base-content">
                      {if @interstitial_deal.merchant,
                        do: @interstitial_deal.merchant.name,
                        else: "External Merchant"}
                    </strong>
                    ({URI.parse(@interstitial_deal.url).host})
                  </p>
                  <ul class="list-disc list-inside space-y-1 text-base-content/70">
                    <li>Always check the legal shop <strong>Impressum</strong>.</li>
                    <li>
                      <strong>Never pay via direct bank transfer ("Vorkasse")</strong>
                      to unverified sellers.
                    </li>
                    <li>
                      Always use payment methods offering buyer protection (PayPal, credit card).
                    </li>
                  </ul>
                </div>

                <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
                  <button
                    phx-click="dismiss_interstitial"
                    class="btn btn-sm btn-ghost"
                  >
                    Stay on DealScout
                  </button>
                  <a
                    href={@interstitial_deal.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    phx-click="dismiss_interstitial"
                    class="btn btn-sm btn-error text-white gap-1"
                  >
                    <span>Proceed to Merchant</span>
                    <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                  </a>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp merchant_icon("verified"), do: "hero-check-badge"
  defp merchant_icon("high_risk"), do: "hero-exclamation-triangle"
  defp merchant_icon("dropshipper"), do: "hero-archive-box"
  defp merchant_icon(_), do: "hero-building-storefront"

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
