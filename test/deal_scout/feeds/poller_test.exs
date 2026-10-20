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
    assert :ok = Poller.poll_feed(feed)

    TestAdapter.stub_url(feed.url, {:error, :nxdomain})
    assert :ok = Poller.poll_feed(feed)

    TestAdapter.reset()
  end

  test "poll_all_feeds/0 polls all active feeds synchronously" do
    assert :ok = Poller.poll_all_feeds()
  end
end
