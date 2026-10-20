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

  test "supports exact quoted phrase matching", %{deal: deal} do
    # Deal title is "GIGABYTE GeForce RTX 4080 SUPER Gaming OC 16GB"
    rule_exact = %AlertRule{keywords: "\"RTX 4080 SUPER\"", is_active: true}
    assert Matcher.matches?(deal, rule_exact)

    rule_wrong_order = %AlertRule{keywords: "\"SUPER 4080 RTX\"", is_active: true}
    refute Matcher.matches?(deal, rule_wrong_order)
  end

  test "filters by merchant trust level (verified_only)", %{deal: deal} do
    rule = %AlertRule{keywords: "RTX 4080", merchant_filter: "verified_only", is_active: true}
    # deal merchant trust_level is "verified"
    assert Matcher.matches?(deal, rule)

    unverified_deal = %{
      deal
      | merchant: %Merchant{name: "RandomShop", slug: "random", trust_level: "unverified"}
    }

    refute Matcher.matches?(unverified_deal, rule)
  end

  test "filters by origin country (de_only and eu_only)", %{deal: deal} do
    rule_de = %AlertRule{keywords: "RTX 4080", country_filter: "de_only", is_active: true}
    # Domestic Mindfactory deal
    assert Matcher.matches?(deal, rule_de)

    # Cross-border Spanish deal
    foreign_deal = %{
      deal
      | url: "https://amazon.es/dp/B0123456",
        title: "GIGABYTE RTX 4080 [Amazon.es]"
    }

    refute Matcher.matches?(foreign_deal, rule_de)

    rule_eu = %AlertRule{keywords: "RTX 4080", country_filter: "eu_only", is_active: true}
    assert Matcher.matches?(foreign_deal, rule_eu)

    us_deal = %{deal | url: "https://amazon.com/dp/B0123456", title: "GIGABYTE RTX 4080 US"}
    refute Matcher.matches?(us_deal, rule_eu)
  end

  test "excludes foreign keyboard layouts when exclude_foreign_keyboards is true" do
    laptop_deal = %Deal{
      feed_id: 1,
      title: "ASUS ROG Zephyrus G14 Gaming Laptop",
      clean_text: "Top Notebook mit AZERTY Layout aus Frankreich.",
      url: "https://amazon.fr/dp/B0123456",
      price: Decimal.new("1299.00")
    }

    rule_exclude = %AlertRule{
      keywords: "Zephyrus",
      exclude_foreign_keyboards: true,
      is_active: true
    }

    refute Matcher.matches?(laptop_deal, rule_exclude)

    rule_allow = %AlertRule{
      keywords: "Zephyrus",
      exclude_foreign_keyboards: false,
      is_active: true
    }

    assert Matcher.matches?(laptop_deal, rule_allow)
  end

  test "supports explicit OR and AND boolean keywords", %{deal: deal} do
    # deal is "GIGABYTE GeForce RTX 4080 SUPER Gaming OC 16GB"
    rule_or = %AlertRule{keywords: "RTX 4080 OR RTX 4090", is_active: true}
    assert Matcher.matches?(deal, rule_or)

    rule_and_pass = %AlertRule{keywords: "RTX 4080 AND 16GB", is_active: true}
    assert Matcher.matches?(deal, rule_and_pass)

    rule_and_fail = %AlertRule{keywords: "RTX 4080 AND 24GB", is_active: true}
    refute Matcher.matches?(deal, rule_and_fail)
  end

  test "supports parentheses () for grouping expressions", %{deal: deal} do
    rule_group = %AlertRule{keywords: "(RTX 4080 OR RX 7900) AND 16GB", is_active: true}
    assert Matcher.matches?(deal, rule_group)

    rule_group_comma = %AlertRule{keywords: "(RTX 4080, RX 7900) 16GB", is_active: true}
    assert Matcher.matches?(deal, rule_group_comma)

    rule_group_fail = %AlertRule{keywords: "(RTX 4070 OR RX 7900) AND 16GB", is_active: true}
    refute Matcher.matches?(deal, rule_group_fail)
  end

  test "supports combining exact quotes and parentheses", %{deal: deal} do
    rule_quotes_group = %AlertRule{
      keywords: "(\"RTX 4080 SUPER\" OR \"RX 7900 XTX\") 16GB",
      is_active: true
    }

    assert Matcher.matches?(deal, rule_quotes_group)

    rule_wrong_quotes = %AlertRule{
      keywords: "(\"SUPER 4080 RTX\" OR \"RX 7900 XTX\") 16GB",
      is_active: true
    }

    refute Matcher.matches?(deal, rule_wrong_quotes)
  end

  test "handles unbalanced parentheses, trailing commas, and German quotes gracefully", %{
    deal: deal
  } do
    assert Matcher.matches?(deal, %AlertRule{keywords: "(RTX 4080", is_active: true})
    assert Matcher.matches?(deal, %AlertRule{keywords: ") RTX 4080", is_active: true})
    assert Matcher.matches?(deal, %AlertRule{keywords: "RTX 4080,", is_active: true})
    assert Matcher.matches?(deal, %AlertRule{keywords: "„RTX 4080 SUPER“", is_active: true})
  end
end
