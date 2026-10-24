defmodule DealScout.Feeds.PollerTest do
  use DealScout.DataCase, async: false

  alias DealScout.Feeds
  alias DealScout.Feeds.Poller
  alias DealScout.Feeds.Feed
  alias DealScout.Feeds.Fetcher.TestAdapter
  alias DealScout.Repo
  alias DealScout.Deals.Deal

  setup do
    TestAdapter.reset()

    {:ok, feed1} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Test Feed 1",
        slug: "test-feed-1",
        url: "https://example.com/feed1.xml",
        is_active: true
      })
      |> Repo.insert()

    {:ok, feed2} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Test Feed 2",
        slug: "test-feed-2",
        url: "https://example.com/feed2.xml",
        is_active: true
      })
      |> Repo.insert()

    on_exit(fn ->
      TestAdapter.reset()
    end)

    %{feed1: feed1, feed2: feed2}
  end

  test "list_due_feeds/1 respects individual intervals and backoff" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, feed_fast} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Fast Feed",
        slug: "fast-feed",
        url: "https://example.com/fast.xml",
        poll_interval_seconds: 60,
        last_fetched_at: DateTime.add(now, -70, :second)
      })
      |> Repo.insert()

    {:ok, _feed_slow} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Slow Feed",
        slug: "slow-feed",
        url: "https://example.com/slow.xml",
        poll_interval_seconds: 600,
        last_fetched_at: DateTime.add(now, -100, :second)
      })
      |> Repo.insert()

    {:ok, _feed_backed_off} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Backed Off Feed",
        slug: "backed-off-feed",
        url: "https://example.com/blocked.xml",
        poll_interval_seconds: 60,
        last_fetched_at: DateTime.add(now, -100, :second),
        backoff_until: DateTime.add(now, 300, :second)
      })
      |> Repo.insert()

    due = Feeds.list_due_feeds(now)
    due_ids = Enum.map(due, & &1.id)

    # Fast Feed (due since 70s > 60s) and feeds with nil last_fetched_at are due
    assert feed_fast.id in due_ids
    # Slow Feed is NOT due (100s < 600s)
    refute Enum.any?(due, &(&1.slug == "slow-feed"))
    # Backed Off Feed is NOT due (backoff_until in future)
    refute Enum.any?(due, &(&1.slug == "backed-off-feed"))
  end

  test "starts with staggered interval and processes poll_now without crashing" do
    pid = Process.whereis(Poller)

    if pid do
      Process.unlink(pid)
      GenServer.stop(pid)
    end

    poller =
      start_supervised!({Poller, [interval_ms: 500, initial_delay_ms: 50, min_stagger_ms: 100]})

    Poller.poll_now()

    _ = :sys.get_state(poller)
    state = :sys.get_state(poller)

    assert state.mode == :fast or state.mode == :normal
    assert is_list(state.queue)

    stop_supervised!(Poller)

    if Process.whereis(DealScout.Feeds.TaskSupervisor) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(DealScout.Feeds.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end
    end
  end

  test "poll_feed/1 ingests deals and updates feed metadata on 200 OK", %{feed1: feed} do
    assert {:ok, _} = Poller.poll_feed(feed)

    updated_feed = Feeds.get_feed(feed.id)
    assert updated_feed.last_fetched_at != nil
    assert updated_feed.etag == "test-etag"

    deal = Repo.get_by(Deal, guid: "test-feed-guid-switch-1")
    assert deal != nil
    assert deal.title =~ "Nintendo Switch OLED"
  end

  test "poll_feed/1 updates last_fetched_at on 304 Not Modified", %{feed1: feed} do
    # Configure feed with matching etag so TestAdapter returns 304
    {:ok, feed} = Feeds.update_feed(feed, %{etag: "test-etag"})

    initial_deal_count = Repo.aggregate(Deal, :count, :id)
    assert {:ok, _} = Poller.poll_feed(feed)

    updated_feed = Feeds.get_feed(feed.id)
    assert updated_feed.last_fetched_at != nil
    # No new deals inserted on 304
    assert Repo.aggregate(Deal, :count, :id) == initial_deal_count
  end

  test "poll_feed/1 handles fetcher error status and network failure gracefully", %{feed1: feed} do
    TestAdapter.stub_url(feed.url, {:ok, %{status: 500, body: "Server Error", headers: []}})
    assert {:error, %{status: 500}} = Poller.poll_feed(feed)

    updated_feed = Feeds.get_feed(feed.id)
    assert updated_feed.consecutive_errors == 1
    assert updated_feed.last_error_status == 500

    TestAdapter.stub_url(feed.url, {:error, :nxdomain})
    assert {:error, :nxdomain} = Poller.poll_feed(updated_feed)

    updated_feed_2 = Feeds.get_feed(feed.id)
    assert updated_feed_2.consecutive_errors == 2

    TestAdapter.reset()
  end

  test "poll_feed/1 handles 429 and 403 with exponential backoff and retry-after", %{feed1: feed} do
    TestAdapter.stub_url(
      feed.url,
      {:ok, %{status: 429, body: "Rate limited", headers: [{"retry-after", "60"}]}}
    )

    assert {:error, %{status: 429}} = Poller.poll_feed(feed)

    updated_feed = Feeds.get_feed(feed.id)
    assert updated_feed.last_error_status == 429
    assert updated_feed.consecutive_errors == 1
    assert updated_feed.backoff_until != nil

    # Verify backoff_until is roughly ~60 seconds in the future
    diff = DateTime.diff(updated_feed.backoff_until, DateTime.utc_now(), :second)
    assert diff >= 55 and diff <= 65

    # 403 backoff without retry-after
    TestAdapter.stub_url(feed.url, {:ok, %{status: 403, body: "Forbidden", headers: []}})
    assert {:error, %{status: 403}} = Poller.poll_feed(updated_feed)

    updated_feed_403 = Feeds.get_feed(feed.id)
    assert updated_feed_403.last_error_status == 403
    assert updated_feed_403.consecutive_errors == 2
    diff_403 = DateTime.diff(updated_feed_403.backoff_until, DateTime.utc_now(), :second)
    assert diff_403 >= 1700

    TestAdapter.reset()
  end

  test "poll_feed/1 does not overwrite etag when 200 OK body is not a valid feed XML", %{
    feed1: feed
  } do
    {:ok, feed} = Feeds.update_feed(feed, %{etag: "previous-good-etag"})

    TestAdapter.stub_url(
      feed.url,
      {:ok, %{status: 200, body: "<html>502 Bad Gateway</html>", headers: [{"etag", "bad-etag"}]}}
    )

    assert {:error, :invalid_feed_xml} = Poller.poll_feed(feed)

    reloaded = Feeds.get_feed(feed.id)
    assert reloaded.etag == "previous-good-etag"

    TestAdapter.reset()
  end

  test "poll_all_feeds/0 polls all active feeds synchronously" do
    assert :ok = Poller.poll_all_feeds()
  end
end
