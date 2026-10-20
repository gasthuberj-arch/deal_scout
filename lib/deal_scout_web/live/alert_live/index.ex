defmodule DealScoutWeb.AlertLive.Index do
  use DealScoutWeb, :live_view

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Feeds
  alias DealScoutWeb.PWAComponents
  alias DealScoutWeb.PushNotificationHandler

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
      |> PushNotificationHandler.init_push_assigns()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    rule = %AlertRule{
      user_id: socket.assigns.current_scope.user.id,
      exclude_dropshippers: true,
      notify_push: true,
      notify_email: false,
      delivery_mode: "instant",
      country_filter: "all",
      exclude_foreign_keyboards: false,
      merchant_filter: "all",
      cooldown_minutes: 0,
      is_active: true
    }

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
  def handle_event("validate", %{"alert_rule" => rule_params}, socket) do
    changeset =
      case socket.assigns.rule do
        nil ->
          %AlertRule{user_id: socket.assigns.current_scope.user.id}
          |> Alerts.change_alert_rule(rule_params)
          |> Map.put(:action, :validate)

        %AlertRule{} = rule ->
          rule
          |> Alerts.change_alert_rule(rule_params)
          |> Map.put(:action, :validate)
      end

    {:noreply, assign(socket, :form, to_form(changeset))}
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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
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
            <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">Keyword Alert Rules</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Configure search terms, exact phrases ("quoted"), region filters, and notifications. When hot deals match, you'll be alerted immediately on your phone.
            </p>
          </div>

          <.link
            patch={~p"/alerts/new"}
            class="btn btn-primary btn-sm flex items-center gap-1 shadow-sm"
          >
            <.icon name="hero-plus" class="size-4" />
            <span>Add Alert Rule</span>
          </.link>
        </div>

        <!-- Rules List -->
        <%= if Enum.empty?(@rules) do %>
          <div class="text-center py-16 bg-base-100 border border-dashed border-base-300 rounded-2xl p-8 space-y-4">
            <div class="size-14 mx-auto rounded-full bg-primary/10 text-primary flex items-center justify-center">
              <.icon name="hero-bell" class="size-7" />
            </div>
            <h2 class="text-lg font-bold">No Alert Rules Configured Yet</h2>
            <p class="text-sm text-base-content/70 max-w-md mx-auto">
              Create an alert rule for products you are hunting (e.g. "RTX 4080", "OLED TV", "Lego Star Wars") to receive instant phone notifications.
            </p>
            <.link patch={~p"/alerts/new"} class="btn btn-primary btn-sm">
              Create Your First Rule
            </.link>
          </div>
        <% else %>
          <div id="rules" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for rule <- @rules do %>
              <div
                id={"rule-#{rule.id}"}
                class={[
                  "card bg-base-100 border transition-all duration-200",
                  rule.is_active && "border-base-300 shadow-sm",
                  !rule.is_active && "border-base-200 opacity-60 bg-base-200/30"
                ]}
              >
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
                    <div class="mt-2 space-y-1.5 text-xs">
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

                      <!-- Filter Badges -->
                      <div class="flex flex-wrap items-center gap-1.5 pt-2">
                        <!-- Channels & Mode -->
                        <%= if rule.notify_push do %>
                          <span class="px-2 py-0.5 rounded bg-indigo-500/10 text-indigo-600 dark:text-indigo-400 font-semibold flex items-center gap-1">
                            <.icon name="hero-device-phone-mobile" class="size-3" />
                            <span>Push</span>
                          </span>
                        <% end %>

                        <%= if rule.notify_email do %>
                          <span class="px-2 py-0.5 rounded bg-blue-500/10 text-blue-600 dark:text-blue-400 font-semibold flex items-center gap-1">
                            <.icon name="hero-envelope" class="size-3" />
                            <span>Email</span>
                          </span>
                        <% end %>

                        <span class="px-2 py-0.5 rounded bg-amber-500/10 text-amber-600 dark:text-amber-400 font-semibold">
                          <%= case rule.delivery_mode do %>
                            <% "instant" -> %>
                              ⚡ Instant
                            <% "hourly_digest" -> %>
                              ⏱️ Hourly Digest
                            <% "daily_digest" -> %>
                              📅 Daily Digest
                            <% other -> %>
                              {other}
                          <% end %>
                        </span>

                        <!-- Country Filter -->
                        <%= if rule.country_filter == "de_only" do %>
                          <span class="px-2 py-0.5 rounded bg-base-200 text-base-content/80 font-semibold">
                            🇩🇪 DE Only
                          </span>
                        <% end %>

                        <%= if rule.country_filter == "eu_only" do %>
                          <span class="px-2 py-0.5 rounded bg-base-200 text-base-content/80 font-semibold">
                            🇪🇺 EU Only
                          </span>
                        <% end %>

                        <%= if rule.exclude_foreign_keyboards do %>
                          <span class="px-2 py-0.5 rounded bg-purple-500/10 text-purple-600 dark:text-purple-400 font-semibold">
                            ⌨️ DE Layout
                          </span>
                        <% end %>

                        <%= if rule.merchant_filter == "verified_only" do %>
                          <span class="px-2 py-0.5 rounded bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 font-semibold">
                            🛡️ Verified Stores
                          </span>
                        <% end %>

                        <%= if rule.cooldown_minutes > 0 do %>
                          <span class="px-2 py-0.5 rounded bg-base-200 text-base-content/70 font-mono text-[10px]">
                            ⏳ {rule.cooldown_minutes}m cooldown
                          </span>
                        <% end %>

                        <%= if rule.max_price do %>
                          <span class="px-2 py-0.5 rounded bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 font-semibold">
                            Max {rule.max_price} €
                          </span>
                        <% end %>

                        <%= if rule.min_temperature do %>
                          <span class="px-2 py-0.5 rounded bg-rose-500/10 text-rose-600 dark:text-rose-400 font-semibold">
                            🔥 ≥ {rule.min_temperature}°
                          </span>
                        <% end %>

                        <%= if rule.exclude_dropshippers do %>
                          <span class="px-2 py-0.5 rounded bg-blue-500/10 text-blue-600 dark:text-blue-400 font-semibold">
                            🚫 No Dropshippers
                          </span>
                        <% end %>

                        <span class="px-2 py-0.5 rounded bg-base-200 text-base-content/70 uppercase text-[10px] font-mono">
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
          <div
            id="alert-rule-modal"
            class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm overflow-hidden"
            role="dialog"
            aria-modal="true"
          >
            <div class="card bg-base-100 w-full max-w-xl max-h-[90vh] shadow-2xl border border-base-300 flex flex-col overflow-hidden my-auto">
              <!-- Modal Header (fixed/sticky) -->
              <div class="flex items-center justify-between px-6 py-4 border-b border-base-200 shrink-0 bg-base-100">
                <h3 class="font-bold text-lg text-base-content flex items-center gap-2">
                  <.icon name="hero-bell" class="size-5 text-primary" />
                  <span>{if @live_action == :new, do: "Create Alert Rule", else: "Edit Alert Rule"}</span>
                </h3>
                <.link
                  patch={~p"/alerts"}
                  id="close-rule-modal-btn"
                  class="btn btn-ghost btn-circle btn-sm"
                  aria-label="Close"
                >
                  ✕
                </.link>
              </div>

              <!-- Form with phx-change, phx-submit, explicit ID, autofill disabled -->
              <.form
                for={@form}
                id="alert-rule-form"
                phx-change="validate"
                phx-submit="save"
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                class="flex flex-col flex-1 min-h-0"
              >
                <!-- Scrollable Body for all inputs -->
                <div class="overflow-y-auto px-6 py-4 space-y-4 flex-1">
                  <.input
                    field={@form[:name]}
                    id="alert-rule-name-input"
                    type="text"
                    label="Alert Rule Name"
                    placeholder="e.g. RTX 4080 GPU, OLED Monitor, Espresso Machine"
                    autocomplete="off"
                    data-1p-ignore="true"
                    data-lpignore="true"
                    required
                  />

                  <.input
                    field={@form[:keywords]}
                    id="alert-rule-keywords-input"
                    type="text"
                    label="Search Keywords (use quotes for exact phrases: &quot;Apple Watch&quot;)"
                    placeholder="e.g. &quot;RTX 4080&quot; or OLED, 4K"
                    autocomplete="off"
                    data-1p-ignore="true"
                    data-lpignore="true"
                    required
                  />

                  <.input
                    field={@form[:negative_keywords]}
                    id="alert-rule-negative-keywords-input"
                    type="text"
                    label="Negative/Exclusion Keywords (optional, comma-separated)"
                    placeholder="e.g. defekt, kühler, zubehör, suche"
                    autocomplete="off"
                    data-1p-ignore="true"
                    data-lpignore="true"
                  />

                  <!-- Channels and Delivery Mode -->
                  <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 space-y-3">
                    <h4 class="font-bold text-xs uppercase tracking-wider text-base-content/70">
                      Notification Delivery & Channels
                    </h4>

                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                      <.input
                        field={@form[:delivery_mode]}
                        id="alert-rule-delivery-mode-select"
                        type="select"
                        label="Delivery Mode"
                        options={[
                          {"⚡ Instant (Alert immediately on match)", "instant"},
                          {"⏱️ Hourly Digest (Batch matches once/hr)", "hourly_digest"},
                          {"📅 Daily Digest (Batch matches once/day)", "daily_digest"}
                        ]}
                      />

                      <.input
                        field={@form[:cooldown_minutes]}
                        id="alert-rule-cooldown-select"
                        type="select"
                        label="Alert Cooldown (prevent bursts)"
                        options={[
                          {"Immediate (No cooldown)", 0},
                          {"15 minutes cooldown", 15},
                          {"30 minutes cooldown", 30},
                          {"1 hour cooldown", 60},
                          {"4 hours cooldown", 240}
                        ]}
                      />
                    </div>

                    <div class="flex items-center gap-6 pt-1">
                      <.input
                        field={@form[:notify_push]}
                        id="alert-rule-notify-push-check"
                        type="checkbox"
                        label="📱 Mobile Push Notification"
                      />
                      <.input
                        field={@form[:notify_email]}
                        id="alert-rule-notify-email-check"
                        type="checkbox"
                        label="✉️ Email Notification"
                      />
                    </div>
                  </div>

                  <!-- Advanced Filters: Country, Keyboard, Merchant -->
                  <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 space-y-3">
                    <h4 class="font-bold text-xs uppercase tracking-wider text-base-content/70">
                      Smart Deal & Region Filters
                    </h4>

                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                      <.input
                        field={@form[:country_filter]}
                        id="alert-rule-country-filter-select"
                        type="select"
                        label="Origin Region"
                        options={[
                          {"All Regions (DE, FR, ES, IT, etc.)", "all"},
                          {"🇩🇪 Germany Only (Exclude foreign imports)", "de_only"},
                          {"🇪🇺 EU Friendly Only (DE, FR, ES, IT, etc.)", "eu_only"}
                        ]}
                      />

                      <.input
                        field={@form[:merchant_filter]}
                        id="alert-rule-merchant-filter-select"
                        type="select"
                        label="Merchant Trust Filter"
                        options={[
                          {"All Merchants", "all"},
                          {"🛡️ Verified Retailers Only (Amazon, MediaMarkt, etc.)", "verified_only"}
                        ]}
                      />
                    </div>

                    <div class="pt-1">
                      <.input
                        field={@form[:exclude_foreign_keyboards]}
                        id="alert-rule-exclude-keyboards-check"
                        type="checkbox"
                        label="⌨️ Exclude foreign keyboard layouts (AZERTY, QWERTY-ES)"
                      />
                    </div>
                  </div>

                  <!-- Price and Temperature Limits -->
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:max_price]}
                      id="alert-rule-max-price-input"
                      type="number"
                      step="0.01"
                      label="Max Price in € (optional)"
                      placeholder="e.g. 799.00"
                      autocomplete="off"
                      data-1p-ignore="true"
                      data-lpignore="true"
                    />

                    <.input
                      field={@form[:source_filter]}
                      id="alert-rule-source-filter-select"
                      type="select"
                      label="Source Portal"
                      options={[{"All Portals", "all"} | Enum.map(@feeds, &{&1.name, &1.slug})]}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:min_temperature]}
                      id="alert-rule-min-temperature-input"
                      type="number"
                      label="Min. Community Temp (optional)"
                      placeholder="e.g. 100 (ignores unrated deals)"
                      autocomplete="off"
                      data-1p-ignore="true"
                      data-lpignore="true"
                    />

                    <div class="flex items-center pt-6">
                      <.input
                        field={@form[:exclude_dropshippers]}
                        id="alert-rule-exclude-dropshippers-check"
                        type="checkbox"
                        label="Exclude dropshippers (Temu, AliExpress)"
                      />
                    </div>
                  </div>

                  <.input
                    field={@form[:is_active]}
                    id="alert-rule-is-active-check"
                    type="checkbox"
                    label="Active immediately"
                  />
                </div>

                <!-- Sticky Footer with Save button always visible -->
                <div class="sticky bottom-0 bg-base-100 px-6 py-3.5 border-t border-base-200 z-10 flex items-center justify-end gap-2 shrink-0">
                  <.link patch={~p"/alerts"} id="cancel-rule-btn" class="btn btn-ghost btn-sm">
                    Cancel
                  </.link>
                  <.button
                    type="submit"
                    id="save-rule-btn"
                    class="btn btn-primary btn-sm flex items-center gap-1.5 shadow-sm"
                  >
                    <.icon name="hero-check" class="size-4" />
                    <span>Save Rule</span>
                  </.button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
