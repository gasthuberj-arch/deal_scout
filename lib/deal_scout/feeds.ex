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

  def get_feed!(id), do: Repo.get!(Feed, id)

  def get_feed_by_slug(slug) do
    Repo.get_by(Feed, slug: slug)
  end

  def update_feed(%Feed{} = feed, attrs) do
    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
  end
end
