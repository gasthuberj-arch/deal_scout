defmodule DealScout.Alerts.ComputeGuardTest do
  use DealScout.DataCase, async: false

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.Notifications.Dispatcher
  alias DealScout.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()

    feed =
      Repo.insert!(%Feed{
        name: "Test Deals Feed",
        slug: "test-deals-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "CoolShop",
        slug: "coolshop-#{System.unique_integer([:positive])}",
        trust_level: "verified"
      })

    deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-guard-#{System.unique_integer([:positive])}",
        title: "Apple MacBook Pro M3 Max",
        url: "https://example.com/macbook",
        price: Decimal.new("1999.00"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{user: user, feed: feed, merchant: merchant, deal: deal}
  end

  describe "Telemetry Tracing & Compute Budget Guard" do
    test "emits :telemetry event [:deal_scout, :alerts, :rule_eval] on evaluation", %{
      user: user,
      deal: deal
    } do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "MacBook Alert",
          keywords: "MacBook",
          is_active: true
        })

      test_pid = self()
      handler_id = "test-rule-eval-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:deal_scout, :alerts, :rule_eval],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Alerts.process_new_deals([deal])

      assert_receive {:telemetry_event, [:deal_scout, :alerts, :rule_eval], measurements,
                      metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert measurements.deal_count == 1
      assert metadata.rule_id == rule.id
      assert metadata.user_id == user.id
      assert metadata.rule_name == "MacBook Alert"
    end

    test "auto-pauses rule when query evaluation exceeds compute budget", %{
      user: user,
      deal: deal
    } do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Pathological Query Rule",
          keywords: "MacBook, Apple, Laptop, Pro",
          is_active: true
        })

      # Subscribe to user topic to verify PubSub broadcast
      Phoenix.PubSub.subscribe(DealScout.PubSub, Dispatcher.user_topic(user.id))

      # Use budget_us: 0 so any evaluation triggers the circuit breaker
      Alerts.process_new_deals([deal], budget_us: 0)

      # 1. Verify PubSub notification received
      assert_receive {:rule_auto_paused, updated_rule, reason}
      assert updated_rule.id == rule.id
      assert updated_rule.is_active == false
      assert reason =~ "Auto-paused: Query evaluation took"
      assert reason =~ "compute budget"
      assert reason =~ "Simplify keywords or remove broad terms."

      # 2. Verify database record updated
      reloaded_rule = Repo.get!(AlertRule, rule.id)
      refute reloaded_rule.is_active
      assert reloaded_rule.pause_reason =~ "Auto-paused: Query evaluation took"
      assert is_integer(reloaded_rule.last_eval_duration_us)
      assert reloaded_rule.last_eval_duration_us >= 0

      # 3. Verify that matches were not recorded in inbox for the paused rule
      matches = Alerts.list_user_matches(user.id)
      assert matches == []
    end

    test "records last_eval_duration_us and keeps rule active when within budget", %{
      user: user,
      deal: deal
    } do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Fast Rule",
          keywords: "MacBook",
          is_active: true
        })

      Alerts.process_new_deals([deal], budget_us: 1_000_000)

      reloaded_rule = Repo.get!(AlertRule, rule.id)
      assert reloaded_rule.is_active
      assert is_nil(reloaded_rule.pause_reason)
      assert is_integer(reloaded_rule.last_eval_duration_us)
      assert reloaded_rule.last_eval_duration_us >= 0

      # Match was recorded
      matches = Alerts.list_user_matches(user.id)
      assert length(matches) == 1
    end
  end

  describe "Alert Rule Lifecycle: Auto-Pause, Resume, and Admin Listing" do
    test "auto_pause_rule/3 updates rule state", %{user: user} do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Heavy Rule",
          keywords: "GPU",
          is_active: true
        })

      reason = "Auto-paused: Query evaluation took 45.2ms (exceeded 30ms compute budget)."
      {:ok, updated} = Alerts.auto_pause_rule(rule, reason, 45_200)

      assert updated.is_active == false
      assert updated.pause_reason == reason
      assert updated.last_eval_duration_us == 45_200
    end

    test "resume_rule/1 clears pause_reason and sets is_active: true", %{user: user} do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Paused Rule",
          keywords: "RTX",
          is_active: false,
          pause_reason: "Auto-paused: took 38ms",
          last_eval_duration_us: 38_000
        })

      {:ok, resumed} = Alerts.resume_rule(rule)
      assert resumed.is_active == true
      assert is_nil(resumed.pause_reason)
      assert resumed.last_eval_duration_us == 38_000
    end

    test "pause_rule/2 manually pauses a rule", %{user: user} do
      rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Active Rule",
          keywords: "OLED",
          is_active: true
        })

      {:ok, paused} = Alerts.pause_rule(rule, "Manually paused by administrator")
      assert paused.is_active == false
      assert paused.pause_reason == "Manually paused by administrator"
    end

    test "list_auto_paused_rules/0 returns auto-paused rules with preloaded user", %{user: user} do
      _active_rule =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Active Rule",
          keywords: "Active",
          is_active: true
        })

      _normal_paused =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "User Paused",
          keywords: "User",
          is_active: false,
          pause_reason: nil
        })

      auto_paused =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Auto Paused Rule",
          keywords: "Broad",
          is_active: false,
          pause_reason: "Auto-paused: Query evaluation took 35ms",
          last_eval_duration_us: 35_000
        })

      results = Alerts.list_auto_paused_rules()
      assert length(results) == 1
      found = hd(results)
      assert found.id == auto_paused.id
      assert found.user.id == user.id
      assert found.pause_reason =~ "Auto-paused"
    end

    test "list_slowest_rules/1 returns slowest rules ordered by duration descending", %{
      user: user
    } do
      r1 =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Fast Rule",
          keywords: "Fast",
          is_active: true,
          last_eval_duration_us: 5_000
        })

      r2 =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Very Slow Rule",
          keywords: "Slow",
          is_active: true,
          last_eval_duration_us: 28_000
        })

      r3 =
        Repo.insert!(%AlertRule{
          user_id: user.id,
          name: "Medium Rule",
          keywords: "Med",
          is_active: true,
          last_eval_duration_us: 12_000
        })

      slowest = Alerts.list_slowest_rules(2)
      assert length(slowest) == 2
      assert Enum.at(slowest, 0).id == r2.id
      assert Enum.at(slowest, 1).id == r3.id
      assert Enum.at(slowest, 0).user.id == user.id

      all_slowest = Alerts.list_slowest_rules(10)
      assert length(all_slowest) == 3
      assert Enum.map(all_slowest, & &1.id) == [r2.id, r3.id, r1.id]
    end
  end
end
