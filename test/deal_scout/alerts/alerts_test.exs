defmodule DealScout.Alerts.AlertsTest do
  use DealScout.DataCase, async: false

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()

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

    %{user: user, feed: feed, merchant: merchant}
  end

  test "process_new_deals/1 matches deals and records UserMatch", %{
    user: user,
    feed: feed,
    merchant: merchant
  } do
    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "MacBook Hunter",
        keywords: "MacBook Air",
        is_active: true
      })

    deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-macbook-#{System.unique_integer([:positive])}",
        title: "Apple MacBook Air M3 16GB",
        url: "https://example.com/macbook",
        price: Decimal.new("1099.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Alerts.process_new_deals([deal])

    matches = Alerts.list_user_matches(user.id)
    assert length(matches) == 1
    assert hd(matches).deal_id == deal.id
    assert hd(matches).alert_rule_id == rule.id
  end

  test "suppresses duplicate match if canonical duplicate deal was alerted within 24 hours", %{
    user: user,
    feed: feed,
    merchant: merchant
  } do
    _rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "MacBook Hunter",
        keywords: "MacBook Air",
        is_active: true
      })

    # Deal 1 is the canonical deal
    canonical_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "canonical-macbook-#{System.unique_integer([:positive])}",
        title: "Apple MacBook Air M3 16GB (Canonical)",
        url: "https://example.com/macbook-1",
        price: Decimal.new("1099.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Alerts.process_new_deals([canonical_deal])
    assert length(Alerts.list_user_matches(user.id)) == 1

    # Deal 2 is a duplicate from another portal pointing to canonical_deal.id
    duplicate_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        canonical_deal_id: canonical_deal.id,
        guid: "duplicate-macbook-#{System.unique_integer([:positive])}",
        title: "Apple MacBook Air M3 16GB (Duplicate)",
        url: "https://example.com/macbook-2",
        price: Decimal.new("1099.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Processing duplicate should be suppressed by duplicate_canonical_match?
    Alerts.process_new_deals([duplicate_deal])
    assert length(Alerts.list_user_matches(user.id)) == 1
  end

  test "respects rule cooldown period to prevent notification storms", %{
    user: user,
    feed: feed,
    merchant: merchant
  } do
    # Last notified 5 minutes ago, with 30 minutes cooldown
    five_min_ago = DateTime.add(DateTime.utc_now(), -300, :second) |> DateTime.truncate(:second)

    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Cooled Rule",
        keywords: "iPad",
        cooldown_minutes: 30,
        last_notified_at: five_min_ago,
        is_active: true
      })

    deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "ipad-deal-#{System.unique_integer([:positive])}",
        title: "Apple iPad 10th Gen",
        url: "https://example.com/ipad",
        price: Decimal.new("349.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Should still record match in inbox, but rule last_notified_at remains five_min_ago (no new notification burst)
    Alerts.process_new_deals([deal])
    assert length(Alerts.list_user_matches(user.id)) == 1

    reloaded_rule = Repo.get!(AlertRule, rule.id)
    assert DateTime.diff(reloaded_rule.last_notified_at, five_min_ago, :second) == 0
  end

  test "collapses multiple matching deals into a single notification batch during ingestion", %{
    user: user,
    feed: feed,
    merchant: merchant
  } do
    _rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "PlayStation 5 Hunter",
        keywords: "PlayStation 5",
        delivery_mode: "instant",
        notify_push: true,
        notify_email: false,
        is_active: true
      })

    deal1 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-ps5-1-#{System.unique_integer([:positive])}",
        title: "Sony PlayStation 5 Slim Digital",
        url: "https://example.com/ps5-1",
        price: Decimal.new("399.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    deal2 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-ps5-2-#{System.unique_integer([:positive])}",
        title: "Sony PlayStation 5 Disc Edition Bundle",
        url: "https://example.com/ps5-2",
        price: Decimal.new("499.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Alerts.process_new_deals([deal1, deal2])

    matches = Alerts.list_user_matches(user.id)
    assert length(matches) == 2
    matched_deal_ids = Enum.map(matches, & &1.deal_id)
    assert deal1.id in matched_deal_ids
    assert deal2.id in matched_deal_ids
  end

  test "filters deals using negative keywords, price ceilings, and merchant trust levels", %{
    user: user,
    feed: feed,
    merchant: verified_merchant
  } do
    unverified_merchant =
      Repo.insert!(%Merchant{
        name: "Dubious Shop",
        slug: "dubious-shop-#{System.unique_integer([:positive])}",
        trust_level: "unverified"
      })

    _rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Clean GPU Deals",
        keywords: "RTX 4070",
        negative_keywords: "defekt, zubehör",
        max_price: Decimal.new("600.00"),
        merchant_filter: "verified_only",
        is_active: true
      })

    # Valid deal: matches keyword, within price, no negative keyword, verified merchant
    valid_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: verified_merchant.id,
        guid: "deal-valid-#{System.unique_integer([:positive])}",
        title: "Asus RTX 4070 Super 12GB",
        url: "https://example.com/rtx-valid",
        price: Decimal.new("589.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Rejected 1: contains negative keyword "defekt"
    defekt_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: verified_merchant.id,
        guid: "deal-defekt-#{System.unique_integer([:positive])}",
        title: "Asus RTX 4070 Super (defekt, Bastler)",
        url: "https://example.com/rtx-defekt",
        price: Decimal.new("199.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Rejected 2: price exceeds 600.00
    expensive_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: verified_merchant.id,
        guid: "deal-expensive-#{System.unique_integer([:positive])}",
        title: "MSI RTX 4070 Ti Super",
        url: "https://example.com/rtx-expensive",
        price: Decimal.new("799.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Rejected 3: unverified merchant
    unverified_deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: unverified_merchant.id,
        guid: "deal-unverified-#{System.unique_integer([:positive])}",
        title: "Gigabyte RTX 4070 Super",
        url: "https://example.com/rtx-unverified",
        price: Decimal.new("549.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Alerts.process_new_deals([valid_deal, defekt_deal, expensive_deal, unverified_deal])

    matches = Alerts.list_user_matches(user.id)
    assert length(matches) == 1
    assert hd(matches).deal_id == valid_deal.id
  end

  test "filters deals based on dropshipper status and keyboard layouts", %{
    user: user,
    feed: feed,
    merchant: merchant
  } do
    dropshipper =
      Repo.insert!(%Merchant{
        name: "AliExpress Store",
        slug: "aliexpress-store-#{System.unique_integer([:positive])}",
        trust_level: "dropshipper"
      })

    _rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Laptop Hunter",
        keywords: "ThinkPad",
        exclude_dropshippers: true,
        exclude_foreign_keyboards: true,
        is_active: true
      })

    german_laptop =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-german-#{System.unique_integer([:positive])}",
        title: "Lenovo ThinkPad T14 Gen 4 QWERTZ DE",
        url: "https://example.com/thinkpad-de",
        price: Decimal.new("899.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    dropship_laptop =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: dropshipper.id,
        guid: "deal-dropship-#{System.unique_integer([:positive])}",
        title: "Lenovo ThinkPad T14 Dropship",
        url: "https://aliexpress.com/item/123",
        price: Decimal.new("699.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    foreign_keyboard_laptop =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-foreign-kb-#{System.unique_integer([:positive])}",
        title: "Lenovo ThinkPad T14 (Clavier AZERTY France)",
        url: "https://amazon.fr/dp/123",
        price: Decimal.new("799.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Alerts.process_new_deals([german_laptop, dropship_laptop, foreign_keyboard_laptop])

    matches = Alerts.list_user_matches(user.id)
    assert length(matches) == 1
    assert hd(matches).deal_id == german_laptop.id
  end
end
