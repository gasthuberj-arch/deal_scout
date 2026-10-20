defmodule DealScout.Notifications.DigestWorker do
  @moduledoc """
  Periodic GenServer that compiles and dispatches consolidated hourly and daily
  deal digests to users who have configured digest delivery modes on their alert rules.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias DealScout.Repo
  alias DealScout.Alerts.UserMatch
  alias DealScout.Notifications.Dispatcher

  # Check every 15 minutes by default
  @default_interval :timer.minutes(15)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_check(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:check_digests, state) do
    send_pending_digests()
    schedule_check(state.interval)
    {:noreply, state}
  end

  @doc """
  Processes all pending unnotified digest matches and dispatches
  consolidated summaries to each user.
  """
  def send_pending_digests(opts \\ []) do
    force = Keyword.get(opts, :force, false)
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)
    one_day_ago = DateTime.add(now, -86400, :second)

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

    # Group matches by user
    matches
    |> Enum.group_by(& &1.user)
    |> Enum.each(fn {user, user_matches} ->
      Dispatcher.dispatch_digest(user, user_matches, "Deal")
    end)

    length(matches)
  rescue
    e ->
      Logger.error("[DigestWorker] Error processing digests: #{Exception.message(e)}")
      0
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_digests, interval)
  end
end
