defmodule DealScout.Feeds.Ebay.Auth do
  @moduledoc """
  Manages eBay OAuth 2.0 application access tokens (Client Credentials flow).

  Caches tokens in an in-memory ETS table to minimize round-trips and
  automatically refreshes before expiration (typically valid for 7,200s / 2 hours).
  """

  require Logger
  alias DealScout.Feeds.Ebay.Config

  @cache_table :ebay_token_cache
  @refresh_margin_seconds 120

  @doc """
  Returns a valid application access token.

  Options:
  - `:force_refresh` - boolean, forces fetching a new token even if cache is valid.
  - `:req_options` - keyword list of extra options forwarded to `Req.post/2` (e.g. for testing).

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  def get_token(opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    if force_refresh do
      fetch_and_cache_token(opts)
    else
      case get_cached_token() do
        {:ok, token} ->
          {:ok, token}

        :expired ->
          fetch_and_cache_token(opts)
      end
    end
  end

  @doc """
  Clears the cached token.
  """
  def clear_cache do
    ensure_table_exists()
    :ets.delete(@cache_table, :token)
    :ok
  end

  @doc """
  Returns the currently cached token tuple `{:ok, token, expires_at}` or `:none`.
  """
  def get_cached_token_details do
    ensure_table_exists()

    case :ets.lookup(@cache_table, :token) do
      [{:token, token, expires_at}] ->
        {:ok, token, expires_at}

      _ ->
        :none
    end
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp get_cached_token do
    case get_cached_token_details() do
      {:ok, token, expires_at} ->
        now = System.os_time(:second)

        if expires_at - now > @refresh_margin_seconds do
          {:ok, token}
        else
          :expired
        end

      :none ->
        :expired
    end
  end

  defp fetch_and_cache_token(opts) do
    client_id = Config.client_id()
    client_secret = Config.client_secret()

    if is_binary(client_id) and is_binary(client_secret) and client_id != "" and
         client_secret != "" do
      request_token(client_id, client_secret, opts)
    else
      {:error, :not_configured}
    end
  end

  defp request_token(client_id, client_secret, opts) do
    url = Config.auth_url()
    basic_auth = "Basic " <> Base.encode64("#{client_id}:#{client_secret}")

    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "scope" => "https://api.ebay.com/oauth/api_scope"
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"authorization", basic_auth}
    ]

    req_opts =
      [
        headers: headers,
        body: body,
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(Config.req_options())
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        handle_success_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "[DealScout.Feeds.Ebay.Auth] eBay token request failed with status #{status}: #{inspect(body)}"
        )

        {:error, {:auth_failed, status, body}}

      {:error, reason} ->
        Logger.error(
          "[DealScout.Feeds.Ebay.Auth] eBay token request network error: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp handle_success_response(body) do
    payload =
      case body do
        %{} = map -> map
        str when is_binary(str) -> Jason.decode!(str)
      end

    case payload do
      %{"access_token" => token, "expires_in" => expires_in} when is_binary(token) ->
        expires_at = System.os_time(:second) + expires_in
        ensure_table_exists()
        :ets.insert(@cache_table, {:token, token, expires_at})
        {:ok, token}

      _ ->
        {:error, {:invalid_response, payload}}
    end
  rescue
    e ->
      {:error, {:decode_error, e}}
  end

  defp ensure_table_exists do
    case :ets.info(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @cache_table
        end

      _ ->
        @cache_table
    end
  end
end
