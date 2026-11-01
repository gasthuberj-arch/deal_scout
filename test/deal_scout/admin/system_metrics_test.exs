defmodule DealScout.Admin.SystemMetricsTest do
  use DealScout.DataCase, async: false

  alias DealScout.Admin.SystemMetrics
  alias DealScout.Feeds.Feed

  describe "get_metrics/0 and memory_metrics/0" do
    test "gathers memory, storage, and stream_cache operational metrics" do
      metrics = SystemMetrics.get_metrics()

      assert is_map(metrics.memory)
      assert is_float(metrics.memory.beam_total_mb)
      assert metrics.memory.container_limit_mb == 512.0
      assert is_float(metrics.memory.swap_used_mb)

      assert is_map(metrics.storage)
      assert is_binary(metrics.storage.db_path)
      assert is_integer(metrics.storage.db_bytes)
      assert is_integer(metrics.storage.wal_bytes)
      assert metrics.storage.retention_days == 365

      assert is_map(metrics.stream_cache)
      assert is_integer(metrics.stream_cache.size)
    end

    test "parses Linux /proc/meminfo syntax properly" do
      sample_meminfo = """
      MemTotal:        5783552 kB
      MemFree:          220160 kB
      MemAvailable:    1232896 kB
      SwapTotal:       4194300 kB
      SwapFree:        2046052 kB
      """

      parsed = SystemMetrics.parse_meminfo(sample_meminfo)

      assert parsed["MemTotal"] == 5_783_552
      assert parsed["MemAvailable"] == 1_232_896
      assert parsed["SwapTotal"] == 4_194_300
      assert parsed["SwapFree"] == 2_046_052
    end
  end

  describe "safe, non-destructive recoveries" do
    test "safe_wal_checkpoint/0 runs non-blocking checkpoint" do
      assert {:ok, result} = SystemMetrics.safe_wal_checkpoint()
      assert result.status in [:checkpointed, :busy, :sandbox]
      assert is_integer(result.busy)
      assert is_integer(result.log)
      assert is_integer(result.checkpointed)
    end

    test "safe_reclaim_memory/0 frees idle memory without error" do
      assert {:ok, result} = SystemMetrics.safe_reclaim_memory()
      assert is_integer(result.reclaimed_processes)
    end

    test "safe_refresh_stream_cache/0 warms cache in-place" do
      assert {:ok, :refreshed} = SystemMetrics.safe_refresh_stream_cache()
    end

    test "safe_retry_feed/1 enforces remote rate limits on HTTP 429 backoff" do
      future =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)

      feed_429 =
        Repo.insert!(%Feed{
          name: "Rate Limited Provider",
          slug: "rate-limited-#{System.unique_integer([:positive])}",
          url: "https://example.com/rss",
          is_active: true,
          backoff_until: future,
          last_error_status: 429
        })

      # Should refuse to force retry immediately to prevent remote domain block
      assert {:error, :rate_limited, ^future} = SystemMetrics.safe_retry_feed(feed_429)

      # For a feed with transient network timeout (e.g. 504)
      feed_504 =
        Repo.insert!(%Feed{
          name: "Gateway Timeout Provider",
          slug: "gw-timeout-#{System.unique_integer([:positive])}",
          url: "https://example.com/rss2",
          is_active: true,
          backoff_until: future,
          last_error_status: 504
        })

      assert {:ok, updated} = SystemMetrics.safe_retry_feed(feed_504)
      assert is_nil(updated.backoff_until)
      assert is_nil(updated.last_error_status)
    end
  end
end
