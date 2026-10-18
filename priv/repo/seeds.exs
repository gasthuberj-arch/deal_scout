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
    Deals.get_or_create_merchant(deal.raw_merchant,
      url: deal.url,
      text: deal.clean_text,
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
