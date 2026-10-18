defmodule DealScout.Notifications.Dispatcher do
  @moduledoc """
  Extensible notification dispatcher for deal alert matches.
  Handles real-time LiveView PubSub broadcasts, optional email alerts,
  and future channels (Telegram, Webhooks).
  """

  require Logger

  alias DealScout.Alerts.UserMatch
  alias DealScout.Repo

  @pubsub DealScout.PubSub

  def user_topic(user_id), do: "user:#{user_id}:matches"

  @doc """
  Dispatches a new deal match to all configured channels for the user.
  """
  def dispatch(%UserMatch{} = match) do
    match = Repo.preload(match, [:user, [deal: [:feed, :merchant]], :alert_rule])

    # 1. Real-time PubSub for LiveView
    broadcast_liveview(match)

    # 2. Email delivery if configured / unnotified
    case dispatch_email(match) do
      {:ok, updated_match} -> {:ok, updated_match}
      _ -> {:ok, match}
    end
  end

  defp broadcast_liveview(%UserMatch{user_id: user_id} = match) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {:new_match, match})
  end

  defp dispatch_email(
         %UserMatch{notified_via_email: false, user: user, deal: deal, alert_rule: rule} = match
       ) do
    # In dev or production when mailer is configured, deliver deal alert notification
    case DealScout.Accounts.UserNotifier.deliver_deal_alert(user, deal, rule) do
      {:ok, _} ->
        match
        |> Ecto.Changeset.change(%{notified_via_email: true})
        |> Repo.update()

      {:error, reason} ->
        Logger.error(
          "[DealScout.Dispatcher] Failed to deliver deal alert email for match #{match.id}: #{inspect(reason)}"
        )

        {:ok, match}

      _ ->
        {:ok, match}
    end
  rescue
    e ->
      Logger.error(
        "[DealScout.Dispatcher] Exception delivering deal alert email for match #{match.id}: #{Exception.message(e)}"
      )

      {:ok, match}
  end

  defp dispatch_email(match), do: {:ok, match}
end
