defmodule DealScout.Feeds.ParserTest do
  use ExUnit.Case, async: true
  alias DealScout.Feeds.Parser

  @sample_rss """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com" xmlns:media="http://search.yahoo.com/mrss/">
    <channel>
      <title>MyDealz Deals</title>
      <item>
        <title><![CDATA[Edeka regional Milka Adventskalender mit App 6,99, dazu das Milka Teil GZG-3€ = 3,99€]]></title>
        <link>https://www.mydealz.de/deals/edeka-milka-2855694</link>
        <guid>https://www.mydealz.de/deals/edeka-milka-2855694</guid>
        <pubDate>Sun, 18 Oct 2026 16:36:18 +0200</pubDate>
        <description><![CDATA[<strong>6,99€ - EDEKA</strong><br /><img src="https://static.mydealz.de/thumb.jpg" />Angebot Edeka Südwest]]></description>
        <pepper:merchant name="EDEKA" price="6,99€"/>
        <media:thumbnail url="https://static.mydealz.de/thumb.jpg" />
      </item>
      <item>
        <title>Google Play 95% Rabatt</title>
        <link>https://www.mydealz.de/deals/google-play</link>
        <guid>google-play-1234</guid>
        <pubDate>Sun, 18 Oct 2026 16:33:49 +0200</pubDate>
        <description>Gültig für 95% Rabatt mit maximal 4,00 € Rabatt</description>
      </item>
    </channel>
  </rss>
  """

  test "parses rss items into deal attributes" do
    deals = Parser.parse_feed(@sample_rss, 1)
    assert length(deals) == 2

    first = hd(deals)
    assert first.feed_id == 1
    assert first.guid == "https://www.mydealz.de/deals/edeka-milka-2855694"
    assert first.title =~ "Milka Adventskalender"
    assert first.merchant == "EDEKA"
    assert Decimal.equal?(first.price, Decimal.new("6.99"))
    assert first.image_url == "https://static.mydealz.de/thumb.jpg"
    assert first.clean_text =~ "Angebot Edeka"

    second = Enum.at(deals, 1)
    assert second.guid == "google-play-1234"
    assert Decimal.equal?(second.price, Decimal.new("4.00"))
  end
end
