defmodule DealScout.Feeds.PollerTest do
  use DealScout.DataCase, async: false

  alias DealScout.Feeds.Poller
  alias DealScout.Feeds.Feed

  setup do
    # Create test feeds
    {:ok, feed1} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Test Feed 1",
        slug: "test-feed-1",
        url: "https://example.com/feed1.xml",
        is_active: true
      })
      |> DealScout.Repo.insert()

    {:ok, feed2} =
      %Feed{}
      |> Feed.changeset(%{
        name: "Test Feed 2",
        slug: "test-feed-2",
        url: "https://example.com/feed2.xml",
        is_active: true
      })
      |> DealScout.Repo.insert()

    {:ok, feed1: feed1, feed2: feed2}
  end

  test "starts with staggered interval and processes poll_now without crashing" do
    # Start a test poller with fast intervals
    # Stop global poller if running to avoid name collision in test
    pid = Process.whereis(Poller)

    if pid do
      Process.unlink(pid)
      GenServer.stop(pid)
    end

    {:ok, poller} =
      start_supervised({Poller, [interval_ms: 500, initial_delay_ms: 50, min_stagger_ms: 100]})

    assert Process.alive?(poller)

    # Trigger poll_now
    Poller.poll_now()

    # Allow worker task messages to process
    _ = :sys.get_state(poller)
    state = :sys.get_state(poller)

    assert state.mode == :fast or state.mode == :normal
    assert is_list(state.queue)
  end

  test "poll_all_feeds can be called directly without error" do
    # When Req gets non-existent URLs or offline URLs, it catches errors gracefully
    assert :ok = Poller.poll_all_feeds()
  end
end
