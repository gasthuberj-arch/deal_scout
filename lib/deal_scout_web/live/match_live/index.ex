defmodule DealScoutWeb.MatchLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Alerts
  alias DealScout.Deals.CrossBorderGuard
  alias DealScoutWeb.PWAComponents
  alias DealScoutWeb.PushNotificationHandler

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      Alerts.subscribe_to_user_matches(user.id)
    end

    socket =
      socket
      |> assign(:page_title, "Matched Deals")
      |> assign(:unread_only, false)
      |> assign(:sound_enabled, true)
      |> assign(:highlight_id, nil)
      |> PushNotificationHandler.init_push_assigns()
      |> load_matches()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    unread_only = params["unread"] == "true"
    highlight_id = params["highlight"]

    socket =
      socket
      |> assign(:unread_only, unread_only)
      |> assign(:highlight_id, highlight_id)
      |> load_matches()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_unread_filter", _params, socket) do
    new_state = !socket.assigns.unread_only
    {:noreply, push_patch(socket, to: ~p"/matches?unread=#{new_state}")}
  end

  @impl true
  def handle_event("toggle_sound", _params, socket) do
    {:noreply, assign(socket, :sound_enabled, !socket.assigns.sound_enabled)}
  end

  @impl true
  def handle_event("mark_read", %{"id" => match_id}, socket) do
    user = socket.assigns.current_scope.user
    Alerts.mark_match_read(user.id, match_id)

    {:noreply, load_matches(socket)}
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    user = socket.assigns.current_scope.user
    Alerts.mark_all_matches_read(user.id)

    {:noreply,
     socket
     |> put_flash(:info, "All matches marked as read.")
     |> load_matches()}
  end

  @impl true
  def handle_event(event, params, socket)
      when event in [
             "push-status",
             "enable_push_notifications",
             "save-push-subscription",
             "push-permission-denied",
             "push-error",
             "open_ios_modal",
             "close_ios_modal",
             "dismiss_push_banner"
           ] do
    case PushNotificationHandler.handle_push_event(event, params, socket) do
      {:handled, updated_socket} -> {:noreply, updated_socket}
      :unhandled -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_match, match}, socket) do
    socket =
      if socket.assigns.sound_enabled do
        push_event(socket, "play-chime", %{})
      else
        socket
      end

    {:noreply,
     socket
     |> put_flash(:info, "New match: #{match.deal.title}")
     |> load_matches()}
  end

  defp load_matches(socket) do
    user = socket.assigns.current_scope.user
    matches = Alerts.list_user_matches(user.id, unread_only: socket.assigns.unread_only)
    unread_count = Alerts.count_unread_matches(user.id)

    socket
    |> assign(:matches, matches)
    |> assign(:unread_count, unread_count)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6" id="match-inbox" phx-hook="AudioChimeHook">
        <!-- PWA Smart Install / Push Banner -->
        <PWAComponents.push_install_banner
          push_subscribed={@push_subscribed}
          push_supported={@push_supported}
          is_ios={@is_ios}
          is_standalone={@is_standalone}
          show_ios_modal={@show_ios_modal}
          dismissed={@banner_dismissed}
        />

        <!-- Header -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight flex items-center gap-3">
              <span>Matched Deals</span>
              <%= if @unread_count > 0 do %>
                <span class="badge badge-primary font-bold">
                  {@unread_count} new
                </span>
              <% end %>
            </h1>
            <p class="text-sm text-base-content/70 mt-1">
              Deals that matched your configured keyword alert criteria in real-time.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <!-- Audio Chime Toggle -->
            <button
              phx-click="toggle_sound"
              class={[
                "btn btn-xs sm:btn-sm gap-1.5",
                @sound_enabled && "btn-neutral",
                !@sound_enabled && "btn-ghost text-base-content/50"
              ]}
              title="Toggle audio notification"
            >
              <%= if @sound_enabled do %>
                <.icon name="hero-speaker-wave" class="size-4 text-emerald-400" />
                <span>Chime On</span>
              <% else %>
                <.icon name="hero-speaker-x-mark" class="size-4" />
                <span>Muted</span>
              <% end %>
            </button>

            <!-- Filter Unread -->
            <button
              phx-click="toggle_unread_filter"
              class={[
                "btn btn-xs sm:btn-sm",
                @unread_only && "btn-neutral",
                !@unread_only && "btn-ghost"
              ]}
            >
              {if @unread_only, do: "Show All", else: "Unread Only"}
            </button>

            <%= if @unread_count > 0 do %>
              <button
                phx-click="mark_all_read"
                class="btn btn-xs sm:btn-sm btn-outline"
              >
                Mark all read
              </button>
            <% end %>
          </div>
        </div>

        <!-- Matches List -->
        <%= if Enum.empty?(@matches) do %>
          <div class="text-center py-16 bg-base-100 border border-dashed border-base-300 rounded-2xl p-8 space-y-4">
            <div class="size-14 mx-auto rounded-full bg-base-200 flex items-center justify-center text-base-content/50">
              <.icon name="hero-check" class="size-7" />
            </div>
            <h2 class="text-lg font-bold">Inbox Zero</h2>
            <p class="text-sm text-base-content/70 max-w-md mx-auto">
              No matching deals found for your current filter. As soon as a deal site publishes an item matching your keywords, it will pop up right here!
            </p>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for match <- @matches do %>
              <% country = CrossBorderGuard.detect_country(match.deal)
              keyboard_warn = CrossBorderGuard.keyboard_warning(match.deal) %>
              <div
                id={"match-#{match.id}"}
                class={[
                  "card bg-base-100 border transition-all duration-200",
                  to_string(match.id) == to_string(@highlight_id) &&
                    "ring-2 ring-primary ring-offset-2 shadow-lg",
                  !match.is_read && "border-primary/50 shadow-md bg-primary/5",
                  match.is_read && "border-base-200 opacity-80"
                ]}
              >
                <div class="p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
                  <div class="flex items-start gap-4 flex-1 min-w-0">
                    <.deal_image
                      src={match.deal.image_url}
                      alt={match.deal.title}
                      class="size-16 shrink-0"
                    />

                    <div class="space-y-1.5 flex-1 min-w-0">
                      <div class="flex flex-wrap items-center gap-2 text-xs">
                        <%= if to_string(match.id) == to_string(@highlight_id) do %>
                          <span class="badge badge-primary badge-sm font-bold animate-pulse">
                            Target Deal
                          </span>
                        <% end %>
                        <span class="badge badge-primary badge-sm font-semibold">
                          Rule: {match.alert_rule.name}
                        </span>
                        <span class="badge badge-ghost badge-sm">
                          {if match.deal.feed, do: match.deal.feed.name, else: "Deal"}
                        </span>
                        <%= if country do %>
                          <span
                            class="badge badge-ghost badge-sm gap-1"
                            title={"Origin: #{country.name}"}
                          >
                            <span>{country.flag}</span>
                            <span>{country.code}</span>
                          </span>
                        <% end %>
                        <%= if !match.is_read do %>
                          <span class="badge badge-xs badge-info font-bold uppercase">New</span>
                        <% end %>
                        <span class="text-base-content/50 ml-auto">
                          {format_time_ago(match.inserted_at)}
                        </span>
                      </div>

                      <h2 class="font-bold text-sm sm:text-base leading-snug line-clamp-2">
                        <a
                          href={match.deal.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="hover:text-primary transition-colors"
                        >
                          {match.deal.title}
                        </a>
                      </h2>

                      <!-- Keyboard warning if foreign -->
                      <%= if keyboard_warn do %>
                        <div class="flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400 bg-amber-500/10 px-2 py-1 rounded-lg border border-amber-500/20 font-medium w-fit">
                          <span>{keyboard_warn.flag}</span>
                          <span>{keyboard_warn.message}</span>
                        </div>
                      <% end %>

                      <div class="flex flex-wrap items-center gap-3 text-xs pt-0.5">
                        <%= if match.deal.price do %>
                          <span class="font-extrabold text-sm text-emerald-600 dark:text-emerald-400">
                            {match.deal.price} €
                          </span>
                        <% end %>
                        <%= if match.deal.merchant do %>
                          <span class="text-base-content/70">
                            via {match.deal.merchant.name}
                          </span>
                        <% end %>
                        <%= if match.deal.temperature do %>
                          <span class="text-rose-500 font-semibold">
                            🔥 {match.deal.temperature}°
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="flex flex-wrap items-center gap-2 self-end sm:self-center shrink-0">
                    <!-- Idealo Price Comparison Link -->
                    <%= if match.deal.idealo_url do %>
                      <a
                        href={match.deal.idealo_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-xs btn-outline btn-warning gap-1 font-semibold"
                        title="Compare price history and offers on Idealo"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                        <span>Idealo</span>
                      </a>
                    <% end %>

                    <%= if match.deal.geizhals_url do %>
                      <a
                        href={match.deal.geizhals_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-xs btn-outline btn-info gap-1 font-semibold"
                        title="Compare offers on Geizhals"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                        <span>Geizhals</span>
                      </a>
                    <% end %>

                    <%= if !match.is_read do %>
                      <button
                        phx-click="mark_read"
                        phx-value-id={match.id}
                        class="btn btn-xs btn-ghost"
                        title="Mark as read"
                      >
                        Mark read
                      </button>
                    <% end %>

                    <a
                      href={match.deal.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="btn btn-xs btn-primary gap-1"
                    >
                      <span>Open Deal</span>
                      <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                    </a>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

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
