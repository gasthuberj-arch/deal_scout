defmodule DealScout.Alerts.BacktestTest do
  use DealScout.DataCase
  alias DealScout.Alerts.Backtest
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed

  setup do
    feed =
      Repo.insert!(%Feed{
        name: "MyDealz",
        slug: "mydealz-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "Amazon DE",
        slug: "amazon-de-#{System.unique_integer([:positive])}",
        trust_level: "verified"
      })

    dropshipper =
      Repo.insert!(%Merchant{
        name: "AliExpress Store",
        slug: "aliexpress-#{System.unique_integer([:positive])}",
        trust_level: "dropshipper"
      })

    %{feed: feed, merchant: merchant, dropshipper: dropshipper}
  end

  describe "extract_search_terms/1" do
    test "extracts plain terms" do
      terms = Backtest.extract_search_terms("RTX 4080")
      assert terms == ["RTX", "4080"]
    end

    test "extracts exact quoted phrases" do
      terms = Backtest.extract_search_terms(~s["Apple Watch Ultra" GPS])
      assert terms == ["Apple Watch Ultra", "GPS"]
    end

    test "extracts terms with boolean operators and parentheses" do
      terms = Backtest.extract_search_terms("(RTX 4080 OR RX 7900) 16GB")
      assert Enum.sort(terms) == ["16GB", "4080", "7900", "RTX", "RX"]
    end

    test "extracts comma-separated terms" do
      terms = Backtest.extract_search_terms("OLED, 4K, 120Hz")
      assert Enum.sort(terms) == ["120Hz", "4K", "OLED"]
    end

    test "handles nil and empty strings" do
      assert Backtest.extract_search_terms(nil) == []
      assert Backtest.extract_search_terms("") == []
      assert Backtest.extract_search_terms("   ") == []
    end
  end

  describe "build_fts_query/1" do
    test "builds prefix query for simple terms" do
      query = Backtest.build_fts_query("RTX 4080")
      assert query =~ "\"RTX\"*"
      assert query =~ "\"4080\"*"
      assert query =~ "AND"
    end

    test "builds exact phrase query" do
      query = Backtest.build_fts_query("\"Apple Watch\"")
      assert query == "\"Apple Watch\""
    end

    test "supports OR operators" do
      query = Backtest.build_fts_query("OLED OR QLED")
      assert query =~ "OR"
    end

    test "handles nil or empty input" do
      assert Backtest.build_fts_query(nil) == nil
      assert Backtest.build_fts_query("") == nil
    end
  end

  describe "test_rule/2" do
    test "returns :no_matches when keywords is empty", %{merchant: merchant, feed: feed} do
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "d1",
        title: "Sony WH-1000XM5 Headphones",
        url: "https://example.com/sony",
        price: Decimal.new("299.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      result = Backtest.test_rule(%AlertRule{keywords: ""})
      assert result.status == :no_matches
      assert result.total_matches == 0
      assert result.matches == []
      assert result.last_match == nil
    end

    test "matches historical deal via FTS lookup and returns :match_found", %{
      merchant: merchant,
      feed: feed
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      deal =
        Repo.insert!(%Deal{
          feed_id: feed.id,
          merchant_id: merchant.id,
          guid: "deal-leica-1",
          title: "Leica M11 Rangefinder Digital Camera Body Black",
          clean_text: "Brand new Leica M11 digital camera in stock with warranty.",
          url: "https://example.com/leica",
          price: Decimal.new("7999.00"),
          published_at: now
        })

      result = Backtest.test_rule(%{"keywords" => "Leica M11"})

      assert result.status == :match_found
      assert result.total_matches == 1
      assert result.last_match.id == deal.id
      assert result.last_match.title =~ "Leica M11"
    end

    test "returns :broad_match when matches exceed broad_threshold", %{
      merchant: merchant,
      feed: feed
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..12 do
        Repo.insert!(%Deal{
          feed_id: feed.id,
          merchant_id: merchant.id,
          guid: "deal-nintendo-#{i}",
          title: "Nintendo Switch OLED Deal ##{i}",
          url: "https://example.com/switch-#{i}",
          price: Decimal.new("299.00"),
          published_at: DateTime.add(now, -i, :minute)
        })
      end

      result = Backtest.test_rule(%{"keywords" => "Nintendo Switch"}, broad_threshold: 10)

      assert result.status == :broad_match
      assert result.total_matches >= 12
      assert result.last_match != nil
      assert result.last_match.title =~ "Nintendo Switch"
    end

    test "respects price ceiling filter", %{merchant: merchant, feed: feed} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-expensive-gpu",
        title: "NVIDIA GeForce RTX 4080 SUPER 16GB",
        url: "https://example.com/gpu",
        price: Decimal.new("1100.00"),
        published_at: now
      })

      # Max price 900 -> should not match 1100
      result =
        Backtest.test_rule(%{
          "keywords" => "RTX 4080",
          "max_price" => "900.00"
        })

      assert result.status == :no_matches
      assert result.total_matches == 0

      # Max price 1200 -> should match
      result2 =
        Backtest.test_rule(%{
          "keywords" => "RTX 4080",
          "max_price" => "1200.00"
        })

      assert result2.status == :match_found
      assert result2.total_matches == 1
    end

    test "respects negative keywords filter", %{merchant: merchant, feed: feed} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-defekt-gpu",
        title: "MSI GeForce RTX 4080 defekt für Bastler",
        clean_text: "Grafikkarte startet nicht, Lüfter defekt",
        url: "https://example.com/defekt",
        price: Decimal.new("250.00"),
        published_at: now
      })

      result =
        Backtest.test_rule(%{
          "keywords" => "RTX 4080",
          "negative_keywords" => "defekt, bastler"
        })

      assert result.status == :no_matches
      assert result.total_matches == 0
    end

    test "respects dropshipper exclusion filter", %{
      merchant: merchant,
      dropshipper: dropshipper,
      feed: feed
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: dropshipper.id,
        guid: "deal-dropship-watch",
        title: "Smart Watch Ultra Titanium Edition",
        url: "https://aliexpress.com/item/123",
        price: Decimal.new("25.00"),
        published_at: now
      })

      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-legit-watch",
        title: "Apple Watch Ultra 2 GPS Titanium",
        url: "https://amazon.de/dp/B000",
        price: Decimal.new("799.00"),
        published_at: DateTime.add(now, -5, :minute)
      })

      result =
        Backtest.test_rule(%{
          "keywords" => "Watch Ultra",
          "exclude_dropshippers" => "true"
        })

      assert result.status == :match_found
      assert result.total_matches == 1
      assert result.last_match.merchant_id == merchant.id
    end

    test "respects country filter (de_only)", %{merchant: merchant, feed: feed} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Deal from Amazon FR
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-fr-monitor",
        title: "LG OLED 27GS95QE Gaming Monitor [Amazon.fr]",
        url: "https://www.amazon.fr/dp/B000",
        clean_text: "Livraison gratuite en France et UE",
        price: Decimal.new("650.00"),
        published_at: now
      })

      result =
        Backtest.test_rule(%{
          "keywords" => "LG OLED",
          "country_filter" => "de_only"
        })

      assert result.status == :no_matches
      assert result.total_matches == 0
    end

    test "safely falls back to recent deals table when FTS query fails or produces syntax error",
         %{merchant: merchant, feed: feed} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      deal =
        Repo.insert!(%Deal{
          feed_id: feed.id,
          merchant_id: merchant.id,
          guid: "deal-sinn-104",
          title: "Sinn 104 St Sa I Fliegeruhr Automatic",
          url: "https://example.com/sinn",
          price: Decimal.new("1250.00"),
          published_at: now
        })

      # Pass unclosed parenthesis which would trigger FTS5 syntax error
      result = Backtest.test_rule(%{"keywords" => "Sinn 104 (Fliegeruhr"})

      assert result.status == :match_found
      assert result.total_matches >= 1
      assert result.last_match.id == deal.id
    end

    test "handles nested params under alert_rule key", %{merchant: merchant, feed: feed} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      deal =
        Repo.insert!(%Deal{
          feed_id: feed.id,
          merchant_id: merchant.id,
          guid: "deal-macbook-m3",
          title: "Apple MacBook Pro 14 M3 Pro 18GB 512GB",
          url: "https://example.com/macbook",
          price: Decimal.new("1899.00"),
          published_at: now
        })

      result =
        Backtest.test_rule(%{
          "alert_rule" => %{
            "keywords" => "MacBook Pro M3",
            "max_price" => "2000.00"
          }
        })

      assert result.status == :match_found
      assert result.last_match.id == deal.id
    end
  end
end
