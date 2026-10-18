defmodule DealScoutWeb.MatchLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Alerts

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
      |> load_matches()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    unread_only = params["unread"] == "true"

    socket =
      socket
      |> assign(:unread_only, unread_only)
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
  def handle_info({:new_match, match}, socket) do
    # Play chime via client push_event if enabled
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
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="size-4 text-emerald-400"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15.536 8.464a5 5 0 010 7.072m2.828-9.9a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"
                  />
                </svg>
                <span>Chime On</span>
              <% else %>
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
                    d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"
                  />
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"
                  />
                </svg>
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
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="size-7"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </div>
            <h2 class="text-lg font-bold">Inbox Zero</h2>
            <p class="text-sm text-base-content/70 max-w-md mx-auto">
              No matching deals found for your current filter. As soon as a deal site publishes an item matching your keywords, it will pop up right here!
            </p>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for match <- @matches do %>
              <div class={[
                "card bg-base-100 border transition-all duration-200",
                !match.is_read && "border-primary/50 shadow-md bg-primary/5",
                match.is_read && "border-base-200 opacity-80"
              ]}>
                <div class="p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
                  <div class="flex items-start gap-4 flex-1 min-w-0">
                    <%= if match.deal.image_url do %>
                      <img
                        src={match.deal.image_url}
                        alt={match.deal.title}
                        class="size-16 object-cover rounded-xl border border-base-200 shrink-0"
                        loading="lazy"
                        onerror="this.style.display='none'"
                      />
                    <% end %>

                    <div class="space-y-1.5 flex-1 min-w-0">
                      <div class="flex flex-wrap items-center gap-2 text-xs">
                        <span class="badge badge-primary badge-sm font-semibold">
                          Rule: {match.alert_rule.name}
                        </span>
                        <span class="badge badge-ghost badge-sm">
                          {if match.deal.feed, do: match.deal.feed.name, else: "Deal"}
                        </span>
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

                      <div class="flex items-center gap-3 text-xs">
                        <%= if match.deal.price do %>
                          <span class="font-extrabold text-emerald-600 dark:text-emerald-400">
                            {match.deal.price} €
                          </span>
                        <% end %>
                        <%= if match.deal.merchant do %>
                          <span class="text-base-content/70">
                            via {match.deal.merchant}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="flex items-center gap-2 self-end sm:self-center shrink-0">
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
