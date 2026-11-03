defmodule DealScoutWeb.UserLive.Settings do
  use DealScoutWeb, :live_view

  on_mount {DealScoutWeb.UserAuth, :require_sudo_mode}

  alias DealScout.Accounts
  alias DealScout.Notifications

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account, credentials, and mobile deal push devices</:subtitle>
        </.header>
      </div>

      <!-- Mobile Deal Push Devices Section -->
      <div
        id="push-settings-container"
        phx-hook="PushManager"
        class="bg-base-200/50 p-6 rounded-2xl border border-base-300 space-y-4"
      >
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <div class="size-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center">
              <.icon name="hero-device-phone-mobile" class="size-6" />
            </div>
            <div>
              <h2 class="text-lg font-bold text-base-content">Mobile Deal Alarms & PWA Devices</h2>
              <p class="text-xs text-base-content/70">
                Registered browsers and devices receiving instant deal notifications for your keyword rules.
              </p>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <%= if @has_subscriptions do %>
              <button
                phx-click="send_test_push"
                class="btn btn-secondary btn-sm flex items-center gap-1.5 shadow-sm"
              >
                <.icon name="hero-paper-airplane" class="size-4" />
                <span>Send Test Alarm</span>
              </button>
            <% end %>
            <button
              phx-click="register_this_device"
              class="btn btn-primary btn-sm flex items-center gap-1.5 shadow-sm"
            >
              <.icon name="hero-plus" class="size-4" />
              <span>Register This Device</span>
            </button>
          </div>
        </div>

        <!-- Android Battery Optimization Guide Card -->
        <div
          id="android-battery-guide-card"
          class="bg-amber-500/10 border border-amber-500/25 rounded-xl p-4 text-xs space-y-2"
        >
          <div class="flex items-center justify-between">
            <span class="font-bold text-base-content flex items-center gap-1.5">
              <.icon name="hero-bolt" class="size-4 text-amber-600 dark:text-amber-400" />
              <span>Android Background Optimization Guide (Instant Locked-Screen Alarms)</span>
            </span>
          </div>
          <p class="text-base-content/75 leading-relaxed">
            By default, Android's <em>Doze Mode</em>
            delays background notifications from web browsers when your screen is locked.
            To guarantee alarms ring the exact second a deal is found:
          </p>
          <ol class="list-decimal list-inside space-y-1 text-base-content/80 font-medium pl-1">
            <li>
              Long-press the <strong>DealScout</strong>
              (or Chrome) icon on your home screen &rarr; tap <strong>App Info</strong>
              (ⓘ).
            </li>
            <li>Tap <strong>App battery usage</strong> (or <strong>Battery</strong>).</li>
            <li>Select <strong>Unrestricted</strong> (instead of <em>Optimized</em>).</li>
          </ol>
        </div>

        <div
          id="push-subscriptions"
          phx-update="stream"
          class="divide-y divide-base-300/50 bg-base-100 rounded-xl border border-base-300 overflow-hidden"
        >
          <div
            id="push-subscriptions-empty"
            class="hidden only:block text-center py-8 bg-base-100 p-6"
          >
            <p class="text-sm text-base-content/70">No mobile devices registered yet.</p>
            <p class="text-xs text-base-content/50 mt-1">
              Click "Register This Device" above or open DealScout on your phone and tap "Enable Alarms" to get push notifications.
            </p>
          </div>
          <div
            :for={{dom_id, sub} <- @streams.subscriptions}
            id={dom_id}
            class="p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3 hover:bg-base-200/30 transition-colors"
          >
            <div class="space-y-1.5 min-w-0">
              <%= if @editing_device_id == sub.id do %>
                <.form
                  for={@edit_device_form}
                  id={"edit-device-form-#{sub.id}"}
                  phx-submit="save_device_name"
                  class="flex items-center gap-2 flex-wrap"
                >
                  <.input
                    field={@edit_device_form[:device_name]}
                    type="text"
                    placeholder="e.g. Personal iPhone"
                    required
                    class="input input-sm input-bordered rounded-lg text-sm w-48 sm:w-64"
                  />
                  <button type="submit" class="btn btn-primary btn-sm rounded-lg text-xs">
                    Save
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_edit_device"
                    class="btn btn-ghost btn-sm rounded-lg text-xs"
                  >
                    Cancel
                  </button>
                </.form>
              <% else %>
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="font-bold text-sm text-base-content device-name">
                    {sub.device_name || "Web Browser"}
                  </span>
                  <button
                    type="button"
                    phx-click="edit_device"
                    phx-value-id={sub.id}
                    title="Rename device nickname"
                    class="btn btn-ghost btn-xs btn-circle text-base-content/50 hover:text-base-content"
                  >
                    <.icon name="hero-pencil" class="size-3" />
                  </button>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-mono bg-base-300/50 text-base-content/70">
                    {sub.browser_info}
                  </span>
                  <span class="badge badge-xs badge-success">Active</span>
                </div>
              <% end %>

              <div class="flex items-center gap-2 flex-wrap text-xs">
                <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-medium bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20">
                  <.icon name="hero-check-circle" class="size-3" />
                  <span>{sub.confirmed_count || 0} confirmed (24h)</span>
                </span>

                <%= if sub.pending_count && sub.pending_count > 0 do %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold bg-amber-500/15 text-amber-700 dark:text-amber-300 border border-amber-500/30">
                    <.icon name="hero-clock" class="size-3" />
                    <span>{sub.pending_count} pending confirms</span>
                  </span>
                <% end %>

                <%= if sub.last_receipt_at do %>
                  <span class="text-[11px] text-base-content/50">
                    · Last confirmed: {Calendar.strftime(sub.last_receipt_at, "%d.%m %H:%M")}
                  </span>
                <% end %>
              </div>

              <p class="text-xs text-base-content/60 font-mono truncate max-w-sm sm:max-w-md">
                {sub.endpoint}
              </p>
              <p class="text-[11px] text-base-content/50">
                Added: {Calendar.strftime(sub.inserted_at, "%d.%m.%Y %H:%M")}
                <%= if sub.last_used_at do %>
                  · Last active: {Calendar.strftime(sub.last_used_at, "%d.%m.%Y %H:%M")}
                <% end %>
              </p>
            </div>

            <button
              phx-click="remove_subscription"
              phx-value-id={sub.id}
              data-confirm="Remove this device from receiving push notifications?"
              class="btn btn-ghost btn-xs text-error self-end sm:self-center"
            >
              <.icon name="hero-trash" class="size-4" />
              <span>Remove</span>
            </button>
          </div>
        </div>

        <%!-- Recent Delivery Diagnostics & Receipt Latency --%>
        <div id="push-delivery-logs-section" class="mt-4 pt-4 border-t border-base-300/50">
          <div class="flex items-center justify-between mb-2">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/70 flex items-center gap-1.5">
              <.icon name="hero-chart-bar" class="size-3.5" />
              <span>Push Delivery Diagnostics & Receipt Latency</span>
            </h4>
            <span class="text-[11px] text-base-content/50">Recent attempts</span>
          </div>

          <%= if @delivery_logs == [] do %>
            <p class="text-xs text-base-content/50 italic py-2">No push deliveries attempted yet.</p>
          <% else %>
            <div id="push-delivery-logs" class="space-y-2">
              <div
                :for={log <- @delivery_logs}
                id={"push-log-#{log.id}"}
                class="text-xs p-2.5 rounded-lg border border-base-200 bg-base-200/30 flex flex-col sm:flex-row sm:items-center justify-between gap-1.5"
              >
                <div class="flex items-center gap-2 flex-wrap">
                  <%= case log.status do %>
                    <% "delivered" -> %>
                      <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20">
                        <.icon name="hero-check-circle" class="size-3" /> Delivered
                      </span>
                    <% "expired" -> %>
                      <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium bg-rose-500/10 text-rose-600 dark:text-rose-400 border border-rose-500/20">
                        <.icon name="hero-x-circle" class="size-3" /> Expired (410)
                      </span>
                    <% "no_subscriptions" -> %>
                      <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium bg-amber-500/10 text-amber-600 dark:text-amber-400 border border-amber-500/20">
                        <.icon name="hero-exclamation-triangle" class="size-3" /> No Devices in DB
                      </span>
                    <% "skipped_cooldown" -> %>
                      <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium bg-sky-500/10 text-sky-600 dark:text-sky-400 border border-sky-500/20">
                        <.icon name="hero-clock" class="size-3" /> Cooldown
                      </span>
                    <% _ -> %>
                      <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium bg-rose-500/10 text-rose-600 dark:text-rose-400 border border-rose-500/20">
                        <.icon name="hero-exclamation-circle" class="size-3" />
                        {log.status}
                      </span>
                  <% end %>

                  <%= if log.gateway_duration_ms do %>
                    <span class="text-base-content/70 font-mono text-[11px]">
                      Gateway: {log.gateway_duration_ms}ms
                    </span>
                  <% end %>

                  <%= if log.client_delay_ms do %>
                    <span class="inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[10px] font-mono font-medium bg-indigo-500/10 text-indigo-600 dark:text-indigo-400 border border-indigo-500/20">
                      Device confirmed in {log.client_delay_ms}ms
                    </span>
                  <% else %>
                    <%= if log.status == "delivered" do %>
                      <span class="text-base-content/40 text-[10px]">
                        (device receipt pending)
                      </span>
                    <% end %>
                  <% end %>

                  <%= if log.error_message do %>
                    <span class="text-rose-600 dark:text-rose-400 text-[11px] truncate max-w-xs">
                      {log.error_message}
                    </span>
                  <% end %>
                </div>

                <span class="text-[11px] text-base-content/50 font-mono shrink-0">
                  {Calendar.strftime(log.inserted_at, "%d.%m %H:%M:%S")}
                </span>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider my-8" />

      <%!-- Data Portability: Export My Data --%>
      <div
        id="data-export-container"
        class="bg-base-200/50 border border-base-300 rounded-2xl p-6 sm:p-8 space-y-4"
      >
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div class="flex items-center gap-3">
            <div class="size-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
              <.icon name="hero-arrow-down-tray" class="size-6" />
            </div>
            <div>
              <h2 class="text-lg font-bold text-base-content">
                Export My Data (GDPR Art. 15 &amp; 20)
              </h2>
              <p class="text-xs sm:text-sm text-base-content/70">
                Download a machine-readable JSON copy of all your account settings, keyword alert rules, and deal match history.
              </p>
            </div>
          </div>

          <a
            href={~p"/users/settings/export"}
            class="btn btn-primary btn-sm gap-2 shrink-0 self-start sm:self-auto"
            id="download_data_btn"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
            <span>Export Data</span>
          </a>
        </div>
      </div>

      <div class="divider my-8" />

      <%!-- Danger Zone: Delete Account --%>
      <div
        id="danger-zone-container"
        class="bg-error/5 border border-error/30 rounded-2xl p-6 sm:p-8 space-y-4"
      >
        <div class="flex items-center gap-3">
          <div class="size-10 rounded-xl bg-error/10 text-error flex items-center justify-center shrink-0">
            <.icon name="hero-exclamation-triangle" class="size-6" />
          </div>
          <div>
            <h2 class="text-lg font-bold text-error">Danger Zone: Delete Account</h2>
            <p class="text-xs sm:text-sm text-base-content/70">
              Permanently delete your account and all associated data in accordance with Art. 17 DSGVO.
            </p>
          </div>
        </div>

        <p class="text-xs sm:text-sm text-base-content/80 leading-relaxed">
          Deleting your account will immediately and permanently erase your user profile, all saved keyword alert rules,
          matched deal history, and registered push notification devices.
          <strong>This action is irreversible.</strong>
        </p>

        <div class="pt-2">
          <.form
            for={@delete_account_form}
            id="delete_account_form"
            action={~p"/users/settings/delete-account"}
            method="post"
            data-confirm="Are you sure you want to permanently delete your account and all your alert rules? This cannot be undone."
          >
            <input type="hidden" name="_method" value="delete" />
            <%= if @current_user_has_password? do %>
              <div class="max-w-md mb-4">
                <.input
                  field={@delete_account_form[:current_password]}
                  type="password"
                  label="Confirm your password to proceed"
                  name="user[current_password]"
                  id="delete_account_password"
                  placeholder="Enter your current password"
                  required
                />
              </div>
            <% end %>
            <.button
              type="submit"
              class="btn btn-error btn-sm gap-2 text-white"
              id="delete_account_btn"
            >
              <.icon name="hero-trash" class="size-4" />
              <span>Permanently Delete My Account</span>
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    subscriptions = Notifications.get_device_delivery_metrics(scope, 24)
    delivery_logs = Notifications.list_push_delivery_logs(scope, 8)
    has_password? = is_binary(user.hashed_password) and byte_size(user.hashed_password) > 0

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:delete_account_form, to_form(%{}, as: "user"))
      |> assign(:current_user_has_password?, has_password?)
      |> assign(:trigger_submit, false)
      |> assign(:devices_by_id, Map.new(subscriptions, &{&1.id, &1}))
      |> assign(:editing_device_id, nil)
      |> assign(:edit_device_form, nil)
      |> assign(:has_subscriptions, subscriptions != [])
      |> assign(:delivery_logs, delivery_logs)
      |> stream(:subscriptions, subscriptions)

    {:ok, socket}
  end

  @impl true
  def handle_event("register_this_device", _params, socket) do
    vapid_key = Notifications.vapid_public_key()
    {:noreply, push_event(socket, "request-push-subscription", %{vapid_public_key: vapid_key})}
  end

  @impl true
  def handle_event("save-push-subscription", params, socket) do
    scope = socket.assigns.current_scope

    case Notifications.create_or_update_push_subscription(scope, params) do
      {:ok, _sub} ->
        reloaded_subs = Notifications.get_device_delivery_metrics(scope, 24)

        socket =
          socket
          |> assign(:devices_by_id, Map.new(reloaded_subs, &{&1.id, &1}))
          |> assign(:has_subscriptions, reloaded_subs != [])
          |> stream(:subscriptions, reloaded_subs, reset: true)

        socket =
          if Map.get(params, "silent", false) do
            socket
          else
            put_flash(
              socket,
              :info,
              "🎉 Device registered! Mobile deal alarms will be delivered here."
            )
          end

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to register push device: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("edit_device", %{"id" => id}, socket) do
    sub_id = String.to_integer(id)
    scope = socket.assigns.current_scope
    sub = Notifications.get_user_push_subscription!(scope, sub_id)
    form = to_form(%{"device_name" => sub.device_name || ""}, as: "device")
    target_metric = socket.assigns.devices_by_id[sub_id]

    socket =
      socket
      |> assign(:editing_device_id, sub_id)
      |> assign(:edit_device_form, form)

    socket =
      if target_metric do
        stream_insert(socket, :subscriptions, target_metric)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit_device", _params, socket) do
    sub_id = socket.assigns.editing_device_id
    target_metric = sub_id && socket.assigns.devices_by_id[sub_id]

    socket =
      socket
      |> assign(:editing_device_id, nil)
      |> assign(:edit_device_form, nil)

    socket =
      if target_metric do
        stream_insert(socket, :subscriptions, target_metric)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_device_name", %{"device" => %{"device_name" => name}}, socket) do
    scope = socket.assigns.current_scope
    sub_id = socket.assigns.editing_device_id

    case Notifications.update_push_subscription_device_name(scope, sub_id, name) do
      {:ok, _updated} ->
        devices = Notifications.get_device_delivery_metrics(scope, 24)
        devices_by_id = Map.new(devices, &{&1.id, &1})

        {:noreply,
         socket
         |> assign(:editing_device_id, nil)
         |> assign(:edit_device_form, nil)
         |> assign(:devices_by_id, devices_by_id)
         |> stream(:subscriptions, devices, reset: true)
         |> put_flash(:info, "Device nickname updated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update device nickname.")}
    end
  end

  @impl true
  def handle_event("send_test_push", _params, socket) do
    scope = socket.assigns.current_scope
    subs = Notifications.list_push_subscriptions(scope)

    socket =
      if subs == [] do
        put_flash(
          socket,
          :error,
          "⚠️ No push devices registered. Click 'Register This Device' above first."
        )
      else
        case Notifications.send_test_notification(scope) do
          {:ok, results} ->
            delivered = Enum.filter(results, &match?({:ok, _}, &1))
            errors = Enum.filter(results, &match?({:error, _}, &1))

            cond do
              delivered != [] and errors == [] ->
                {:ok, info} = hd(delivered)
                dur = Map.get(info, :duration_ms, 0)

                put_flash(
                  socket,
                  :info,
                  "🚀 Test push accepted by gateway in #{dur}ms! If your phone doesn't alert within seconds, check OS Battery Optimization."
                )

              delivered != [] and errors != [] ->
                put_flash(
                  socket,
                  :warning,
                  "⚠️ Push delivered to #{length(delivered)} device(s), but failed for #{length(errors)} device(s)."
                )

              true ->
                err_msg =
                  case errors do
                    [{:error, err} | _] -> Map.get(err, :error, inspect(err))
                    _ -> "Unknown error"
                  end

                put_flash(
                  socket,
                  :error,
                  "❌ Push gateway rejected test notification: #{inspect(err_msg)}"
                )
            end

          {:error, reason} ->
            put_flash(socket, :error, "❌ Failed to send test push: #{inspect(reason)}")
        end
      end

    reloaded_subs = Notifications.get_device_delivery_metrics(scope, 24)
    logs = Notifications.list_push_delivery_logs(scope, 8)

    {:noreply,
     socket
     |> assign(:devices_by_id, Map.new(reloaded_subs, &{&1.id, &1}))
     |> assign(:has_subscriptions, reloaded_subs != [])
     |> assign(:delivery_logs, logs)
     |> stream(:subscriptions, reloaded_subs, reset: true)}
  end

  @impl true
  def handle_event("remove_subscription", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.delete_user_push_subscription(scope, id) do
      {:ok, sub} ->
        subs = Notifications.get_device_delivery_metrics(scope, 24)

        {:noreply,
         socket
         |> put_flash(:info, "Device removed.")
         |> assign(:devices_by_id, Map.new(subs, &{&1.id, &1}))
         |> assign(:has_subscriptions, subs != [])
         |> stream_delete(:subscriptions, sub)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove device.")}
    end
  end

  @impl true
  def handle_event("push-status", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("push-error", %{"message" => msg}, socket) do
    {:noreply, put_flash(socket, :error, "Push alarm error: #{msg}")}
  end

  @impl true
  def handle_event("push-permission-denied", _params, socket) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       "Push notifications were blocked. Please allow notifications in your browser settings to receive deal alarms."
     )}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
