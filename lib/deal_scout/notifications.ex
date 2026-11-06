defmodule DealScout.Notifications do
  @moduledoc """
  Context module for managing notifications, push subscriptions, and VAPID keys.
  Follows AGENTS.md conventions by accepting current_scope as the primary identifier.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Analytics
  alias DealScout.Notifications.{PushDeliveryLog, PushSubscription, WebPush}
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

    res =
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

    case res do
      {:ok, sub} ->
        Analytics.invalidate_device_metrics_cache()
        {:ok, sub}

      error ->
        error
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
      %PushSubscription{} = sub ->
        res = Repo.delete(sub)
        Analytics.invalidate_device_metrics_cache()
        res

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates the device nickname for a push subscription belonging to the scoped user.
  """
  def update_push_subscription_device_name(%Scope{user: %User{id: user_id}}, id, device_name),
    do: update_push_subscription_device_name(user_id, id, device_name)

  def update_push_subscription_device_name(%User{id: user_id}, id, device_name),
    do: update_push_subscription_device_name(user_id, id, device_name)

  def update_push_subscription_device_name(user_id, id, device_name)
      when is_integer(user_id) do
    case Repo.get_by(PushSubscription, id: id, user_id: user_id) do
      %PushSubscription{} = sub ->
        case sub
             |> PushSubscription.changeset(%{device_name: device_name})
             |> Repo.update() do
          {:ok, updated} ->
            Analytics.invalidate_device_metrics_cache()
            {:ok, updated}

          error ->
            error
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Delivers a Web Push payload to all active subscriptions registered for the given
  scope, user, or user_id. Updates `last_used_at` on success, prunes expired
  (HTTP 410 Gone) subscriptions automatically, records gateway response latency,
  and persists an audit trail log for every delivery attempt.
  """
  def deliver_push_to_user(%Scope{user: %User{id: user_id}}, payload) when not is_nil(user_id),
    do: deliver_push_to_user(user_id, payload)

  def deliver_push_to_user(%{id: user_id}, payload) when not is_nil(user_id),
    do: deliver_push_to_user(user_id, payload)

  def deliver_push_to_user(user_id, payload) when is_integer(user_id) and is_map(payload) do
    subscriptions = list_push_subscriptions(user_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_ms = System.system_time(:millisecond)

    if subscriptions == [] do
      tracking_id =
        Map.get(payload, :tracking_id) ||
          "push-#{user_id}-none-#{System.system_time(:microsecond)}"

      record_push_delivery_log(%{
        user_id: user_id,
        user_match_id: Map.get(payload, :user_match_id),
        tracking_id: tracking_id,
        endpoint: nil,
        status: "no_subscriptions",
        error_message: "User has 0 registered push devices in database."
      })

      {:ok, []}
    else
      results =
        Enum.map(subscriptions, fn sub ->
          tracking_id =
            Map.get(payload, :tracking_id) ||
              "push-#{user_id}-#{sub.id}-#{System.system_time(:microsecond)}"

          payload_with_meta =
            payload
            |> Map.put(:tracking_id, tracking_id)
            |> Map.put(:sent_at, now_ms)

          # Pre-dispatch: persist tracking entry with status "pending" so device ACKs
          # arriving immediately never miss the record in SQLite (race-free).
          {:ok, pending_log} =
            record_push_delivery_log(%{
              user_id: user_id,
              user_match_id: Map.get(payload, :user_match_id),
              push_subscription_id: sub.id,
              tracking_id: tracking_id,
              endpoint: sub.endpoint,
              status: "pending"
            })

          start_mono = System.monotonic_time(:millisecond)
          send_res = WebPush.send_notification(sub, payload_with_meta)
          duration_ms = max(1, System.monotonic_time(:millisecond) - start_mono)

          case send_res do
            {:ok, _} ->
              sub
              |> Ecto.Changeset.change(last_used_at: now)
              |> Repo.update()

              update_push_attempt(
                pending_log,
                "delivered",
                201,
                nil,
                duration_ms
              )

              {:ok,
               %{
                 status: :delivered,
                 duration_ms: duration_ms,
                 tracking_id: tracking_id,
                 sub_id: sub.id
               }}

            {:error, :subscription_expired} ->
              update_push_attempt(
                pending_log,
                "expired",
                410,
                "Push subscription expired or gone (HTTP 410). Device unregistered.",
                duration_ms
              )

              Repo.delete(sub)

              {:error,
               %{
                 status: :subscription_expired,
                 duration_ms: duration_ms,
                 sub_id: sub.id
               }}

            {:error, {:http_error, status, body}} ->
              update_push_attempt(
                pending_log,
                "http_error",
                status,
                "Push gateway returned HTTP #{status}: #{inspect(body)}",
                duration_ms
              )

              {:error,
               %{
                 status: :http_error,
                 http_status: status,
                 error: body,
                 duration_ms: duration_ms
               }}

            {:error, reason} ->
              update_push_attempt(
                pending_log,
                "network_error",
                nil,
                inspect(reason),
                duration_ms
              )

              {:error,
               %{
                 status: :network_error,
                 error: inspect(reason),
                 duration_ms: duration_ms
               }}
          end
        end)

      {:ok, results}
    end
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

  @doc """
  Lists the most recent push delivery logs for a given user or scope.
  """
  def list_push_delivery_logs(target, limit \\ 20)

  def list_push_delivery_logs(%Scope{user: %User{id: user_id}}, limit),
    do: list_push_delivery_logs(user_id, limit)

  def list_push_delivery_logs(%User{id: user_id}, limit),
    do: list_push_delivery_logs(user_id, limit)

  def list_push_delivery_logs(user_id, limit) when is_integer(user_id) do
    from(l in PushDeliveryLog,
      where: l.user_id == ^user_id,
      order_by: [desc: l.inserted_at, desc: l.id],
      limit: ^limit,
      preload: [:user_match]
    )
    |> Repo.all()
  end

  @doc """
  Records a push delivery attempt log directly (e.g. for skipped cooldown or manual errors).
  Foreign keys (:user_id, :user_match_id, :push_subscription_id) are explicitly set
  on the struct to comply with AGENTS.md Ecto guidelines.
  """
  def record_push_delivery_log(attrs) when is_map(attrs) do
    user_id = Map.get(attrs, :user_id)
    user_match_id = Map.get(attrs, :user_match_id)
    push_subscription_id = Map.get(attrs, :push_subscription_id)

    %PushDeliveryLog{
      user_id: user_id,
      user_match_id: user_match_id,
      push_subscription_id: push_subscription_id
    }
    |> PushDeliveryLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Records a push notification suppression log (e.g. when suppressed by rule cooldown).
  Encapsulates tracking ID generation and status behind the notification seam.
  """
  def record_push_suppression(user_id, user_match_id, reason \\ nil) when is_integer(user_id) do
    record_push_delivery_log(%{
      user_id: user_id,
      user_match_id: user_match_id,
      tracking_id:
        "skipped-cooldown-#{user_match_id || user_id}-#{System.system_time(:microsecond)}",
      endpoint: nil,
      status: "skipped_cooldown",
      error_message: reason
    })
  end

  @doc """
  Records a delivery receipt ping sent back from the Service Worker on the device.
  Measures latency on the server against `log.inserted_at` to eliminate client device clock skew.
  """
  def record_receipt(tracking_id, received_at_ms, _client_delay_ms)
      when is_binary(tracking_id) do
    query = from(l in PushDeliveryLog, where: l.tracking_id == ^tracking_id)

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %PushDeliveryLog{} = log ->
        now = DateTime.utc_now()
        # Roundtrip latency measured on server eliminates device clock skew
        server_delay_ms = max(0, DateTime.diff(now, log.inserted_at, :millisecond))

        received_at =
          case DateTime.from_unix(received_at_ms, :millisecond) do
            {:ok, dt} -> dt
            _ -> now
          end

        case log
             |> PushDeliveryLog.receipt_changeset(%{
               client_received_at: received_at,
               client_delay_ms: server_delay_ms
             })
             |> Repo.update() do
          {:ok, updated_log} ->
            Analytics.invalidate_delivery_metrics_cache()
            Analytics.invalidate_device_metrics_cache()
            {:ok, updated_log}

          error ->
            error
        end
    end
  end

  @doc """
  Lists the most recent push delivery logs globally across all users for admin inspection.
  Preloads the user and user_match associations.
  """
  def list_recent_delivery_logs(limit \\ 10) when is_integer(limit) and limit > 0 do
    from(l in PushDeliveryLog,
      order_by: [desc: l.inserted_at, desc: l.id],
      limit: ^limit,
      preload: [:user, :user_match]
    )
    |> Repo.all()
  end

  @doc """
  Prunes push delivery logs older than the given number of days (default 7).
  Returns `{deleted_count, nil}`.
  """
  def prune_push_delivery_logs(days \\ 7) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(l in PushDeliveryLog, where: l.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp update_push_attempt(pending_log, status, http_status, error_msg, duration_ms) do
    # Fetch fresh in case client ACK already updated client_received_at while gateway request was in flight
    current_log = Repo.get(PushDeliveryLog, pending_log.id) || pending_log

    current_log
    |> PushDeliveryLog.changeset(%{
      status: status,
      http_status: http_status,
      error_message: error_msg,
      gateway_duration_ms: duration_ms
    })
    |> Repo.update()
  end
end
