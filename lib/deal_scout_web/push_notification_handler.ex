defmodule DealScoutWeb.PushNotificationHandler do
  @moduledoc """
  Shared event handling and assign initialization for PWA push notifications
  across LiveViews (AlertLive, MatchLive, etc.).
  """

  import Phoenix.Component
  import Phoenix.LiveView
  alias DealScout.Notifications

  @doc """
  Initializes standard PWA and push notification assigns on the LiveView socket.
  """
  def init_push_assigns(socket) do
    has_subscriptions =
      case socket.assigns[:current_scope] do
        nil -> false
        scope -> Notifications.list_push_subscriptions(scope) != []
      end

    socket
    |> assign(:push_supported, true)
    |> assign(:push_subscribed, has_subscriptions)
    |> assign(:is_ios, false)
    |> assign(:is_standalone, false)
    |> assign(:show_ios_modal, false)
    |> assign(:banner_dismissed, false)
  end

  @doc """
  Handles common PWA push events.
  Returns `{:handled, socket}` or `:unhandled`.
  """
  def handle_push_event("push-status", params, socket) do
    {:handled,
     socket
     |> assign(:push_supported, Map.get(params, "supported", true))
     |> assign(:is_ios, Map.get(params, "is_ios", false))
     |> assign(:is_standalone, Map.get(params, "is_standalone", false))
     |> assign(
       :push_subscribed,
       socket.assigns.push_subscribed || Map.get(params, "subscribed", false)
     )}
  end

  def handle_push_event("enable_push_notifications", _params, socket) do
    vapid_key = Notifications.vapid_public_key()
    {:handled, push_event(socket, "request-push-subscription", %{vapid_public_key: vapid_key})}
  end

  def handle_push_event("save-push-subscription", params, socket) do
    scope = socket.assigns.current_scope

    case Notifications.create_or_update_push_subscription(scope, params) do
      {:ok, _sub} ->
        {:handled,
         socket
         |> put_flash(:info, "🎉 Mobile deal alarms enabled for this device!")
         |> assign(:push_subscribed, true)}

      {:error, changeset} ->
        {:handled,
         socket
         |> put_flash(:error, "Failed to register push device: #{inspect(changeset.errors)}")}
    end
  end

  def handle_push_event("push-permission-denied", _params, socket) do
    {:handled,
     socket
     |> put_flash(
       :error,
       "Push notifications were blocked. Please allow notifications in your browser settings to receive deal alarms."
     )}
  end

  def handle_push_event("push-error", %{"message" => msg}, socket) do
    {:handled, put_flash(socket, :error, "Push alarm error: #{msg}")}
  end

  def handle_push_event("open_ios_modal", _params, socket) do
    {:handled, assign(socket, :show_ios_modal, true)}
  end

  def handle_push_event("close_ios_modal", _params, socket) do
    {:handled, assign(socket, :show_ios_modal, false)}
  end

  def handle_push_event("dismiss_push_banner", _params, socket) do
    {:handled, assign(socket, :banner_dismissed, true)}
  end

  def handle_push_event(_event, _params, _socket), do: :unhandled
end
