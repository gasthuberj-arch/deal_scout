defmodule DealScout.Feeds do
  @moduledoc """
  The Feeds context for managing RSS feed sources.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Feeds.Feed

  def list_feeds do
    Repo.all(from f in Feed, order_by: f.name)
  end

  def list_active_feeds do
    Repo.all(from f in Feed, where: f.is_active == true, order_by: f.name)
  end

  @doc """
  Returns all active feeds directly from DB that are currently due for polling
  (i.e. not in backoff and whose last_fetched_at is nil or older than poll_interval_seconds).
  """
  def list_due_feeds(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    from(f in Feed,
      where: f.is_active == true,
      where: is_nil(f.backoff_until) or f.backoff_until <= ^now,
      order_by: [asc_nulls_first: f.last_fetched_at, asc: f.id]
    )
    |> Repo.all()
    |> Enum.filter(&due_for_fetch?(&1, now))
  end

  defp due_for_fetch?(%Feed{last_fetched_at: nil}, _now), do: true

  defp due_for_fetch?(
         %Feed{last_fetched_at: last_fetched_at, poll_interval_seconds: interval},
         now
       ) do
    interval = interval || 120
    DateTime.diff(now, last_fetched_at, :second) >= interval
  end

  def get_feed!(id), do: Repo.get!(Feed, id)

  def get_feed(id), do: Repo.get(Feed, id)

  def get_feed_by_slug(slug) do
    Repo.get_by(Feed, slug: slug)
  end

  def update_feed(%Feed{} = feed, attrs) do
    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
  end
end
