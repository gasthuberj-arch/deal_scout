defmodule DealScout.Alerts.MatcherTest do
  use ExUnit.Case, async: true
  alias DealScout.Alerts.Matcher
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed

  setup do
    feed = %Feed{id: 1, slug: "mydealz", name: "MyDealz"}
    merchant = %Merchant{id: 1, name: "Mindfactory", slug: "mindfactory", trust_level: "verified"}

    deal = %Deal{
      feed_id: 1,
      feed: feed,
      merchant_id: 1,
      merchant: merchant,
      raw_merchant: "Mindfactory",
      title: "GIGABYTE GeForce RTX 4080 SUPER Gaming OC 16GB",
      clean_text: "Top Grafikkarte mit Triple-Fan Kühler für flüsterleisen Betrieb.",
      price: Decimal.new("989.00"),
      temperature: 150
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

  test "filters by source feed", %{deal: deal} do
    matching_feed_rule = %AlertRule{
      keywords: "RTX 4080",
      source_filter: "mydealz",
      is_active: true
    }

    assert Matcher.matches?(deal, matching_feed_rule)

    other_feed_rule = %AlertRule{
      keywords: "RTX 4080",
      source_filter: "dealdoktor",
      is_active: true
    }

    refute Matcher.matches?(deal, other_feed_rule)
  end

  test "enforces strict min_temperature matching", %{deal: deal} do
    # deal temperature is 150
    rule_ok = %AlertRule{keywords: "RTX 4080", min_temperature: 100, is_active: true}
    assert Matcher.matches?(deal, rule_ok)

    rule_too_hot = %AlertRule{keywords: "RTX 4080", min_temperature: 200, is_active: true}
    refute Matcher.matches?(deal, rule_too_hot)

    # deal without temperature rating
    deal_no_temp = %{deal | temperature: nil}
    refute Matcher.matches?(deal_no_temp, rule_ok)
  end

  test "excludes dropshippers when exclude_dropshippers is true", %{deal: deal} do
    dropship_merchant = %Merchant{name: "Temu", slug: "temu", trust_level: "dropshipper"}
    temu_deal = %{deal | merchant: dropship_merchant, raw_merchant: "Temu"}

    rule_exclude = %AlertRule{keywords: "RTX 4080", exclude_dropshippers: true, is_active: true}
    refute Matcher.matches?(temu_deal, rule_exclude)

    rule_allow = %AlertRule{keywords: "RTX 4080", exclude_dropshippers: false, is_active: true}
    assert Matcher.matches?(temu_deal, rule_allow)
  end
end
