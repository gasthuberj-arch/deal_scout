defmodule DealScout.Notifications.Dispatcher do
  @moduledoc """
  Single **Match delivery** module for DealScout.

  Owns the full notification lifecycle for recorded `UserMatch` records:
  - Immediate LiveView inbox broadcasts over `Phoenix.PubSub`
  - **Cooldown** enforcement (suppresses push/email bursts while still broadcasting to the inbox)
  - Instant single-match and collapsed multi-match batch delivery
  - **Digest** queueing (`digest_at`) and periodic flushing (`flush_pending_digests/1`)
  - Accurate `notified_via_push` and `notified_via_email` recording based on actual transport success
  """

  import Ecto.Query, warn: false
  require Logger

  alias DealScout.Accounts.UserNotifier
  alias DealScout.Alerts.{AlertRule, UserMatch}
  alias DealScout.Notifications
  alias DealScout.Repo

  @pubsub DealScout.PubSub
  @digest_modes ~w(hourly_digest daily_digest)

  def user_topic(user_id), do: "user:#{user_id}:matches"

  @doc """
  Dispatches a single deal match.
  Respects rule cooldown, `delivery_mode` (instant vs digest), `notify_push`, and `notify_email`.
  """
  def dispatch(%UserMatch{} = match) do
    match = Repo.preload(match, [:user, [deal: [:feed, :merchant]], :alert_rule])
    rule = match.alert_rule

    # 1. Real-time PubSub for LiveView inbox (always immediate)
    broadcast_liveview(match)

    cond do
      rule && AlertRule.in_cooldown?(rule) ->
        {:ok, match}

      rule && rule.delivery_mode in @digest_modes ->
        queue_for_digest(match)

      true ->
        deliver_instant_single(match, rule)
    end
  end

  @doc """
  Dispatches a batch of matches belonging to the same alert rule produced in a single polling run.
  Always broadcasts each match to the LiveView inbox immediately, then respects **Cooldown**,
  queues for **Digest**, or delivers a single/collapsed instant notification.
  """
  def dispatch_batch(%AlertRule{} = rule, matches) when is_list(matches) do
    matches = Repo.preload(matches, [:user, [deal: [:feed, :merchant]], :alert_rule])

    # 1. Real-time PubSub for LiveView inbox (always immediate, even during cooldown)
    Enum.each(matches, &broadcast_liveview/1)

    cond do
      matches == [] ->
        :ok

      AlertRule.in_cooldown?(rule) ->
        :ok

      rule.delivery_mode in @digest_modes ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Enum.each(matches, fn m ->
          m
          |> Ecto.Changeset.change(%{digest_at: now})
          |> Repo.update()
        end)

        :ok

      length(matches) == 1 ->
        {:ok, _match} = deliver_instant_single(hd(matches), rule)
        :ok

      true ->
        deliver_instant_batch(rule, matches)
        :ok
    end
  end

  @doc """
  Flushes all pending digest matches whose quiet window (`hourly_digest` or `daily_digest`)
  has elapsed (or all queued digest matches when `force: true`), grouping by user and
  delivering one consolidated digest per user.
  Returns the number of digest matches processed.
  """
  def flush_pending_digests(opts \\ []) do
    force = Keyword.get(opts, :force, false)
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)
    one_day_ago = DateTime.add(now, -86_400, :second)

    base_query =
      from m in UserMatch,
        join: r in assoc(m, :alert_rule),
        join: u in assoc(m, :user),
        where:
          not is_nil(m.digest_at) and m.notified_via_push == false and
            m.notified_via_email == false,
        preload: [:user, [deal: [:feed, :merchant]], :alert_rule]

    query =
      if force do
        base_query
      else
        from [m, r, u] in base_query,
          where:
            (r.delivery_mode == "hourly_digest" and m.digest_at <= ^one_hour_ago) or
              (r.delivery_mode == "daily_digest" and m.digest_at <= ^one_day_ago)
      end

    matches = Repo.all(query)

    matches
    |> Enum.group_by(& &1.user)
    |> Enum.each(fn {user, user_matches} ->
      dispatch_digest(user, user_matches, "Deal")
    end)

    length(matches)
  rescue
    e ->
      Logger.error("[DealScout.Dispatcher] Error flushing digests: #{Exception.message(e)}")
      0
  end

  @doc """
  Dispatches a consolidated digest of matches to a user and marks each match's
  `notified_via_push` and `notified_via_email` flags according to actual delivery success,
  clearing `digest_at` so processed matches are not re-queued.
  """
  def dispatch_digest(user, matches, period_label) when is_list(matches) and matches != [] do
    matches = Repo.preload(matches, [:user, [deal: [:feed, :merchant]], :alert_rule])
    count = length(matches)
    top_match = hd(matches)

    any_push? =
      Enum.any?(matches, fn m -> is_nil(m.alert_rule) or m.alert_rule.notify_push != false end)

    push_delivered? =
      if any_push? do
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

        {:ok, delivered_count} = send_push_to_user(user, payload)
        delivered_count > 0
      else
        false
      end

    any_email? = Enum.any?(matches, fn m -> m.alert_rule && m.alert_rule.notify_email end)

    email_delivered? =
      if any_email? do
        deliver_email_notification(top_match)
      else
        false
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(matches, fn m ->
      m
      |> Ecto.Changeset.change(%{
        notified_via_push: push_delivered?,
        notified_via_email: email_delivered?,
        digest_at: nil
      })
      |> Repo.update()
    end)

    if push_delivered? or email_delivered? do
      matches
      |> Enum.map(& &1.alert_rule)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.each(&touch_rule_last_notified(&1, now))
    end

    :ok
  end

  def dispatch_digest(_user, _matches, _period_label), do: :ok

  # ============================================================================
  # Internal Delivery Helpers
  # ============================================================================

  defp broadcast_liveview(%UserMatch{user_id: user_id} = match) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {:new_match, match})
  end

  defp queue_for_digest(%UserMatch{} = match) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    match
    |> Ecto.Changeset.change(%{digest_at: now})
    |> Repo.update()
  end

  defp deliver_instant_single(%UserMatch{} = match, rule) do
    push_delivered? =
      if rule && rule.notify_push && !match.notified_via_push do
        deliver_single_push(match)
      else
        match.notified_via_push || false
      end

    email_delivered? =
      if (is_nil(rule) or rule.notify_email != false) && !match.notified_via_email do
        deliver_email_notification(match)
      else
        match.notified_via_email || false
      end

    updated_match =
      update_match_delivery_flags(match, %{
        notified_via_push: push_delivered?,
        notified_via_email: email_delivered?
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    touch_rule_last_notified(rule, now)

    {:ok, updated_match}
  end

  defp deliver_instant_batch(%AlertRule{} = rule, matches) do
    first_match = hd(matches)
    user = first_match.user
    deal_count = length(matches)

    push_delivered? =
      if rule.notify_push do
        payload = build_batch_push_payload(rule, matches, first_match, deal_count)
        {:ok, count} = send_push_to_user(user, payload)
        count > 0
      else
        false
      end

    email_delivered? =
      if rule.notify_email do
        deliver_email_notification(first_match)
      else
        false
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(matches, fn m ->
      update_match_delivery_flags(m, %{
        notified_via_push: push_delivered?,
        notified_via_email: email_delivered?
      })
    end)

    touch_rule_last_notified(rule, now)
  end

  defp deliver_single_push(%UserMatch{user: %{id: user_id}} = match) when not is_nil(user_id) do
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
    count > 0
  end

  defp deliver_single_push(_match), do: false

  defp build_batch_push_payload(rule, matches, first_match, deal_count) do
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

    %{
      title: title,
      body: "#{deal_titles}#{if deal_count > 2, do: " and #{deal_count - 2} more", else: ""}",
      url: "/matches?highlight=#{first_match.id}",
      icon: (first_match.deal && first_match.deal.image_url) || "/images/icon-192.png",
      badge: "/images/badge-72.png",
      idealo_url: first_match.deal && first_match.deal.idealo_url,
      geizhals_url: first_match.deal && first_match.deal.geizhals_url,
      tag: "batch-rule-#{rule.id}-#{System.system_time(:second)}"
    }
  end

  defp deliver_email_notification(%UserMatch{user: user, deal: deal, alert_rule: rule} = match) do
    case UserNotifier.deliver_deal_alert(user, deal, rule) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.error(
          "[DealScout.Dispatcher] Failed to deliver deal alert email for match #{match.id}: #{inspect(reason)}"
        )

        false

      _ ->
        false
    end
  rescue
    e ->
      Logger.error(
        "[DealScout.Dispatcher] Exception delivering deal alert email for match #{match.id}: #{Exception.message(e)}"
      )

      false
  end

  defp update_match_delivery_flags(%UserMatch{} = match, attrs) do
    if match.id && match.__meta__.state == :loaded do
      case match |> Ecto.Changeset.change(attrs) |> Repo.update() do
        {:ok, updated} -> updated
        _ -> Map.merge(match, attrs)
      end
    else
      Map.merge(match, attrs)
    end
  end

  defp touch_rule_last_notified(%AlertRule{id: id} = rule, now)
       when not is_nil(id) and rule.__meta__.state == :loaded do
    rule
    |> Ecto.Changeset.change(%{last_notified_at: now})
    |> Repo.update()
  end

  defp touch_rule_last_notified(_rule, _now), do: :ok

  defp send_push_to_user(user, payload) do
    {:ok, results} = Notifications.deliver_push_to_user(user, payload)
    delivered_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, delivered_count}
  end
end
