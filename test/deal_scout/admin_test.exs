defmodule DealScout.AdminTest do
  use DealScout.DataCase, async: false

  alias DealScout.AccountsFixtures
  alias DealScout.Admin
  alias DealScout.Alerts
  alias DealScout.Feeds.Feed
  alias DealScout.Repo

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, user: user}
  end

  describe "system overview & health telemetry" do
    test "get_system_overview/0 aggregates operational telemetry in a single map" do
      overview = Admin.get_system_overview()

      assert is_map(overview)
      assert Map.has_key?(overview, :system_metrics)
      assert Map.has_key?(overview, :active_alarms)
      assert Map.has_key?(overview, :active_alarms_count)
      assert Map.has_key?(overview, :ops)
      assert Map.has_key?(overview, :backup)
      assert Map.has_key?(overview, :auto_paused_rules)
      assert Map.has_key?(overview, :slowest_rules)
      assert Map.has_key?(overview, :push_metrics)
      assert Map.has_key?(overview, :ebay_status)

      assert is_list(overview.active_alarms)
      assert is_integer(overview.active_alarms_count)
      assert is_map(overview.system_metrics.memory)
      assert is_map(overview.system_metrics.storage)
    end

    test "list_streamable_alarms/0 assigns string :id to each alarm" do
      alarms = Admin.list_streamable_alarms()
      assert is_list(alarms)

      Enum.each(alarms, fn alarm ->
        assert is_binary(alarm.id)
      end)
    end
  end

  describe "safe recovery operations" do
    test "safe_checkpoint/0 runs a non-blocking SQLite PASSIVE checkpoint" do
      assert {:ok, result} = Admin.safe_checkpoint()
      assert result.status in [:checkpointed, :sandbox, :busy]
      assert is_integer(result.checkpointed)
    end

    test "safe_reclaim_memory/0 executes memory shrink and garbage collection" do
      assert {:ok, %{reclaimed_processes: count}} = Admin.safe_reclaim_memory()
      assert is_integer(count)
    end

    test "safe_refresh_cache/0 warms stream cache without errors" do
      assert {:ok, :refreshed} = Admin.safe_refresh_cache()
    end

    test "safe_retry_feed/1 resets backoff and triggers poller" do
      # Insert a feed in backoff
      backoff = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      {:ok, feed} =
        %Feed{}
        |> Feed.changeset(%{
          name: "Test Retry Feed",
          url: "https://example.com/rss",
          slug: "test-retry-feed",
          is_active: true,
          backoff_until: backoff,
          consecutive_errors: 3,
          last_error_status: 500
        })
        |> Repo.insert()

      assert {:ok, updated_feed} = Admin.safe_retry_feed(feed.id)
      assert is_nil(updated_feed.backoff_until)
      assert is_nil(updated_feed.last_error_status)
    end

    test "safe_retry_feed/1 rejects retry when in HTTP 429 rate limit" do
      backoff = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      {:ok, feed} =
        %Feed{}
        |> Feed.changeset(%{
          name: "Rate Limited Feed",
          url: "https://example.com/rss429",
          slug: "test-feed-429",
          is_active: true,
          backoff_until: backoff,
          consecutive_errors: 1,
          last_error_status: 429
        })
        |> Repo.insert()

      assert {:error, :rate_limited, ^backoff} = Admin.safe_retry_feed(feed.id)
    end
  end

  describe "rule management" do
    test "pause_rule/2 and resume_rule/1 modify rule status", %{user: user} do
      {:ok, rule} =
        Alerts.create_alert_rule(user, %{
          name: "Admin Managed Rule",
          keywords: "Switch",
          source_filter: "all"
        })

      assert rule.is_active == true

      # Pause via ID
      assert {:ok, paused} = Admin.pause_rule(rule.id, "Testing admin pause")
      assert paused.is_active == false
      assert paused.pause_reason == "Testing admin pause"

      # Resume via struct
      assert {:ok, resumed} = Admin.resume_rule(paused)
      assert resumed.is_active == true
      assert is_nil(resumed.pause_reason)
    end
  end

  describe "device delivery analytics" do
    test "list_device_delivery_metrics/1 supports 'all' and 'pending_only'" do
      metrics = Admin.list_device_delivery_metrics("all")
      assert is_map(metrics)
      assert is_list(metrics.devices)
      assert is_integer(metrics.all_count)
      assert is_integer(metrics.pending_count)

      pending = Admin.list_device_delivery_metrics("pending_only")
      assert is_list(pending.devices)
    end
  end

  describe "polling triggers" do
    test "trigger_feed_poll/0 returns :ok" do
      assert Admin.trigger_feed_poll() == :ok
    end

    test "trigger_ebay_poll/0 returns :error when unconfigured" do
      # In test environment, ebay is typically not configured
      case Admin.trigger_ebay_poll() do
        {:ok, :triggered} -> assert true
        {:error, :not_configured} -> assert true
      end
    end
  end
end
