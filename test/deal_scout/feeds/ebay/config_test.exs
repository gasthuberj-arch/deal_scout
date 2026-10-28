defmodule DealScout.Feeds.Ebay.ConfigTest do
  use ExUnit.Case, async: false

  alias DealScout.Feeds.Ebay.Config

  setup do
    original_config = Application.get_env(:deal_scout, DealScout.Feeds.Ebay)

    on_exit(fn ->
      if original_config do
        Application.put_env(:deal_scout, DealScout.Feeds.Ebay, original_config)
      else
        Application.delete_env(:deal_scout, DealScout.Feeds.Ebay)
      end
    end)

    :ok
  end

  test "configured? returns false when credentials are empty" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay, client_id: nil, client_secret: nil)
    refute Config.configured?()
    refute Config.enabled?()
  end

  test "configured? returns true when both client_id and client_secret are set" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay,
      client_id: "test-app-id",
      client_secret: "test-secret"
    )

    assert Config.configured?()
    assert Config.enabled?()
    assert Config.client_id() == "test-app-id"
    assert Config.client_secret() == "test-secret"
  end

  test "respects enabled: false flag even when configured" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay,
      client_id: "test-app-id",
      client_secret: "test-secret",
      enabled: false
    )

    assert Config.configured?()
    refute Config.enabled?()
  end

  test "defaults marketplace_id to EBAY_DE and poll_interval_seconds to 60" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay, [])

    assert Config.marketplace_id() == "EBAY_DE"
    assert Config.poll_interval_seconds() == 60
    assert Config.auth_url() == "https://api.ebay.com/identity/v1/oauth2/token"
    assert Config.api_base_url() == "https://api.ebay.com"
  end
end
