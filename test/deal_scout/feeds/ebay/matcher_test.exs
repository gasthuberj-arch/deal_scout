defmodule DealScout.Feeds.Ebay.MatcherTest do
  use DealScout.DataCase, async: false

  alias DealScout.AccountsFixtures
  alias DealScout.Alerts
  alias DealScout.Deals.Deal
  alias DealScout.Feeds.Ebay.Matcher
  alias DealScout.Repo

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, user: user}
  end

  test "discards non-matching items without persisting them to SQLite", %{user: user} do
    {:ok, _rule} =
      Alerts.create_alert_rule(user, %{
        name: "RTX Cards",
        keywords: "RTX 4080",
        source_filter: "all"
      })

    item = %{
      guid: "ebay-v1|999|0",
      title: "PlayStation 5 Pro Digital Edition",
      url: "https://www.ebay.de/itm/999",
      price: Decimal.new("699.00"),
      clean_text: "PlayStation 5 Pro Digital Edition Zustand: Neu",
      description: "Zustand: Neu",
      temperature: 100,
      image_url: "https://example.com/ps5.jpg",
      raw_merchant: "eBay",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    assert {:ok, result} = Matcher.evaluate_and_persist([item])
    assert result.matched_deals == []
    assert result.discarded_count == 1

    # Verify zero deals written to SQLite
    assert Repo.aggregate(Deal, :count) == 0
  end

  test "persists matching deal, records user match, and discards non-matching", %{user: user} do
    {:ok, rule} =
      Alerts.create_alert_rule(user, %{
        name: "RTX Sniper",
        keywords: "RTX 4080",
        max_price: Decimal.new("850.00"),
        source_filter: "all"
      })

    matching_item = %{
      guid: "ebay-v1|1001|0",
      title: "NVIDIA GeForce RTX 4080 16GB",
      url: "https://www.ebay.de/itm/1001",
      price: Decimal.new("750.00"),
      clean_text: "NVIDIA GeForce RTX 4080 16GB Zustand: Gebraucht",
      description: "Zustand: Gebraucht | Verkäufer: test_seller",
      temperature: 100,
      image_url: "https://example.com/rtx.jpg",
      raw_merchant: "eBay",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    expensive_item = %{
      guid: "ebay-v1|1002|0",
      title: "NVIDIA GeForce RTX 4080 16GB",
      url: "https://www.ebay.de/itm/1002",
      price: Decimal.new("950.00"),
      clean_text: "NVIDIA GeForce RTX 4080 16GB",
      description: "Too expensive",
      temperature: 100,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    assert {:ok, result} = Matcher.evaluate_and_persist([matching_item, expensive_item])
    assert length(result.matched_deals) == 1
    assert result.discarded_count == 1

    [saved_deal] = result.matched_deals
    assert saved_deal.guid == "ebay-v1|1001|0"
    assert saved_deal.price == Decimal.new("750.00")

    # Verify SQLite persistence
    assert Repo.aggregate(Deal, :count) == 1

    # Verify user match record
    user_matches = Alerts.list_user_matches(user.id)
    assert length(user_matches) == 1
    [match] = user_matches
    assert match.deal_id == saved_deal.id
    assert match.alert_rule_id == rule.id
  end

  test "returns empty when no active rules exist" do
    item = %{
      guid: "ebay-v1|2001|0",
      title: "Any Item",
      url: "https://www.ebay.de/itm/2001",
      price: Decimal.new("10.00"),
      clean_text: "Any Item"
    }

    assert {:ok, result} = Matcher.evaluate_and_persist([item], rules: [])
    assert result.matched_deals == []
    assert result.discarded_count == 1
    assert Repo.aggregate(Deal, :count) == 0
  end
end
