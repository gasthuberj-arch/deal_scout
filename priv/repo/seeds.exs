alias DealScout.Repo
alias DealScout.Feeds.Feed
alias DealScout.Deals
alias DealScout.Deals.Deal
alias DealScout.Feeds.Parser
import Ecto.Query

feeds = [
  %{
    name: "MyDealz",
    slug: "mydealz",
    url: "https://www.mydealz.de/rss"
  },
  %{
    name: "MyDealz (Hot)",
    slug: "mydealz-hot",
    url: "https://www.mydealz.de/rss/trending"
  },
  %{
    name: "DealDoktor",
    slug: "dealdoktor",
    url: "https://www.dealdoktor.de/feed/"
  },
  %{
    name: "MonsterDealz",
    slug: "monsterdealz",
    url: "https://www.monsterdealz.de/feed/"
  },
  %{
    name: "Schnäppchenfuchs",
    slug: "schnaeppchenfuchs",
    url: "https://schnaeppchenfuchs.com/rss"
  },
  %{
    name: "Mein-Deal",
    slug: "mein-deal",
    url: "https://www.mein-deal.com/feed/"
  },
  %{
    name: "Preisjäger",
    slug: "preisjaeger",
    url: "https://www.preisjaeger.at/rss"
  },
  %{
    name: "Dealabs",
    slug: "dealabs",
    url: "https://www.dealabs.com/rss"
  },
  %{
    name: "Reddit Deals",
    slug: "reddit-deals",
    url: "https://www.reddit.com/r/dealdoktor/.rss"
  },
  %{
    name: "Reddit BAPC",
    slug: "reddit-bapcsales",
    url: "https://www.reddit.com/r/bapcsales/.rss"
  }
]

for feed_attrs <- feeds do
  Repo.insert!(
    struct(Feed, feed_attrs),
    on_conflict: [set: [name: feed_attrs.name, url: feed_attrs.url]],
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
admin_email = "admin@dealscout.de"
admin_pass = "dealscout2026!"

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
