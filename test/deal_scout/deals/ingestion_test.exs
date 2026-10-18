defmodule DealScout.Deals.IngestionTest do
  use DealScout.DataCase, async: true

  alias DealScout.Deals
  alias DealScout.Deals.{Deal, Merchant, Ingestion, CrossBorderGuard}
  alias DealScout.Feeds.Feed
  alias DealScout.Alerts
  alias DealScout.Alerts.UserMatch
  alias DealScout.Repo

  @sample_rss """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com">
    <channel>
      <title>Test Deals</title>
      <item>
        <title><![CDATA[150° - Sony WH-1000XM5 ANC Kopfhörer]]></title>
        <link>https://www.mediamarkt.de/de/product/-2855694.html</link>
        <guid>guid-sony-xm5-1</guid>
        <pubDate>Sun, 18 Oct 2026 16:36:18 +0200</pubDate>
        <description><![CDATA[<strong>249,00€ - MediaMarkt</strong><br />Top Angebot!]]></description>
        <pepper:merchant name="MediaMarkt" price="249,00€"/>
      </item>
    </channel>
  </rss>
  """

  @multi_rss """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com">
    <channel>
      <title>Amazon Deals</title>
      <item>
        <title><![CDATA[100° - Apple iPhone 15 128GB]]></title>
        <link>https://www.amazon.de/dp/B0CHX1TNVL</link>
        <guid>guid-amazon-iphone-1</guid>
        <pubDate>Sun, 18 Oct 2026 16:00:00 +0200</pubDate>
        <description><![CDATA[749,00€]]></description>
        <pepper:merchant name="Amazon" price="749,00€"/>
      </item>
      <item>
        <title><![CDATA[200° - Apple MacBook Air M3]]></title>
        <link>https://www.amazon.de/dp/B0CX23V251</link>
        <guid>guid-amazon-macbook-2</guid>
        <pubDate>Sun, 18 Oct 2026 16:10:00 +0200</pubDate>
        <description><![CDATA[1099,00€]]></description>
        <pepper:merchant name="Amazon" price="1099,00€"/>
      </item>
    </channel>
  </rss>
  """

  @cross_border_rss """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com">
    <channel>
      <title>Cross Border Deal</title>
      <item>
        <title><![CDATA[80° - Asus ZenBook 14 OLED Laptop]]></title>
        <link>https://www.amazon.fr/dp/B0CZ3NVL89</link>
        <guid>guid-asus-fr-1</guid>
        <pubDate>Sun, 18 Oct 2026 16:20:00 +0200</pubDate>
        <description><![CDATA[799,00€ - Amazon FR]]></description>
        <pepper:merchant name="Amazon FR" price="799,00€"/>
      </item>
    </channel>
  </rss>
  """

  setup do
    feed =
      Repo.insert!(%Feed{
        name: "MyDealz",
        slug: "mydealz",
        url: "https://www.mydealz.de/rss"
      })

    %{feed: feed}
  end

  describe "ingest_feed/2 idempotency and merchant stats" do
    test "creates deals and sets merchant deal_count to 1, repeated poll does not increment", %{
      feed: feed
    } do
      # 1. First ingestion
      assert {:ok, [deal]} = Ingestion.ingest_feed(feed, @sample_rss)
      assert deal.guid == "guid-sony-xm5-1"
      assert deal.title =~ "Sony WH-1000XM5"
      assert deal.temperature == 150

      merchant = Repo.get_by!(Merchant, slug: "mediamarkt")
      assert merchant.deal_count == 1
      assert merchant.avg_temperature == 150.0
      assert merchant.feed_counts == %{"mydealz" => 1}

      # 2. Second ingestion of the same feed (duplicate GUIDs)
      assert {:ok, []} = Ingestion.ingest_feed(feed, @sample_rss)

      # 3. Verify merchant deal_count is STILL 1 and avg_temperature is uncorrupted
      merchant_after = Repo.get_by!(Merchant, slug: "mediamarkt")
      assert merchant_after.deal_count == 1
      assert merchant_after.avg_temperature == 150.0
      assert merchant_after.feed_counts == %{"mydealz" => 1}
    end

    test "ingesting multiple new deals for same merchant increments stats accurately", %{
      feed: feed
    } do
      assert {:ok, deals} = Ingestion.ingest_feed(feed, @multi_rss)
      assert length(deals) == 2

      merchant = Repo.get_by!(Merchant, slug: "amazon")
      assert merchant.deal_count == 2
      # (100 + 200) / 2 = 150.0
      assert merchant.avg_temperature == 150.0
      assert merchant.feed_counts == %{"mydealz" => 2}

      # Re-ingest duplicate
      assert {:ok, []} = Ingestion.ingest_feed(feed, @multi_rss)

      merchant_after = Repo.get_by!(Merchant, slug: "amazon")
      assert merchant_after.deal_count == 2
      assert merchant_after.avg_temperature == 150.0
    end
  end

  describe "ingest_feed/2 pipeline integration" do
    test "broadcasts newly ingested deals via PubSub", %{feed: feed} do
      Deals.subscribe()

      assert {:ok, [deal]} = Ingestion.ingest_feed(feed, @sample_rss)
      assert_receive {:new_deal, %Deal{id: id}}
      assert id == deal.id
    end

    test "matches user alert rules on new deals", %{feed: feed} do
      user =
        Repo.insert!(%DealScout.Accounts.User{
          email: "alert_tester_#{System.unique_integer()}@example.com",
          hashed_password: "dummy"
        })

      rule =
        Repo.insert!(%Alerts.AlertRule{
          user_id: user.id,
          name: "Sony Headphones",
          keywords: "sony",
          is_active: true
        })

      assert {:ok, [deal]} = Ingestion.ingest_feed(feed, @sample_rss)

      match = Repo.get_by(UserMatch, user_id: user.id, deal_id: deal.id, alert_rule_id: rule.id)
      assert match != nil
    end

    test "evaluates cross border origin and keyboard warnings at ingestion time", %{feed: feed} do
      assert {:ok, [deal]} = Ingestion.ingest_feed(feed, @cross_border_rss)

      assert deal.cross_border_evaluated == true
      assert deal.country != nil
      assert deal.country.code == "FR"
      assert deal.keyboard_warning != nil
      assert deal.keyboard_warning.layout =~ "AZERTY"

      # CrossBorderGuard returns precomputed result without re-parsing regexes
      assert CrossBorderGuard.detect_country(deal) == deal.country
      assert CrossBorderGuard.keyboard_warning(deal) == deal.keyboard_warning
    end

    test "handles malformed or invalid inputs gracefully", %{feed: feed} do
      assert {:error, :invalid_arguments} = Ingestion.ingest_feed(nil, @sample_rss)
      assert {:error, :invalid_arguments} = Ingestion.ingest_feed(feed, 123)
    end
  end
end
