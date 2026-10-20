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
end
