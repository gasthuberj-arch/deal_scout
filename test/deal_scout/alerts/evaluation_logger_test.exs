defmodule DealScout.Alerts.EvaluationLoggerTest do
  use DealScout.DataCase, async: false

  alias DealScout.Alerts
  alias DealScout.Alerts.{AlertRule, ComputeGuard}
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()

    feed =
      Repo.insert!(%Feed{
        name: "Log Test Feed",
        slug: "log-test-feed-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "LogShop",
        slug: "logshop-#{System.unique_integer([:positive])}",
        trust_level: "verified"
      })

    deal1 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "log-deal-1-#{System.unique_integer([:positive])}",
        title: "Gaming Laptop RTX 4080",
        url: "https://example.com/laptop",
        price: Decimal.new("1499.00"),
        published_at: ~U[2026-10-22 10:00:00Z]
      })

    deal2 =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "log-deal-2-#{System.unique_integer([:positive])}",
        title: "Ultra Gaming Monitor 4K",
        url: "https://example.com/monitor",
        price: Decimal.new("499.00"),
        published_at: ~U[2026-10-22 10:15:00Z]
      })

    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Gaming Gear Rule",
        keywords: "Gaming",
        is_active: true
      })

    log_file =
      Path.join(System.tmp_dir!(), "alert_eval_test_#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(log_file) end)

    %{
      user: user,
      feed: feed,
      merchant: merchant,
      deals: [deal1, deal2],
      rule: rule,
      log_file: log_file
    }
  end

  describe "ComputeGuard slow evaluation logging" do
    test "writes NDJSON entry when duration is at or above threshold", %{
      rule: rule,
      deals: deals,
      log_file: log_file
    } do
      # 6000 us >= 5000 us default threshold
      assert {:ok, ^deals} =
               ComputeGuard.run(
                 rule,
                 deals,
                 [duration_us: 6_000, log_path: log_file, threshold_us: 5_000],
                 fn -> deals end
               )

      assert File.exists?(log_file)
      content = File.read!(log_file)
      [line] = String.split(content, "\n", trim: true)

      assert {:ok, entry} = Jason.decode(line)
      assert entry["rule_id"] == rule.id
      assert entry["rule_name"] == "Gaming Gear Rule"
      assert entry["duration_us"] == 6_000
      assert entry["duration_ms"] == 6.0
      assert entry["normalized_duration_us"] == 3_000
      assert entry["normalized_duration_ms"] == 3.0
      assert entry["deal_count"] == 2
      assert entry["matches_count"] == 2

      # Batch window verification
      assert entry["batch_window"]["earliest_published_at"] =~ "2026-10-22T10:00:00"
      assert entry["batch_window"]["latest_published_at"] =~ "2026-10-22T10:15:00"
      assert entry["batch_window"]["window_seconds"] == 900

      # Deal references verification
      deal_refs = entry["deal_references"]
      assert length(deal_refs) == 2
      assert Enum.any?(deal_refs, &(&1["title"] == "Gaming Laptop RTX 4080"))
      assert Enum.any?(deal_refs, &(&1["title"] == "Ultra Gaming Monitor 4K"))
    end

    test "ignores runs below the threshold", %{rule: rule, deals: deals, log_file: log_file} do
      assert {:ok, [_]} =
               ComputeGuard.run(
                 rule,
                 deals,
                 [duration_us: 2_000, log_path: log_file, threshold_us: 5_000],
                 fn -> [hd(deals)] end
               )

      refute File.exists?(log_file)
    end
  end

  describe "process_new_deals/2 integration" do
    test "does not auto-pause when auto_pause is disabled by default, and logs slow runs", %{
      rule: rule,
      deals: deals,
      log_file: log_file
    } do
      # budget_us: 0 so evaluation exceeds budget
      # threshold_us: 0 so it records to log file
      Alerts.process_new_deals(deals, budget_us: 0, log_path: log_file, threshold_us: 0)

      # Rule stays active
      reloaded = Repo.get!(AlertRule, rule.id)
      assert reloaded.is_active == true
      assert is_nil(reloaded.pause_reason)
      assert is_integer(reloaded.last_eval_duration_us)

      # Log file recorded
      assert File.exists?(log_file)
      content = File.read!(log_file)
      assert content =~ "Gaming Gear Rule"
      assert content =~ "Gaming Laptop RTX 4080"
    end
  end
end
