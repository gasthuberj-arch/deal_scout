defmodule DealScout.Alerts.MatcherTest do
  use ExUnit.Case, async: true
  alias DealScout.Alerts.Matcher
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.Deal
  alias DealScout.Feeds.Feed

  setup do
    feed = %Feed{id: 1, slug: "mydealz", name: "MyDealz"}

    deal = %Deal{
      feed_id: 1,
      feed: feed,
      title: "GIGABYTE GeForce RTX 4080 SUPER Gaming OC 16GB",
      clean_text: "Top Grafikkarte mit Triple-Fan Kühler für flüsterleisen Betrieb.",
      price: Decimal.new("989.00"),
      merchant: "Mindfactory"
    }

    %{deal: deal}
  end

  test "matches exact or case-insensitive keyword tokens", %{deal: deal} do
    rule = %AlertRule{keywords: "rtx 4080", is_active: true}
    assert Matcher.matches?(deal, rule)

    rule2 = %AlertRule{keywords: "RTX 4090", is_active: true}
    refute Matcher.matches?(deal, rule2)
  end

  test "supports comma-separated OR keyword groups", %{deal: deal} do
    rule = %AlertRule{keywords: "RX 7900, RTX 4080", is_active: true}
    assert Matcher.matches?(deal, rule)
  end

  test "rejects when negative/exclusion keyword is present", %{deal: deal} do
    # Deal has "Kühler" in clean_text
    rule = %AlertRule{
      keywords: "RTX 4080",
      negative_keywords: "defekt, kühler",
      is_active: true
    }

    refute Matcher.matches?(deal, rule)
  end

  test "filters by max price", %{deal: deal} do
    # Deal price is 989.00
    affordable_rule = %AlertRule{
      keywords: "RTX 4080",
      max_price: Decimal.new("1000.00"),
      is_active: true
    }

    assert Matcher.matches?(deal, affordable_rule)

    too_expensive_rule = %AlertRule{
      keywords: "RTX 4080",
      max_price: Decimal.new("900.00"),
      is_active: true
    }

    refute Matcher.matches?(deal, too_expensive_rule)
  end

  test "filters by source portal", %{deal: deal} do
    mydealz_rule = %AlertRule{
      keywords: "RTX 4080",
      source_filter: "mydealz",
      is_active: true
    }

    assert Matcher.matches?(deal, mydealz_rule)

    dealdoktor_rule = %AlertRule{
      keywords: "RTX 4080",
      source_filter: "dealdoktor",
      is_active: true
    }

    refute Matcher.matches?(deal, dealdoktor_rule)
  end
end
