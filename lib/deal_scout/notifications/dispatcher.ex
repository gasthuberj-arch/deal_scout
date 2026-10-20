defmodule DealScout.Notifications.Dispatcher do
  @moduledoc """
  Extensible notification dispatcher for deal alert matches.
  Handles real-time LiveView PubSub broadcasts, Web Push notifications (VAPID),
  email alerts, and collapsed batch/digest delivery.
  """

  require Logger

  alias DealScout.Alerts.{AlertRule, UserMatch}
  alias DealScout.Notifications.{PushSubscription, WebPush}
  alias DealScout.Repo

  @pubsub DealScout.PubSub

  def user_topic(user_id), do: "user:#{user_id}:matches"

  @doc """
  Dispatches a single deal match.
  Respects delivery_mode (instant vs digest), notify_push, and notify_email.
  """
  def dispatch(%UserMatch{} = match) do
    match = Repo.preload(match, [:user, [deal: [:feed, :merchant]], :alert_rule])
    rule = match.alert_rule

    # 1. Real-time PubSub for LiveView inbox (always immediate)
    broadcast_liveview(match)

    # 2. Check delivery mode
    if rule && rule.delivery_mode in ["hourly_digest", "daily_digest"] do
      # Queue for digest worker
      match
      |> Ecto.Changeset.change(%{digest_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()
    else
      # Instant delivery mode
      match =
        if rule && rule.notify_push && !match.notified_via_push do
          dispatch_single_push(match)
        else
          match
        end

      match =
        if (is_nil(rule) or rule.notify_email != false) && !match.notified_via_email do
          dispatch_single_email(match)
        else
          match
        end

      if rule && rule.id && rule.__meta__.state == :loaded do
        rule
        |> Ecto.Changeset.change(%{
          last_notified_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
      end

      {:ok, match}
    end
  end

  @doc """
  Dispatches a batch of matches belonging to the same alert rule
  produced in a single polling run.
  """
  def dispatch_batch(%AlertRule{} = rule, matches) when is_list(matches) do
    matches = Repo.preload(matches, [:user, [deal: [:feed, :merchant]], :alert_rule])

    # Broadcast each to LiveView so UI updates live
    Enum.each(matches, &broadcast_liveview/1)

    cond do
      matches == [] ->
        :ok

      rule.delivery_mode in ["hourly_digest", "daily_digest"] ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Enum.each(matches, fn m ->
          m
          |> Ecto.Changeset.change(%{digest_at: now})
          |> Repo.update()
        end)

      length(matches) == 1 ->
        dispatch(hd(matches))

      true ->
        # Multiple matches in instant mode: collapse into a single push/email notification
        first_match = hd(matches)
        user = first_match.user
        deal_count = length(matches)

        push_delivered? =
          if rule.notify_push do
            deal_titles =
              matches
              |> Enum.take(2)
              |> Enum.map(fn m ->
                price_str = if m.deal.price, do: " (#{m.deal.price} €)", else: ""
                "#{m.deal.title}#{price_str}"
              end)
              |> Enum.join(", ")

            prices = matches |> Enum.map(& &1.deal.price) |> Enum.reject(&is_nil/1)

            min_price =
              case prices do
                [] -> nil
                _ -> Enum.min(prices, Decimal)
              end

            title =
              if min_price do
                "🔥 #{deal_count} new deals for '#{rule.name}' (from #{min_price} €)"
              else
                "🔥 #{deal_count} new deals for '#{rule.name}'"
              end

            payload = %{
              title: title,
              body:
                "#{deal_titles}#{if deal_count > 2, do: " and #{deal_count - 2} more", else: ""}",
              url: "/matches?highlight=#{first_match.id}",
              icon: (first_match.deal && first_match.deal.image_url) || "/images/icon-192.png",
              badge: "/images/badge-72.png",
              idealo_url: first_match.deal && first_match.deal.idealo_url,
              geizhals_url: first_match.deal && first_match.deal.geizhals_url,
              tag: "batch-rule-#{rule.id}-#{System.system_time(:second)}"
            }

            {:ok, count} = send_push_to_user(user, payload)
            count > 0
          else
            false
          end

        if rule.notify_email do
          # Collapse batch into single email notification for top deal
          dispatch_single_email(first_match)
        end

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Enum.each(matches, fn m ->
          m
          |> Ecto.Changeset.change(%{
            notified_via_push: push_delivered?,
            notified_via_email: rule.notify_email
          })
          |> Repo.update()
        end)

        rule
        |> Ecto.Changeset.change(%{last_notified_at: now})
        |> Repo.update()
    end
  end

  @doc """
  Dispatches a consolidated digest of matches to a user.
  """
  def dispatch_digest(user, matches, period_label) when is_list(matches) and matches != [] do
    matches = Repo.preload(matches, [:user, [deal: [:feed, :merchant]], :alert_rule])
    count = length(matches)
    top_match = hd(matches)

    payload = %{
      title: "DealScout #{period_label} Digest: #{count} new deals",
      body: "You have #{count} new deal matches ready in your inbox. Tap to browse them now.",
      url: "/matches?highlight=#{top_match.id}",
      icon: (top_match.deal && top_match.deal.image_url) || "/images/icon-192.png",
      badge: "/images/badge-72.png",
      idealo_url: top_match.deal && top_match.deal.idealo_url,
      geizhals_url: top_match.deal && top_match.deal.geizhals_url,
      tag: "digest-#{user.id}-#{System.system_time(:second)}"
    }

    send_push_to_user(user, payload)

    any_email? = Enum.any?(matches, fn m -> m.alert_rule && m.alert_rule.notify_email end)

    if any_email? do
      dispatch_single_email(top_match)
    end

    Enum.each(matches, fn m ->
      m
      |> Ecto.Changeset.change(%{notified_via_push: true, notified_via_email: any_email?})
      |> Repo.update()
    end)
  end

  def dispatch_digest(_user, _matches, _period_label), do: :ok

  defp broadcast_liveview(%UserMatch{user_id: user_id} = match) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {:new_match, match})
  end

  defp dispatch_single_push(%UserMatch{user: %{id: user_id}} = match) when not is_nil(user_id) do
    deal = match.deal
    rule = match.alert_rule
    price_str = if deal && deal.price, do: " · #{deal.price} €", else: ""

    merchant_name =
      if deal && deal.merchant, do: deal.merchant.name, else: (deal && deal.raw_merchant) || ""

    merchant_str = if merchant_name != "", do: " at #{merchant_name}", else: ""

    actions =
      if deal && deal.idealo_url do
        [%{action: "open_idealo", title: "View on Idealo"}]
      else
        []
      end

    payload = %{
      title: "🔥 Deal Alert: #{(rule && rule.name) || "Match"}",
      body: "#{(deal && deal.title) || "Deal"}#{price_str}#{merchant_str}",
      url: "/matches?highlight=#{match.id}",
      icon: (deal && deal.image_url) || "/images/icon-192.png",
      badge: "/images/badge-72.png",
      idealo_url: deal && deal.idealo_url,
      geizhals_url: deal && deal.geizhals_url,
      actions: actions,
      tag: "match-#{match.id}"
    }

    {:ok, count} = send_push_to_user(match.user, payload)
    push_delivered? = count > 0

    if match.id do
      case match
           |> Ecto.Changeset.change(%{notified_via_push: push_delivered?})
           |> Repo.update() do
        {:ok, updated} -> updated
        _ -> match
      end
    else
      %{match | notified_via_push: push_delivered?}
    end
  end

  defp dispatch_single_push(match), do: match

  defp dispatch_single_email(%UserMatch{user: user, deal: deal, alert_rule: rule} = match) do
    case DealScout.Accounts.UserNotifier.deliver_deal_alert(user, deal, rule) do
      {:ok, _} ->
        if match.id do
          case match |> Ecto.Changeset.change(%{notified_via_email: true}) |> Repo.update() do
            {:ok, updated} -> updated
            _ -> match
          end
        else
          %{match | notified_via_email: true}
        end

      {:error, reason} ->
        Logger.error(
          "[DealScout.Dispatcher] Failed to deliver deal alert email for match #{match.id}: #{inspect(reason)}"
        )

        match

      _ ->
        match
    end
  rescue
    e ->
      Logger.error(
        "[DealScout.Dispatcher] Exception delivering deal alert email for match #{match.id}: #{Exception.message(e)}"
      )

      match
  end

  defp send_push_to_user(%{id: user_id}, payload) when not is_nil(user_id) do
    import Ecto.Query

    subscriptions =
      Repo.all(from s in PushSubscription, where: s.user_id == ^user_id)

    delivered_count =
      Enum.reduce(subscriptions, 0, fn sub, acc ->
        case WebPush.send_notification(sub, payload) do
          {:ok, _} ->
            sub
            |> Ecto.Changeset.change(
              last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
            )
            |> Repo.update()

            acc + 1

          {:error, :subscription_expired} ->
            Repo.delete(sub)
            acc

          _ ->
            acc
        end
      end)

    {:ok, delivered_count}
  end

  defp send_push_to_user(_user, _payload), do: {:ok, 0}
end
