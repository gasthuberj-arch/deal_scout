defmodule DealScout.Feeds.Ebay.Config do
  @moduledoc """
  Configuration helper for eBay Browse REST API integration.
  """

  @default_marketplace_id "EBAY_DE"
  @default_auth_url "https://api.ebay.com/identity/v1/oauth2/token"
  @default_api_base_url "https://api.ebay.com"
  @default_poll_interval_seconds 60

  @doc """
  Returns the configured eBay Client ID (App ID), or nil if unset.
  """
  def client_id do
    get_ebay_config(:client_id) || System.get_env("EBAY_CLIENT_ID")
  end

  @doc """
  Returns the configured eBay Client Secret (Cert ID), or nil if unset.
  """
  def client_secret do
    get_ebay_config(:client_secret) || System.get_env("EBAY_CLIENT_SECRET")
  end

  @doc """
  Returns the configured eBay Marketplace ID (default "EBAY_DE").
  """
  def marketplace_id do
    get_ebay_config(:marketplace_id) || System.get_env("EBAY_MARKETPLACE_ID") ||
      @default_marketplace_id
  end

  @doc """
  Returns the polling interval in seconds (default 60).
  """
  def poll_interval_seconds do
    get_ebay_config(:poll_interval_seconds) || @default_poll_interval_seconds
  end

  @doc """
  Returns the OAuth token endpoint URL.
  """
  def auth_url do
    get_ebay_config(:auth_url) || @default_auth_url
  end

  @doc """
  Returns the base API endpoint URL.
  """
  def api_base_url do
    get_ebay_config(:api_base_url) || @default_api_base_url
  end

  @doc """
  Returns true if both client ID and client secret are configured.
  """
  def configured? do
    present?(client_id()) and present?(client_secret())
  end

  @doc """
  Returns true if eBay integration is enabled and configured.
  """
  def enabled? do
    configured?() and get_ebay_config(:enabled, true) != false
  end

  @doc """
  Returns any configured Req options (useful for test plugs or custom transports).
  """
  def req_options do
    get_ebay_config(:req_options, [])
  end

  defp get_ebay_config(key, default \\ nil) do
    config = Application.get_env(:deal_scout, DealScout.Feeds.Ebay, [])
    Keyword.get(config, key, default)
  end

  defp present?(val) when is_binary(val), do: String.trim(val) != ""
  defp present?(_), do: false
end
