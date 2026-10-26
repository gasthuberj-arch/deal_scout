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

  @sample_atom """
  <?xml version="1.0" encoding="UTF-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
    <title>reddit: deals</title>
    <entry>
      <title>[Amazon] Logitech MX Master 3S Wireless Mouse - 79.99€ (was 109€)</title>
      <link href="https://www.reddit.com/r/dealdoktor/comments/12345/logitech_mx_master/" />
      <id>t3_12345</id>
      <updated>2026-10-18T14:20:00+00:00</updated>
      <content type="html">&lt;p&gt;Direct link: https://www.amazon.de/dp/B09HM94VDS&lt;/p&gt;&lt;p&gt;Idealo: https://www.idealo.de/preisvergleich/OffersOfProduct/mx3s.html&lt;/p&gt;</content>
    </entry>
  </feed>
  """

  test "parses Atom feed entries (Reddit format)" do
    deals = Parser.parse_feed(@sample_atom, 99)
    assert length(deals) == 1

    deal = hd(deals)
    assert deal.feed_id == 99
    assert deal.guid == "t3_12345"
    assert deal.url == "https://www.reddit.com/r/dealdoktor/comments/12345/logitech_mx_master/"
    assert deal.title =~ "Logitech MX Master 3S"
    assert Decimal.equal?(deal.price, Decimal.new("79.99"))
    assert deal.idealo_url == "https://www.idealo.de/preisvergleich/OffersOfProduct/mx3s.html"
  end

  describe "price extraction edge cases and German formatting" do
    test "parses TCL 98Q7D PRO bundle and German thousands separators accurately" do
      tcl_rss = """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:pepper="https://www.pepper.com">
        <channel>
          <title>TV Deals</title>
          <item>
            <title><![CDATA[TCL-Bundle | 98Q7D PRO SQD-Mini LED Fernseher (98", 1152 Dimming-Zonen, 2000 Nits, 144Hz) + 2x TCL Z100 Dolby Atmos FlexConnect Lautsprecher]]></title>
            <link>https://www.mydealz.de/deals/tcl-bundle-98q7d-pro-2857999</link>
            <guid>tcl-bundle-98q7d-pro-1</guid>
            <pubDate>Mon, 26 Oct 2026 12:00:00 +0100</pubDate>
            <description><![CDATA[<strong>2.199€ - Amazon</strong><br />Top Mini-LED TV Bundle]]></description>
            <pepper:merchant name="Amazon" price="2.199€"/>
          </item>
          <item>
            <title><![CDATA[Kino-Feeling! 📺 TCL 98Q7D Pro – 98 Zoll SQD-Mini LED Fernseher für 2.193€ 🍿]]></title>
            <link>https://schnaeppchenfuchs.com/angebote/tcl-98q7d-pro-98</link>
            <guid>tcl-bundle-98q7d-pro-2</guid>
            <pubDate>Mon, 26 Oct 2026 12:05:00 +0100</pubDate>
            <description><![CDATA[TCL 98Q7D Pro – 98 Zoll SQD-Mini LED Fernseher für 2.192,99€ inkl. Versand bei amazon.de (Preisvergleich: 2.539€)]]></description>
          </item>
        </channel>
      </rss>
      """

      [pepper_deal, text_deal] = Parser.parse_feed(tcl_rss, 1)
      assert Decimal.equal?(pepper_deal.price, Decimal.new("2199.00"))
      assert Decimal.equal?(text_deal.price, Decimal.new("2193.00"))
    end

    test "parse_price_string handles common European and international price formats" do
      assert Decimal.equal?(Parser.parse_price_string("2.199€"), Decimal.new("2199.00"))
      assert Decimal.equal?(Parser.parse_price_string("2.192,99€"), Decimal.new("2192.99"))
      assert Decimal.equal?(Parser.parse_price_string("28.999 €"), Decimal.new("28999.00"))
      assert Decimal.equal?(Parser.parse_price_string("1 299€"), Decimal.new("1299.00"))
      assert Decimal.equal?(Parser.parse_price_string("1 531,42€"), Decimal.new("1531.42"))
      assert Decimal.equal?(Parser.parse_price_string("999,-€"), Decimal.new("999.00"))
      assert Decimal.equal?(Parser.parse_price_string("4.500,-- €"), Decimal.new("4500.00"))
      assert Decimal.equal?(Parser.parse_price_string("79.99€"), Decimal.new("79.99"))
      assert Decimal.equal?(Parser.parse_price_string("100 Euro"), Decimal.new("100.00"))
      assert Decimal.equal?(Parser.parse_price_string("19,99 EUR"), Decimal.new("19.99"))
    end

    test "extracts 0.00 price for explicit freebies without confusing free shipping" do
      freebie_rss = """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0">
        <channel>
          <title>Freebies</title>
          <item>
            <title>[Gratis statt 99,99 $] Muze Savage – 432 Synth- &amp; Bass-Presets</title>
            <link>https://www.mydealz.de/deals/gratis-muze-savage</link>
            <guid>freebie-1</guid>
            <description>Aktuell kostenlos sichern.</description>
          </item>
          <item>
            <title>BVB Shop - Versandkostenfrei!</title>
            <link>https://www.mydealz.de/gutscheine/bvb-shop-versandkostenfrei</link>
            <guid>voucher-shipping-only</guid>
            <description>NUR HEUTE: Kostenloser Versand im Onlineshop!</description>
          </item>
        </channel>
      </rss>
      """

      [free_deal, shipping_deal] = Parser.parse_feed(freebie_rss, 1)
      assert Decimal.equal?(free_deal.price, Decimal.new("0.00"))
      assert shipping_deal.price == nil
    end
  end
end
