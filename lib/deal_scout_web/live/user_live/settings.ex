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
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <span class="font-bold text-sm text-base-content">
                  {sub.device_name || "Web Browser"}
                </span>
                <span class="badge badge-xs badge-success">Active</span>
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

      <!-- Danger Zone: Delete Account -->
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
    subscriptions = Notifications.list_push_subscriptions(scope)
    has_password? = is_binary(user.hashed_password) and byte_size(user.hashed_password) > 0

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:delete_account_form, to_form(%{}, as: "user"))
      |> assign(:current_user_has_password?, has_password?)
      |> assign(:trigger_submit, false)
      |> assign(:has_subscriptions, subscriptions != [])
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
      {:ok, sub} ->
        {:noreply,
         socket
         |> put_flash(:info, "🎉 Device registered! Mobile deal alarms will be delivered here.")
         |> assign(:has_subscriptions, true)
         |> stream_insert(:subscriptions, sub)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to register push device: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("send_test_push", _params, socket) do
    scope = socket.assigns.current_scope
    {:ok, _} = Notifications.send_test_notification(scope)

    subs = Notifications.list_push_subscriptions(scope)

    {:noreply,
     socket
     |> put_flash(:info, "🚀 Test deal alarm sent! Check your device notifications.")
     |> assign(:has_subscriptions, subs != [])
     |> stream(:subscriptions, subs, reset: true)}
  end

  @impl true
  def handle_event("remove_subscription", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.delete_user_push_subscription(scope, id) do
      {:ok, sub} ->
        subs = Notifications.list_push_subscriptions(scope)

        {:noreply,
         socket
         |> put_flash(:info, "Device removed.")
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
