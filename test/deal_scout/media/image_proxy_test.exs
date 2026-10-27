defmodule DealScout.Media.ImageProxyTest do
  use DealScout.DataCase, async: false

  alias DealScout.Media.ImageProxy
  alias DealScout.Deals
  alias DealScout.Feeds.Feed

  setup do
    feed =
      Repo.insert!(%Feed{
        name: "Proxy Test Feed",
        slug: "proxy-test-feed",
        url: "https://example.com/rss"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "proxy-deal-1",
        title: "Wireless ANC Headphones",
        url: "https://example.com/deal",
        image_url: "https://example.com/deal.jpg",
        published_at: now
      })

    ImageProxy.clear()

    %{feed: feed, deal: deal}
  end

  test "fetch_image returns cached image if present in ETS", %{deal: deal} do
    sample_binary = <<1, 2, 3, 4, 5>>
    ImageProxy.put_cached_image(deal.id, "image/jpeg", sample_binary)

    assert {:ok, "image/jpeg", ^sample_binary} = ImageProxy.fetch_image(deal.id)
    assert {:ok, "image/jpeg", ^sample_binary} = ImageProxy.fetch_image("#{deal.id}")
  end

  test "fetch_image returns error :not_found for nonexistent deal" do
    assert {:error, :not_found} = ImageProxy.fetch_image(999_999_999)
  end

  test "fetch_image returns error :not_found when deal has no image_url", %{feed: feed} do
    {:ok, deal_no_img} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "no-img-deal",
        title: "Deal With No Image",
        url: "https://example.com/no-img",
        image_url: nil,
        published_at: DateTime.utc_now()
      })

    assert {:error, :not_found} = ImageProxy.fetch_image(deal_no_img.id)
  end

  test "invalidate removes entry from cache", %{deal: deal} do
    sample_binary = <<1, 2, 3>>
    ImageProxy.put_cached_image(deal.id, "image/png", sample_binary)

    assert {:ok, "image/png", ^sample_binary} = ImageProxy.fetch_image(deal.id)

    ImageProxy.invalidate(deal.id)

    # After invalidation, lookup on nonexistent remote URL fails or redirects
    assert {:redirect, "https://example.com/deal.jpg"} = ImageProxy.fetch_image(deal.id)
  end

  test "coalesces concurrent requests for the same un-cached deal", %{deal: deal} do
    # When multiple tasks call fetch_image concurrently for an un-cached deal whose remote URL fails,
    # all tasks should receive {:redirect, ...} without crashing or raising errors
    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          ImageProxy.fetch_image(deal.id)
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert length(results) == 5

    Enum.each(results, fn res ->
      assert {:redirect, "https://example.com/deal.jpg"} = res
    end)
  end
end
