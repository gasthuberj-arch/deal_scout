defmodule DealScout.Accounts.UserNotifierTest do
  use ExUnit.Case, async: true

  alias DealScout.Accounts.UserNotifier
  alias DealScout.Accounts.User
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed

  setup do
    user = %User{email: "dealhunter@example.com"}
    feed = %Feed{name: "MyDealz"}
    alert_rule = %AlertRule{name: "GPU Alert", keywords: "RTX 4080"}

    %{user: user, feed: feed, alert_rule: alert_rule}
  end

  describe "deliver_deal_alert/3" do
    test "succeeds when deal.merchant is a loaded %Merchant{} struct without raising Protocol.UndefinedError",
         %{user: user, feed: feed, alert_rule: alert_rule} do
      merchant = %Merchant{name: "MediaMarkt", slug: "mediamarkt"}

      deal = %Deal{
        title: "RTX 4080 Super",
        price: Decimal.new("949.00"),
        merchant: merchant,
        feed: feed,
        url: "https://example.com/deals/1"
      }

      assert {:ok, email} = UserNotifier.deliver_deal_alert(user, deal, alert_rule)
      assert email.to == [{"", "dealhunter@example.com"}]
      assert email.subject == "[DealScout] Deal Match: RTX 4080 Super"
      assert email.text_body =~ "Price: 949.00 € at MediaMarkt"
      assert email.text_body =~ "A new deal matched your alert rule \"GPU Alert\" (RTX 4080)"
      assert email.text_body =~ "Source: MyDealz"
      assert email.text_body =~ "https://example.com/deals/1"
    end

    test "succeeds when deal.merchant is a string", %{
      user: user,
      feed: feed,
      alert_rule: alert_rule
    } do
      deal = %Deal{
        title: "PlayStation 5 Pro",
        price: Decimal.new("799.00"),
        merchant: "Amazon",
        feed: feed,
        url: "https://example.com/deals/2"
      }

      assert {:ok, email} = UserNotifier.deliver_deal_alert(user, deal, alert_rule)
      assert email.text_body =~ "Price: 799.00 € at Amazon"
    end

    test "falls back to raw_merchant when deal.merchant is nil",
         %{user: user, feed: feed, alert_rule: alert_rule} do
      deal = %Deal{
        title: "Apple MacBook Air M3",
        price: Decimal.new("1099.00"),
        merchant: nil,
        raw_merchant: "Cyberport",
        feed: feed,
        url: "https://example.com/deals/3"
      }

      assert {:ok, email} = UserNotifier.deliver_deal_alert(user, deal, alert_rule)
      assert email.text_body =~ "Price: 1099.00 € at Cyberport"
    end

    test "formats cleanly when both merchant and raw_merchant are nil",
         %{user: user, feed: feed, alert_rule: alert_rule} do
      deal = %Deal{
        title: "Nintendo Switch OLED",
        price: Decimal.new("299.00"),
        merchant: nil,
        raw_merchant: nil,
        feed: feed,
        url: "https://example.com/deals/4"
      }

      assert {:ok, email} = UserNotifier.deliver_deal_alert(user, deal, alert_rule)
      assert email.text_body =~ "Price: 299.00 € \n"
    end

    test "handles missing price gracefully", %{user: user, feed: feed, alert_rule: alert_rule} do
      deal = %Deal{
        title: "Free Steam Game",
        price: nil,
        merchant: %Merchant{name: "Steam"},
        feed: feed,
        url: "https://example.com/deals/5"
      }

      assert {:ok, email} = UserNotifier.deliver_deal_alert(user, deal, alert_rule)
      assert email.text_body =~ "Price: Price not listed at Steam"
    end
  end
end
