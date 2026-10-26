defmodule DealScoutWeb.Admin.FeedbackLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Feedback

  @impl true
  def mount(_params, _session, socket) do
    counts = Feedback.count_feedbacks_by_status()
    filters = %{"status" => "all", "category" => "all"}
    feedbacks = Feedback.list_feedbacks(filters)

    socket =
      socket
      |> assign(:page_title, "User Feedback Administration")
      |> assign(:filters, filters)
      |> assign(:counts, counts)
      |> assign(:feedbacks_empty?, feedbacks == [])
      |> stream(:feedbacks, feedbacks)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    filters = Map.merge(socket.assigns.filters, filter_params)
    feedbacks = Feedback.list_feedbacks(filters)
    counts = Feedback.count_feedbacks_by_status()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:counts, counts)
     |> assign(:feedbacks_empty?, feedbacks == [])
     |> stream(:feedbacks, feedbacks, reset: true)}
  end

  @impl true
  def handle_event("update_status", %{"id" => id, "status" => new_status}, socket) do
    feedback = Feedback.get_feedback!(id)

    case Feedback.update_feedback_status(feedback, new_status) do
      {:ok, updated} ->
        counts = Feedback.count_feedbacks_by_status()

        {:noreply,
         socket
         |> assign(:counts, counts)
         |> stream_insert(:feedbacks, updated)
         |> put_flash(:info, "Feedback status updated to #{human_status(new_status)}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update feedback status.")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    feedback = Feedback.get_feedback!(id)

    case Feedback.delete_feedback(feedback) do
      {:ok, _deleted} ->
        counts = Feedback.count_feedbacks_by_status()

        {:noreply,
         socket
         |> assign(:counts, counts)
         |> stream_delete(:feedbacks, feedback)
         |> put_flash(:info, "Feedback entry deleted successfully.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete feedback entry.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <div class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-error/10 text-error mb-2">
              <.icon name="hero-shield-check" class="size-3.5" />
              <span>Admin Feedback Triage Console</span>
            </div>
            <h1 class="text-3xl font-extrabold tracking-tight flex items-center gap-2">
              <span>User Feedback &amp; Suggestions</span>
            </h1>
            <p class="text-sm text-base-content/70 mt-1">
              Review issues, scraper reports, and feature requests submitted by signed-in users.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/admin/system"}
              class="btn btn-ghost btn-sm flex items-center gap-1.5 text-base-content/75 hover:text-base-content"
            >
              <.icon name="hero-cpu-chip" class="size-4" /> System Health
            </.link>
          </div>
        </div>

        <%!-- Status Metric Cards --%>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div class="card bg-base-100 border border-base-300 p-4 sm:p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Total Feedback</span>
              <.icon name="hero-inbox-stack" class="size-4 text-primary" />
            </div>
            <div class="text-2xl sm:text-3xl font-black text-base-content">
              {@counts.total}
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 p-4 sm:p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>New</span>
              <span class="size-2 rounded-full bg-blue-500 animate-pulse"></span>
            </div>
            <div class="text-2xl sm:text-3xl font-black text-blue-600 dark:text-blue-400">
              {@counts.new}
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 p-4 sm:p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Under Review</span>
              <.icon name="hero-magnifying-glass" class="size-4 text-amber-500" />
            </div>
            <div class="text-2xl sm:text-3xl font-black text-amber-600 dark:text-amber-400">
              {@counts.under_review}
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 p-4 sm:p-5 rounded-2xl shadow-sm space-y-1">
            <div class="flex items-center justify-between text-base-content/60 text-xs font-semibold uppercase tracking-wider">
              <span>Resolved</span>
              <.icon name="hero-check-circle" class="size-4 text-emerald-500" />
            </div>
            <div class="text-2xl sm:text-3xl font-black text-emerald-600 dark:text-emerald-400">
              {@counts.resolved}
            </div>
          </div>
        </div>

        <%!-- Filter Bar --%>
        <div class="bg-base-100 p-4 rounded-2xl border border-base-300 shadow-sm flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-4">
          <form
            id="feedback-filter-form"
            phx-change="filter"
            class="flex flex-wrap items-center gap-3"
          >
            <div class="flex items-center gap-2">
              <label for="filter-status" class="text-xs font-semibold text-base-content/70 uppercase">Status:</label>
              <select
                id="filter-status"
                name="filters[status]"
                class="select select-sm select-bordered rounded-xl text-xs bg-base-200/50"
              >
                <option value="all" selected={@filters["status"] == "all"}>All Statuses</option>
                <option value="new" selected={@filters["status"] == "new"}>New</option>
                <option value="under_review" selected={@filters["status"] == "under_review"}>
                  Under Review
                </option>
                <option value="resolved" selected={@filters["status"] == "resolved"}>Resolved</option>
                <option value="archived" selected={@filters["status"] == "archived"}>Archived</option>
              </select>
            </div>

            <div class="flex items-center gap-2">
              <label
                for="filter-category"
                class="text-xs font-semibold text-base-content/70 uppercase"
              >Category:</label>
              <select
                id="filter-category"
                name="filters[category]"
                class="select select-sm select-bordered rounded-xl text-xs bg-base-200/50"
              >
                <option value="all" selected={@filters["category"] == "all"}>All Categories</option>
                <option value="bug" selected={@filters["category"] == "bug"}>Bug Reports</option>
                <option value="feature_request" selected={@filters["category"] == "feature_request"}>
                  Feature Requests
                </option>
                <option value="scraper_issue" selected={@filters["category"] == "scraper_issue"}>
                  Scraper / Deal Issues
                </option>
                <option value="other" selected={@filters["category"] == "other"}>
                  General / Other
                </option>
              </select>
            </div>
          </form>
        </div>

        <%!-- Feedback Stream List --%>
        <div id="feedbacks-container" class="space-y-4">
          <div id="feedbacks" phx-update="stream" class="space-y-4">
            <div
              id="feedbacks-empty"
              class="hidden only:block p-12 text-center text-base-content/60 bg-base-100 rounded-2xl border border-dashed border-base-300"
            >
              <.icon name="hero-inbox" class="size-10 mx-auto text-base-content/40 mb-2" />
              <p class="font-medium">No feedback entries found</p>
              <p class="text-xs text-base-content/50 mt-1">
                No user feedback matching current filters.
              </p>
            </div>

            <div
              :for={{id, feedback} <- @streams.feedbacks}
              id={id}
              class="card bg-base-100 border border-base-300 rounded-2xl p-5 shadow-sm space-y-4 hover:border-base-content/20 transition-colors"
            >
              <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2 border-b border-base-200 pb-3">
                <div class="flex flex-wrap items-center gap-2">
                  <%!-- Category Badge --%>
                  <span class={[
                    "inline-flex items-center gap-1 px-2.5 py-1 rounded-lg text-xs font-semibold",
                    category_badge_class(feedback.category)
                  ]}>
                    {category_icon_text(feedback.category)}
                  </span>

                  <%!-- Status Badge --%>
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium uppercase tracking-wider",
                    status_badge_class(feedback.status)
                  ]}>
                    {human_status(feedback.status)}
                  </span>

                  <%!-- Page URL Context --%>
                  <%= if feedback.page_url && feedback.page_url != "" do %>
                    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-xs bg-base-200 text-base-content/70 font-mono">
                      <.icon name="hero-link" class="size-3" />
                      {feedback.page_url}
                    </span>
                  <% end %>
                </div>

                <%!-- User & Timestamp --%>
                <div class="flex items-center gap-3 text-xs text-base-content/60">
                  <div class="flex items-center gap-1.5 font-medium text-base-content/80">
                    <.icon name="hero-user" class="size-3.5 text-base-content/40" />
                    <span>{if feedback.user, do: feedback.user.email, else: "Deleted User"}</span>
                  </div>
                  <span>•</span>
                  <time datetime={DateTime.to_iso8601(feedback.inserted_at)}>
                    {Calendar.strftime(feedback.inserted_at, "%Y-%m-%d %H:%M UTC")}
                  </time>
                </div>
              </div>

              <%!-- Message Content --%>
              <div class="text-sm text-base-content leading-relaxed whitespace-pre-wrap bg-base-200/30 p-4 rounded-xl border border-base-200">
                {feedback.message}
              </div>

              <%!-- Actions Bar --%>
              <div class="flex flex-wrap items-center justify-between gap-3 pt-1">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span class="text-xs text-base-content/50 mr-1">Move to:</span>

                  <%= if feedback.status != "under_review" do %>
                    <button
                      type="button"
                      phx-click="update_status"
                      phx-value-id={feedback.id}
                      phx-value-status="under_review"
                      class="btn btn-ghost btn-xs rounded-lg text-amber-600 dark:text-amber-400 hover:bg-amber-500/10 cursor-pointer"
                    >
                      Under Review
                    </button>
                  <% end %>

                  <%= if feedback.status != "resolved" do %>
                    <button
                      type="button"
                      phx-click="update_status"
                      phx-value-id={feedback.id}
                      phx-value-status="resolved"
                      class="btn btn-ghost btn-xs rounded-lg text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/10 cursor-pointer"
                    >
                      <.icon name="hero-check" class="size-3" /> Mark Resolved
                    </button>
                  <% end %>

                  <%= if feedback.status != "archived" do %>
                    <button
                      type="button"
                      phx-click="update_status"
                      phx-value-id={feedback.id}
                      phx-value-status="archived"
                      class="btn btn-ghost btn-xs rounded-lg text-base-content/60 hover:bg-base-200 cursor-pointer"
                    >
                      Archive
                    </button>
                  <% end %>

                  <%= if feedback.status != "new" do %>
                    <button
                      type="button"
                      phx-click="update_status"
                      phx-value-id={feedback.id}
                      phx-value-status="new"
                      class="btn btn-ghost btn-xs rounded-lg text-blue-600 dark:text-blue-400 hover:bg-blue-500/10 cursor-pointer"
                    >
                      Reopen as New
                    </button>
                  <% end %>
                </div>

                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={feedback.id}
                  data-confirm="Are you sure you want to permanently delete this feedback entry?"
                  class="btn btn-ghost btn-xs text-error hover:bg-error/10 rounded-lg cursor-pointer flex items-center gap-1"
                >
                  <.icon name="hero-trash" class="size-3" /> Delete
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp human_status("new"), do: "New"
  defp human_status("under_review"), do: "Under Review"
  defp human_status("resolved"), do: "Resolved"
  defp human_status("archived"), do: "Archived"
  defp human_status(status), do: status

  defp status_badge_class("new"), do: "bg-blue-500/15 text-blue-700 dark:text-blue-300"

  defp status_badge_class("under_review"),
    do: "bg-amber-500/15 text-amber-700 dark:text-amber-300"

  defp status_badge_class("resolved"),
    do: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-300"

  defp status_badge_class("archived"), do: "bg-base-content/10 text-base-content/60"
  defp status_badge_class(_), do: "bg-base-200 text-base-content"

  defp category_badge_class("bug"), do: "bg-rose-500/15 text-rose-700 dark:text-rose-300"

  defp category_badge_class("feature_request"),
    do: "bg-purple-500/15 text-purple-700 dark:text-purple-300"

  defp category_badge_class("scraper_issue"),
    do: "bg-amber-500/15 text-amber-700 dark:text-amber-300"

  defp category_badge_class(_), do: "bg-sky-500/15 text-sky-700 dark:text-sky-300"

  defp category_icon_text("bug"), do: "🐛 Bug Report"
  defp category_icon_text("feature_request"), do: "💡 Feature Request"
  defp category_icon_text("scraper_issue"), do: "🔍 Deal / Scraper Issue"
  defp category_icon_text(_), do: "💬 General Feedback"
end
