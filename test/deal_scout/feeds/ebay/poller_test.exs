defmodule DealScout.Feeds.Ebay.PollerTest do
  use DealScout.DataCase, async: false

  alias DealScout.AccountsFixtures
  alias DealScout.Alerts
  alias DealScout.Feeds.Ebay.{Poller, SeenCache}

  setup do
    SeenCache.clear()
    user = AccountsFixtures.user_fixture()
    {:ok, user: user}
  end

  test "perform_poll_cycle returns 0 queries when no alert rules exist" do
    assert {:ok, stats} = Poller.perform_poll_cycle()
    assert stats.queries_run == 0
    assert stats.new_items == 0
    assert stats.matched == 0
  end

  test "perform_poll_cycle executes search, filters seen items, and matches", %{user: user} do
    {:ok, _rule} =
      Alerts.create_alert_rule(user, %{
        name: "Watch GPU",
        keywords: "RTX 4080",
        max_price: Decimal.new("800.00"),
        source_filter: "all"
      })

    item1 = %{
      guid: "ebay-v1|9001|0",
      title: "NVIDIA GeForce RTX 4080 16GB",
      url: "https://www.ebay.de/itm/9001",
      price: Decimal.new("750.00"),
      clean_text: "NVIDIA GeForce RTX 4080 16GB",
      description: "Zustand: Gebraucht",
      temperature: 100,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    item2 = %{
      guid: "ebay-v1|9002|0",
      title: "PlayStation 5 Console",
      url: "https://www.ebay.de/itm/9002",
      price: Decimal.new("450.00"),
      clean_text: "PlayStation 5 Console",
      description: "Zustand: Neu",
      temperature: 100,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    plug = fn conn ->
      response_payload = %{
        "total" => 2,
        "itemSummaries" => [
          %{
            "itemId" => "v1|9001|0",
            "title" => item1.title,
            "price" => %{"value" => "750.00", "currency" => "EUR"},
            "itemWebUrl" => item1.url,
            "condition" => "Used"
          },
          %{
            "itemId" => "v1|9002|0",
            "title" => item2.title,
            "price" => %{"value" => "450.00", "currency" => "EUR"},
            "itemWebUrl" => item2.url,
            "condition" => "New"
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response_payload))
    end

    # First poll cycle
    assert {:ok, stats} =
             Poller.perform_poll_cycle(
               client_opts: [token: "test_token", req_options: [plug: plug]]
             )

    assert stats.queries_run == 1
    assert stats.new_items == 2
    assert stats.matched == 1
    assert stats.discarded == 1

    # Second poll cycle with same upstream data -> items are already in SeenCache!
    assert {:ok, stats2} =
             Poller.perform_poll_cycle(
               client_opts: [token: "test_token", req_options: [plug: plug]]
             )

    assert stats2.queries_run == 1
    assert stats2.new_items == 0
    assert stats2.matched == 0
    assert stats2.discarded == 0
  end

  test "poller GenServer starts up and returns status" do
    poller =
      start_supervised!({Poller, [auto_start: false, poll_interval_seconds: 120]})

    status = GenServer.call(poller, :get_status)
    assert status.last_status == :idle
    assert status.consecutive_errors == 0
  end
end
