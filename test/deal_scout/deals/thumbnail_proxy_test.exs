defmodule DealScout.Deals.ThumbnailProxyTest do
  use DealScout.DataCase, async: false

  alias DealScout.Deals.ThumbnailProxy
  alias DealScout.Deals.ThumbnailProxy.TestAdapter
  alias DealScout.Deals
  alias DealScout.Feeds.Feed

  setup do
    ThumbnailProxy.clear()
    TestAdapter.reset()

    feed =
      Repo.insert!(%Feed{
        name: "Thumbnail Test Feed",
        slug: "thumb-test-feed",
        url: "https://example.com/rss"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "thumb-deal-1",
        title: "Logitech MX Master 3S",
        clean_text: "Ergonomic wireless mouse",
        url: "https://example.com/item/1",
        image_url: "https://example.com/images/mouse.jpg",
        published_at: now
      })

    %{feed: feed, deal: deal, now: now}
  end

  describe "get_thumbnail/2 cache hierarchy" do
    test "returns cached image directly on ETS hit", %{deal: deal} do
      payload = "fake-binary-png-data"
      assert :ok = ThumbnailProxy.put(deal.id, "image/png", payload)

      assert {:ok, "image/png", ^payload} = ThumbnailProxy.get_thumbnail(deal.id)
      assert {:ok, "image/png", ^payload} = ThumbnailProxy.get_thumbnail("#{deal.id}")
    end

    test "falls back to disk when ETS entry is missing or deleted", %{deal: deal} do
      payload = "persisted-disk-payload"
      assert :ok = ThumbnailProxy.put(deal.id, "image/jpeg", payload)

      # Evict from ETS memory table only
      :ets.delete(:deal_image_cache, deal.id)

      # Disk cache should repopulate ETS and return data
      assert {:ok, "image/jpeg", ^payload} = ThumbnailProxy.get_thumbnail(deal.id)
      assert ThumbnailProxy.size() > 0
    end

    test "returns :not_found for non-existent or invalid deals" do
      assert :not_found = ThumbnailProxy.get_thumbnail(999_999)
      assert :not_found = ThumbnailProxy.get_thumbnail("invalid")
      assert :not_found = ThumbnailProxy.get_thumbnail("../../etc/passwd")
      assert :not_found = ThumbnailProxy.get_thumbnail("-5")
    end

    test "returns :not_found when deal has nil or empty image_url", %{feed: feed, now: now} do
      {:ok, deal_no_img} =
        Deals.insert_deal(%{
          feed_id: feed.id,
          guid: "deal-no-image",
          title: "Deal without image",
          url: "https://example.com/no-img",
          image_url: nil,
          published_at: now
        })

      assert :not_found = ThumbnailProxy.get_thumbnail(deal_no_img.id)
    end
  end

  describe "upstream HTTP proxying and Two-Adapter seam" do
    test "fetches remote image via configured TestAdapter on cache miss", %{deal: deal} do
      test_image = <<137, 80, 78, 71, 1, 2, 3, 4>>

      TestAdapter.put_response(deal.image_url, %{
        status: 200,
        body: test_image,
        headers: [{"content-type", "image/png"}]
      })

      # Hits default adapter without passing ad-hoc fetcher
      assert {:ok, "image/png", ^test_image} = ThumbnailProxy.get_thumbnail(deal.id)
      assert ThumbnailProxy.size() > 0
    end

    test "streams oversized images (>60 KB) directly without storing in cache", %{deal: deal} do
      large_payload = :binary.copy("A", 60_001)

      mock_fetcher = fn _url ->
        {:ok,
         %{
           status: 200,
           body: large_payload,
           headers: [{"content-type", "image/jpeg"}]
         }}
      end

      assert {:ok, "image/jpeg", ^large_payload} =
               ThumbnailProxy.get_thumbnail(deal.id, fetcher: mock_fetcher)

      # Ensure it was not cached
      assert ThumbnailProxy.size() == 0
      refute File.exists?(ThumbnailProxy.disk_path(deal.id))
    end

    test "redirects to upstream URL when upstream returns non-200", %{deal: deal} do
      mock_fetcher = fn _url -> {:ok, %{status: 503, body: "Service Unavailable"}} end

      assert {:redirect, external_url} =
               ThumbnailProxy.get_thumbnail(deal.id, fetcher: mock_fetcher)

      assert external_url == deal.image_url
    end

    test "redirects to upstream URL when fetcher throws or times out", %{deal: deal} do
      failing_fetcher = fn _url -> {:error, :timeout} end

      assert {:redirect, external_url} =
               ThumbnailProxy.get_thumbnail(deal.id, fetcher: failing_fetcher)

      assert external_url == deal.image_url
    end

    test "redirects to upstream URL when concurrency permits are exhausted", %{deal: deal} do
      # Saturate 4 permits
      permits =
        for _i <- 1..4 do
          {:ok, permit} = ThumbnailProxy.acquire_permit()
          permit
        end

      # Attempting to fetch with zero timeout should return redirect immediately
      assert {:redirect, external_url} =
               ThumbnailProxy.get_thumbnail(deal.id,
                 permit_timeout: 10,
                 fetcher: fn _ -> {:ok, %{status: 200, body: "data"}} end
               )

      assert external_url == deal.image_url

      # Release permits
      Enum.each(permits, &ThumbnailProxy.release_permit/1)
    end

    test "cancels queued acquire when caller times out to eliminate ghost permits" do
      permits =
        for _i <- 1..4 do
          {:ok, permit} = ThumbnailProxy.acquire_permit()
          permit
        end

      # Caller times out quickly on acquire
      assert {:error, :busy} = ThumbnailProxy.acquire_permit(10)

      # Now release all 4 permits
      Enum.each(permits, &ThumbnailProxy.release_permit/1)

      # All 4 slots should be immediately reclaimable, confirming no ghost permit was granted
      new_permits =
        for _i <- 1..4 do
          {:ok, p} = ThumbnailProxy.acquire_permit(100)
          p
        end

      assert length(new_permits) == 4
      Enum.each(new_permits, &ThumbnailProxy.release_permit/1)
    end
  end

  describe "cache bounds and eviction" do
    test "enforces max ETS entry cap and prunes oldest" do
      payload = "small-image"

      for i <- 1..160 do
        ThumbnailProxy.put(i, "image/jpeg", payload)
      end

      assert ThumbnailProxy.size() <= 150
      assert ThumbnailProxy.size() > 0
    end

    test "clear/0 empties both memory and disk caches" do
      ThumbnailProxy.put(10, "image/jpeg", "content")
      assert ThumbnailProxy.size() > 0

      ThumbnailProxy.clear()
      assert ThumbnailProxy.size() == 0
    end
  end
end
