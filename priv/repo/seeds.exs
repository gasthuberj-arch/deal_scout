alias DealScout.Repo
alias DealScout.Feeds.Feed
alias DealScout.Deals.Deal
alias DealScout.Feeds.Parser
import Ecto.Query

feeds = [
  %{
    name: "MyDealz",
    slug: "mydealz",
    url: "https://www.mydealz.de/rss",
    poll_interval_seconds: 120
  },
  %{
    name: "MyDealz (Hot)",
    slug: "mydealz-hot",
    url: "https://www.mydealz.de/rss/trending",
    poll_interval_seconds: 180
  },
  %{
    name: "DealDoktor",
    slug: "dealdoktor",
    url: "https://www.dealdoktor.de/feed/",
    poll_interval_seconds: 300
  },
  %{
    name: "MonsterDealz",
    slug: "monsterdealz",
    url: "https://www.monsterdealz.de/feed/",
    poll_interval_seconds: 300
  },
  %{
    name: "Mein-Deal",
    slug: "mein-deal",
    url: "https://www.mein-deal.com/feed/",
    poll_interval_seconds: 300
  },
  %{
    name: "Preisjäger",
    slug: "preisjaeger",
    url: "https://www.preisjaeger.at/rss",
    poll_interval_seconds: 180
  },
  %{
    name: "Dealabs",
    slug: "dealabs",
    url: "https://www.dealabs.com/rss",
    poll_interval_seconds: 120
  },
  %{
    name: "Chollometro",
    slug: "chollometro",
    url: "https://www.chollometro.com/rss",
    poll_interval_seconds: 180
  },
  %{
    name: "nl.pepper.com",
    slug: "pepper-nl",
    url: "https://nl.pepper.com/rss",
    poll_interval_seconds: 180
  },
  %{
    name: "GG.deals (Freebies)",
    slug: "ggdeals-freebies",
    url: "https://gg.deals/news/freebies/feed/",
    poll_interval_seconds: 300
  },
  %{
    name: "GG.deals (EU Deals)",
    slug: "ggdeals-news",
    url: "https://gg.deals/eu/news/feed/",
    poll_interval_seconds: 300
  },
  %{
    name: "eBay",
    slug: "ebay",
    url: "https://www.ebay.de",
    poll_interval_seconds: 60,
    is_active: false
  }
]

# Ensure defunct feeds are removed if present
Repo.delete_all(
  from f in Feed,
    where: f.slug in ["reddit-deals", "reddit-bapcsales", "schnaeppchenfuchs"]
)

for feed_attrs <- feeds do
  Repo.insert!(
    struct(Feed, feed_attrs),
    on_conflict: [
      set: [
        name: feed_attrs.name,
        url: feed_attrs.url,
        poll_interval_seconds: feed_attrs.poll_interval_seconds
      ]
    ],
    conflict_target: :slug
  )
end

# Backfill existing deals with merchant_id, comparison links, and temperature
deals_to_backfill = Repo.all(from d in Deal, where: is_nil(d.merchant_id))

Enum.each(deals_to_backfill, fn deal ->
  feed = Repo.get(Feed, deal.feed_id)
  feed_slug = if feed, do: feed.slug, else: nil

  {idealo_url, geizhals_url} =
    Parser.extract_comparison_links((deal.description || "") <> " " <> (deal.clean_text || ""))

  {temperature, clean_title} = Parser.extract_temperature(deal.title)

  merchant =
    DealScout.Deals.Ingestion.backfill_deal_merchant(deal,
      feed_slug: feed_slug,
      temperature: temperature
    )

  deal
  |> Deal.changeset(%{
    merchant_id: merchant.id,
    title: clean_title,
    temperature: temperature,
    idealo_url: deal.idealo_url || idealo_url,
    geizhals_url: deal.geizhals_url || geizhals_url
  })
  |> Repo.update()
end)

# Default admin account
admin_email = System.get_env("ADMIN_EMAIL", "admin@dealscout.de")
admin_pass = System.get_env("ADMIN_PASSWORD", "dealscout2026!")

case Repo.get_by(DealScout.Accounts.User, email: admin_email) do
  nil ->
    %DealScout.Accounts.User{
      email: admin_email,
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      is_admin: true
    }
    |> DealScout.Accounts.User.password_changeset(%{password: admin_pass})
    |> Repo.insert!()

  user ->
    user
    |> Ecto.Changeset.change(%{
      is_admin: true,
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> DealScout.Accounts.User.password_changeset(%{password: admin_pass})
    |> Repo.update!()
end
