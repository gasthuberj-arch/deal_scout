alias DealScout.Repo
alias DealScout.Feeds.Feed

feeds = [
  %{
    name: "MyDealz",
    slug: "mydealz",
    url: "https://www.mydealz.de/rss"
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
