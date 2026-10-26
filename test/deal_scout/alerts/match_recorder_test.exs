defmodule DealScout.Alerts.MatchRecorderTest do
  use DealScout.DataCase

  alias DealScout.Alerts.{AlertRule, MatchRecorder, UserMatch}
  alias DealScout.Deals.Deal
  alias DealScout.Feeds.Feed
  alias DealScout.Accounts.User
  alias DealScout.Repo

  setup do
    user =
      Repo.insert!(%User{
        email: "match_recorder_#{System.unique_integer([:positive])}@example.com",
        hashed_password: "dummy"
      })

    feed =
      Repo.insert!(%Feed{
        name: "Test Feed",
        slug: "test-feed-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss",
        is_active: true
      })

    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Laptop Deals",
        keywords: "Laptop",
        is_active: true,
        delivery_mode: "instant"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    deal1 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        guid: "deal-rec-1",
        title: "ThinkPad Laptop",
        url: "https://example.com/deal1",
        price: Decimal.new("800.00"),
        published_at: now
      })

    deal2 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        guid: "deal-rec-2",
        title: "ThinkPad Laptop Duplicate",
        url: "https://example.com/deal2",
        price: Decimal.new("810.00"),
        canonical_deal_id: deal1.id,
        published_at: now
      })

    %{user: user, feed: feed, rule: rule, deal1: deal1, deal2: deal2}
  end

  test "records matches and skips canonical duplicates within batch in single pass", %{
    user: user,
    rule: rule,
    deal1: deal1,
    deal2: deal2
  } do
    # Both deal1 and deal2 matched the rule, but deal2 has canonical_deal_id pointing to deal1
    matches_by_rule = %{rule => [deal1, deal2]}

    assert :ok = MatchRecorder.record_and_dispatch(matches_by_rule)

    matches = Repo.all(from m in UserMatch, where: m.user_id == ^user.id)
    assert length(matches) == 1
    assert hd(matches).deal_id == deal1.id
  end

  test "skips canonical matches already recorded in past 24 hours", %{
    user: user,
    rule: rule,
    deal1: deal1,
    deal2: deal2
  } do
    # Record first match
    assert :ok = MatchRecorder.record_and_dispatch(%{rule => [deal1]})

    # Second polling cycle brings deal2 (duplicate of deal1)
    assert :ok = MatchRecorder.record_and_dispatch(%{rule => [deal2]})

    # Still only 1 recorded match
    matches = Repo.all(from m in UserMatch, where: m.user_id == ^user.id)
    assert length(matches) == 1
    assert hd(matches).deal_id == deal1.id
  end

  test "handles empty match map gracefully" do
    assert :ok = MatchRecorder.record_and_dispatch(%{})
  end
end
