defmodule DealScout.Feeds.Ebay.ClientTest do
  use ExUnit.Case, async: false

  alias DealScout.Feeds.Ebay.Client

  @sample_item %{
    "itemId" => "v1|123456789012|0",
    "title" => "NVIDIA GeForce RTX 4080 Founders Edition 16GB",
    "price" => %{
      "value" => "799.50",
      "currency" => "EUR"
    },
    "itemWebUrl" => "https://www.ebay.de/itm/123456789012",
    "image" => %{
      "imageUrl" => "https://i.ebayimg.com/images/g/abc/s-l500.jpg"
    },
    "condition" => "Used",
    "itemCreationDate" => "2026-10-28T12:00:00.000Z",
    "seller" => %{
      "username" => "gpu_master",
      "feedbackPercentage" => "99.4",
      "feedbackScore" => 520
    },
    "shippingOptions" => [
      %{
        "shippingCost" => %{
          "value" => "5.49",
          "currency" => "EUR"
        }
      }
    ]
  }

  test "normalize_item/1 transforms raw eBay item into DealScout deal attributes" do
    deal = Client.normalize_item(@sample_item)

    assert deal.guid == "ebay-v1|123456789012|0"
    assert deal.title == "NVIDIA GeForce RTX 4080 Founders Edition 16GB"
    assert deal.url == "https://www.ebay.de/itm/123456789012"
    assert deal.image_url == "https://i.ebayimg.com/images/g/abc/s-l500.jpg"
    assert deal.price == Decimal.new("799.50")
    assert deal.raw_merchant == "eBay"
    assert deal.temperature == 100
    assert deal.country.country_code == "DE"
    assert deal.country.is_germany == true

    assert deal.description =~ "Zustand: Gebraucht"
    assert deal.description =~ "gpu_master (99.4%, 520 Bewertungen)"
    assert deal.description =~ "Versand: 5.49 EUR"
    assert deal.clean_text =~ "RTX 4080"
  end

  test "search/1 sends correct headers and query parameters" do
    plug = fn conn ->
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth == "Bearer test_bearer_token"

      [marketplace] = Plug.Conn.get_req_header(conn, "x-ebay-c-marketplace-id")
      assert marketplace == "EBAY_DE"

      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["q"] == "RTX 4080"
      assert params["sort"] == "newlyListed"
      assert params["limit"] == "25"
      assert params["filter"] =~ "buyingOptions:{FIXED_PRICE}"

      response_payload = %{
        "total" => 1,
        "itemSummaries" => [@sample_item]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response_payload))
    end

    assert {:ok, [deal]} =
             Client.search(
               q: "RTX 4080",
               limit: 25,
               token: "test_bearer_token",
               req_options: [plug: plug]
             )

    assert deal.guid == "ebay-v1|123456789012|0"
  end

  test "search/1 handles empty itemSummaries gracefully" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"total" => 0}))
    end

    assert {:ok, []} =
             Client.search(
               q: "nonexistent_query_xyz",
               token: "test_token",
               req_options: [plug: plug]
             )
  end

  test "search/1 handles 429 rate limit errors" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Rate limit exceeded"}))
    end

    assert {:error, {:rate_limited, 429, _}} =
             Client.search(
               q: "test",
               token: "test_token",
               req_options: [plug: plug]
             )
  end
end
