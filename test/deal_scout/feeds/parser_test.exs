defmodule DealScout.Feeds.ParserTest do
  use ExUnit.Case, async: true
  alias DealScout.Feeds.Parser

  @sample_rss """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com" xmlns:media="http://search.yahoo.com/mrss/">
    <channel>
      <title>MyDealz Deals</title>
      <item>
        <title><![CDATA[194° - Edeka regional Milka Adventskalender mit App 6,99, dazu das Milka Teil GZG-3€ = 3,99€]]></title>
        <link>https://www.mydealz.de/deals/edeka-milka-2855694</link>
        <guid>https://www.mydealz.de/deals/edeka-milka-2855694</guid>
        <pubDate>Sun, 18 Oct 2026 16:36:18 +0200</pubDate>
        <description><![CDATA[<strong>6,99€ - EDEKA</strong><br /><img src="https://static.mydealz.de/thumb.jpg" />Idealo: https://www.idealo.de/preisvergleich/OffersOfProduct/12345.html und Geizhals: https://geizhals.de/milka-a98765.html]]></description>
        <pepper:merchant name="EDEKA" price="6,99€"/>
        <media:thumbnail url="https://static.mydealz.de/thumb.jpg" />
      </item>
      <item>
        <title>Google Play 95% Rabatt</title>
        <link>https://play.google.com/store/apps/details?id=sample</link>
        <guid>google-play-1234</guid>
        <pubDate>Sun, 18 Oct 2026 16:33:49 +0200</pubDate>
        <description>Gültig für 95% Rabatt mit maximal 4,00 € Rabatt</description>
      </item>
    </channel>
  </rss>
  """

  test "parses rss items into deal attributes with temperature and comparison links" do
    deals = Parser.parse_feed(@sample_rss, 1)
    assert length(deals) == 2

    first = hd(deals)
    assert first.feed_id == 1
    assert first.guid == "https://www.mydealz.de/deals/edeka-milka-2855694"
    assert first.title =~ "Milka Adventskalender"
    refute first.title =~ "194° -"
    assert first.temperature == 194
    assert first.merchant == "EDEKA"
    assert Decimal.equal?(first.price, Decimal.new("6.99"))
    assert first.image_url == "https://static.mydealz.de/thumb.jpg"
    assert first.idealo_url == "https://www.idealo.de/preisvergleich/OffersOfProduct/12345.html"
    assert first.geizhals_url == "https://geizhals.de/milka-a98765.html"

    second = Enum.at(deals, 1)
    assert second.guid == "google-play-1234"
    assert Decimal.equal?(second.price, Decimal.new("4.00"))
    assert second.temperature == nil
    # Falls back to domain from URL
    assert second.merchant == "play.google.com"
  end

  test "extract_temperature parses various Pepper temperature strings" do
    assert {194, "Super Deal"} = Parser.extract_temperature("194° - Super Deal")
    assert {0, "Free Game"} = Parser.extract_temperature("0° - Free Game")
    assert {-15, "Cold Deal"} = Parser.extract_temperature("-15° - Cold Deal")
    assert {nil, "No Temp In Title"} = Parser.extract_temperature("No Temp In Title")
  end

  test "extract_comparison_links extracts Idealo and Geizhals URLs" do
    snippet = """
    PVG: https://www.idealo.de/preisvergleich/OffersOfProduct/9999.html
    Geizhals Link: https://geizhals.de/asus-rog-a1111.html
    """

    {idealo, geizhals} = Parser.extract_comparison_links(snippet)
    assert idealo == "https://www.idealo.de/preisvergleich/OffersOfProduct/9999.html"
    assert geizhals == "https://geizhals.de/asus-rog-a1111.html"
  end
end
