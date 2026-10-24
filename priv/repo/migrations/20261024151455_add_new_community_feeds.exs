defmodule DealScout.Repo.Migrations.AddNewCommunityFeeds do
  use Ecto.Migration

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    new_feeds = [
      %{
        name: "Chollometro",
        slug: "chollometro",
        url: "https://www.chollometro.com/rss",
        poll_interval_seconds: 180,
        is_active: true,
        consecutive_errors: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "nl.pepper.com",
        slug: "pepper-nl",
        url: "https://nl.pepper.com/rss",
        poll_interval_seconds: 180,
        is_active: true,
        consecutive_errors: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "GG.deals (Freebies)",
        slug: "ggdeals-freebies",
        url: "https://gg.deals/news/freebies/feed/",
        poll_interval_seconds: 300,
        is_active: true,
        consecutive_errors: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "GG.deals (EU Deals)",
        slug: "ggdeals-news",
        url: "https://gg.deals/eu/news/feed/",
        poll_interval_seconds: 300,
        is_active: true,
        consecutive_errors: 0,
        inserted_at: now,
        updated_at: now
      }
    ]

    for feed <- new_feeds do
      execute """
      INSERT INTO feeds (name, slug, url, poll_interval_seconds, is_active, consecutive_errors, inserted_at, updated_at)
      VALUES ('#{feed.name}', '#{feed.slug}', '#{feed.url}', #{feed.poll_interval_seconds}, 1, 0, '#{DateTime.to_iso8601(feed.inserted_at)}', '#{DateTime.to_iso8601(feed.updated_at)}')
      ON CONFLICT(slug) DO UPDATE SET
        name = excluded.name,
        url = excluded.url,
        poll_interval_seconds = excluded.poll_interval_seconds;
      """
    end
  end

  def down do
    execute "DELETE FROM feeds WHERE slug IN ('chollometro', 'pepper-nl', 'ggdeals-freebies', 'ggdeals-news');"
  end
end
