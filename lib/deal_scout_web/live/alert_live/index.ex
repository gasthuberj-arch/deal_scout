defmodule DealScoutWeb.AlertLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Feeds

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    feeds = Feeds.list_active_feeds()
    rules = Alerts.list_alert_rules_for_user(user.id)

    socket =
      socket
      |> assign(:page_title, "My Alert Keywords")
      |> assign(:rules, rules)
      |> assign(:feeds, feeds)
      |> assign(:rule, nil)
      |> assign(:form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    rule = %AlertRule{user_id: socket.assigns.current_scope.user.id}
    changeset = Alerts.change_alert_rule(rule)

    socket
    |> assign(:page_title, "New Alert Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = Alerts.get_user_alert_rule!(socket.assigns.current_scope.user.id, id)
    changeset = Alerts.change_alert_rule(rule)

    socket
    |> assign(:page_title, "Edit Alert Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "My Alert Keywords")
    |> assign(:rule, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("save", %{"alert_rule" => rule_params}, socket) do
    user = socket.assigns.current_scope.user

    case socket.assigns.live_action do
      :new ->
        case Alerts.create_alert_rule(user, rule_params) do
          {:ok, _rule} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alert rule created successfully.")
             |> push_navigate(to: ~p"/alerts")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      :edit ->
        case Alerts.update_alert_rule(socket.assigns.rule, rule_params) do
          {:ok, _rule} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alert rule updated successfully.")
             |> push_navigate(to: ~p"/alerts")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    rule = Alerts.get_user_alert_rule!(socket.assigns.current_scope.user.id, id)
    {:ok, _} = Alerts.delete_alert_rule(rule)

    rules = Alerts.list_alert_rules_for_user(socket.assigns.current_scope.user.id)

    {:noreply,
     socket
     |> put_flash(:info, "Alert rule deleted.")
     |> assign(:rules, rules)}
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    rule = Alerts.get_user_alert_rule!(socket.assigns.current_scope.user.id, id)
    {:ok, _} = Alerts.update_alert_rule(rule, %{is_active: !rule.is_active})

    rules = Alerts.list_alert_rules_for_user(socket.assigns.current_scope.user.id)
    {:noreply, assign(socket, :rules, rules)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <!-- Header -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-base-200/50 p-6 rounded-2xl border border-base-300">
          <div>
            <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">Keyword Alert Rules</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Configure search terms, exclusions, and price caps. When new deals hit your criteria, you'll be notified instantly.
            </p>
          </div>

          <.link patch={~p"/alerts/new"} class="btn btn-primary btn-sm flex items-center gap-1">
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
                d="M12 4v16m8-8H4"
              />
            </svg>
            <span>Add Alert Rule</span>
          </.link>
        </div>

        <!-- Rules List -->
        <%= if Enum.empty?(@rules) do %>
          <div class="text-center py-16 bg-base-100 border border-dashed border-base-300 rounded-2xl p-8 space-y-4">
            <div class="size-14 mx-auto rounded-full bg-primary/10 text-primary flex items-center justify-center">
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
                  d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                />
              </svg>
            </div>
            <h2 class="text-lg font-bold">No Alert Rules Configured Yet</h2>
            <p class="text-sm text-base-content/70 max-w-md mx-auto">
              Create an alert rule for products you are hunting (e.g. "RTX 4080", "OLED TV", "Lego Star Wars") to receive instant notifications.
            </p>
            <.link patch={~p"/alerts/new"} class="btn btn-primary btn-sm">
              Create Your First Rule
            </.link>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for rule <- @rules do %>
              <div class={[
                "card bg-base-100 border transition-all duration-200",
                rule.is_active && "border-base-300 shadow-sm",
                !rule.is_active && "border-base-200 opacity-60 bg-base-200/30"
              ]}>
                <div class="p-5 space-y-3">
                  <div class="flex items-center justify-between">
                    <span class={[
                      "badge badge-sm font-semibold",
                      rule.is_active && "badge-success",
                      !rule.is_active && "badge-ghost"
                    ]}>
                      {if rule.is_active, do: "Active", else: "Paused"}
                    </span>
                    <div class="flex items-center gap-1">
                      <button
                        phx-click="toggle_active"
                        phx-value-id={rule.id}
                        class="btn btn-ghost btn-xs"
                        title={if rule.is_active, do: "Pause Alert", else: "Activate Alert"}
                      >
                        {if rule.is_active, do: "Pause", else: "Resume"}
                      </button>
                      <.link patch={~p"/alerts/#{rule.id}/edit"} class="btn btn-ghost btn-xs">
                        Edit
                      </.link>
                      <button
                        phx-click="delete"
                        phx-value-id={rule.id}
                        data-confirm="Are you sure you want to delete this alert rule?"
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Delete
                      </button>
                    </div>
                  </div>

                  <div>
                    <h2 class="font-bold text-base text-base-content">{rule.name}</h2>
                    <div class="mt-2 space-y-1 text-xs">
                      <div>
                        <span class="font-semibold text-base-content/60">Keywords:</span>
                        <span class="font-mono bg-primary/10 text-primary px-1.5 py-0.5 rounded ml-1 font-bold">
                          {rule.keywords}
                        </span>
                      </div>

                      <%= if rule.negative_keywords && rule.negative_keywords != "" do %>
                        <div>
                          <span class="font-semibold text-base-content/60">Exclude:</span>
                          <span class="font-mono bg-error/10 text-error px-1.5 py-0.5 rounded ml-1">
                            {rule.negative_keywords}
                          </span>
                        </div>
                      <% end %>

                      <%= if rule.max_price do %>
                        <div>
                          <span class="font-semibold text-base-content/60">Max Price:</span>
                          <span class="font-semibold text-emerald-600 dark:text-emerald-400 ml-1">
                            {rule.max_price} €
                          </span>
                        </div>
                      <% end %>

                      <div>
                        <span class="font-semibold text-base-content/60">Source:</span>
                        <span class="text-base-content/80 ml-1 uppercase text-[11px] font-mono">
                          {rule.source_filter}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Modal Dialog for New / Edit Rule -->
        <%= if @live_action in [:new, :edit] do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
            <div class="card bg-base-100 w-full max-w-lg shadow-2xl border border-base-300">
              <div class="p-6">
                <div class="flex items-center justify-between pb-4 border-b border-base-200">
                  <h3 class="font-bold text-lg">
                    {if @live_action == :new, do: "Create Alert Rule", else: "Edit Alert Rule"}
                  </h3>
                  <.link patch={~p"/alerts"} class="btn btn-ghost btn-circle btn-sm">✕</.link>
                </div>

                <.form for={@form} phx-submit="save" class="space-y-4 pt-4">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label="Alert Rule Name"
                    placeholder="e.g. RTX 4080 GPU, OLED Monitor, Espresso Machine"
                    required
                  />

                  <.input
                    field={@form[:keywords]}
                    type="text"
                    label="Required Keywords (All words in a group must match)"
                    placeholder="e.g. RTX 4080 or OLED, 4K"
                    required
                  />

                  <.input
                    field={@form[:negative_keywords]}
                    type="text"
                    label="Negative/Exclusion Keywords (optional, comma-separated)"
                    placeholder="e.g. defekt, kühler, zubehör, suche"
                  />

                  <div class="grid grid-cols-2 gap-4">
                    <.input
                      field={@form[:max_price]}
                      type="number"
                      step="0.01"
                      label="Max Price in € (optional)"
                      placeholder="e.g. 799.00"
                    />

                    <.input
                      field={@form[:source_filter]}
                      type="select"
                      label="Source Portal"
                      options={[{"All Portals", "all"} | Enum.map(@feeds, &{&1.name, &1.slug})]}
                    />
                  </div>

                  <.input
                    field={@form[:is_active]}
                    type="checkbox"
                    label="Active immediately"
                  />

                  <div class="flex items-center justify-end gap-2 pt-4 border-t border-base-200">
                    <.link patch={~p"/alerts"} class="btn btn-ghost btn-sm">Cancel</.link>
                    <.button class="btn btn-primary btn-sm">Save Rule</.button>
                  </div>
                </.form>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
