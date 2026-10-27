defmodule DealScoutWeb.DealImageControllerTest do
  use DealScoutWeb.ConnCase

  alias DealScout.Repo
  alias DealScout.Feeds.Feed
  alias DealScout.Deals
  alias DealScout.Deals.ImageCache

  setup do
    feed =
      Repo.insert!(%Feed{name: "Test Feed", slug: "test-feed", url: "https://example.com/feed"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-img-test-1",
        title: "Test Headphones",
        url: "https://example.com/deal",
        image_url: "https://example.com/headphones.jpg",
        published_at: now
      })

    %{feed: feed, deal: deal, now: now}
  end

  test "returns 404 for non-existent deal", %{conn: conn} do
    conn = get(conn, ~p"/deals/999999/image")
    assert response(conn, 404)
  end

  test "returns cached image from ImageCache if present", %{conn: conn, deal: deal} do
    sample_png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    ImageCache.put(deal.id, "image/png", sample_png)

    conn = get(conn, ~p"/deals/#{deal.id}/image")
    assert response(conn, 200) == sample_png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") |> hd() =~ "public"
  end

  test "returns 404 when deal has no image_url", %{conn: conn, feed: feed, now: now} do
    {:ok, deal_no_img} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-no-img",
        title: "No Image Deal",
        url: "https://example.com/deal-no-img",
        image_url: nil,
        published_at: now
      })

    conn = get(conn, ~p"/deals/#{deal_no_img.id}/image")
    assert response(conn, 404)
  end
end
