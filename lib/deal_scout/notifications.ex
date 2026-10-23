defmodule DealScout.Notifications do
  @moduledoc """
  Context module for managing notifications, push subscriptions, and VAPID keys.
  Follows AGENTS.md conventions by accepting current_scope as the primary identifier.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Notifications.{PushSubscription, WebPush}
  alias DealScout.Accounts.{Scope, User}

  def vapid_public_key, do: WebPush.vapid_public_key()

  @doc """
  Lists all push subscriptions for the user in the given scope.
  """
  def list_push_subscriptions(%Scope{user: %User{id: user_id}}),
    do: list_push_subscriptions(user_id)

  def list_push_subscriptions(%User{id: user_id}),
    do: list_push_subscriptions(user_id)

  def list_push_subscriptions(user_id) when is_integer(user_id) do
    Repo.all(
      from s in PushSubscription,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at]
    )
  end

  def list_push_subscriptions_for_user(user_id), do: list_push_subscriptions(user_id)

  @doc """
  Fetches a single push subscription by ID belonging to the scoped user.
  """
  def get_user_push_subscription!(%Scope{user: %User{id: user_id}}, id),
    do: get_user_push_subscription!(user_id, id)

  def get_user_push_subscription!(%User{id: user_id}, id),
    do: get_user_push_subscription!(user_id, id)

  def get_user_push_subscription!(user_id, id) do
    Repo.get_by!(PushSubscription, id: id, user_id: user_id)
  end

  @doc """
  Creates or updates a Web Push subscription for the scoped user.
  """
  def create_or_update_push_subscription(%Scope{user: %User{} = user}, attrs),
    do: create_or_update_push_subscription(user, attrs)

  def create_or_update_push_subscription(%User{} = user, attrs) do
    endpoint = attrs[:endpoint] || attrs["endpoint"]

    existing =
      if endpoint do
        Repo.get_by(PushSubscription, endpoint: endpoint)
      end

    case existing do
      %PushSubscription{} = sub ->
        sub
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.put_change(:user_id, user.id)
        |> Repo.update()

      nil ->
        %PushSubscription{user_id: user.id}
        |> PushSubscription.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Deletes a push subscription belonging to the scoped user.
  """
  def delete_user_push_subscription(%Scope{user: %User{id: user_id}}, id),
    do: delete_user_push_subscription(user_id, id)

  def delete_user_push_subscription(%User{id: user_id}, id),
    do: delete_user_push_subscription(user_id, id)

  def delete_user_push_subscription(user_id, id) do
    case Repo.get_by(PushSubscription, id: id, user_id: user_id) do
      %PushSubscription{} = sub -> Repo.delete(sub)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Delivers a Web Push payload to all active subscriptions registered for the given
  scope, user, or user_id. Updates `last_used_at` on success and prunes expired
  (HTTP 410 Gone) subscriptions automatically.
  """
  def deliver_push_to_user(%Scope{user: %User{id: user_id}}, payload) when not is_nil(user_id),
    do: deliver_push_to_user(user_id, payload)

  def deliver_push_to_user(%{id: user_id}, payload) when not is_nil(user_id),
    do: deliver_push_to_user(user_id, payload)

  def deliver_push_to_user(user_id, payload) when is_integer(user_id) and is_map(payload) do
    subscriptions = list_push_subscriptions(user_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    results =
      Enum.map(subscriptions, fn sub ->
        case WebPush.send_notification(sub, payload) do
          {:ok, _} = ok ->
            sub
            |> Ecto.Changeset.change(last_used_at: now)
            |> Repo.update()

            ok

          {:error, :subscription_expired} = expired ->
            Repo.delete(sub)
            expired

          error ->
            error
        end
      end)

    {:ok, results}
  end

  def deliver_push_to_user(_target, _payload), do: {:ok, []}

  @doc """
  Sends a test notification to all active devices registered under the scoped user.
  """
  def send_test_notification(target) do
    payload = %{
      title: "DealScout Test Alarm",
      body: "Push alarms are working on your device! You're ready to catch hot deals.",
      url: "/alerts",
      icon: "/images/icon-192.png",
      badge: "/images/badge-72.png",
      tag: "test-alarm-#{System.system_time(:second)}"
    }

    deliver_push_to_user(target, payload)
  end
end
