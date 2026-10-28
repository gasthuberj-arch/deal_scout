defmodule DealScout.Feeds.Ebay.Client do
  @moduledoc """
  Client for the eBay Browse REST API (`/buy/browse/v1/item_summary/search`).

  Provides filtered searching for newly listed Buy-It-Now (Sofort-Kauf) deals
  and transforms raw eBay JSON responses into standardized DealScout deal maps.
  """

  require Logger
  alias DealScout.Feeds.Ebay.{Auth, Config}

  @search_path "/buy/browse/v1/item_summary/search"
  @default_limit 50
  @default_sort "newlyListed"
  @default_filter "buyingOptions:{FIXED_PRICE},deliveryCountry:DE"

  @doc """
  Searches eBay for items matching the given query `q`.

  Options:
  - `:q` - Query string (e.g., `"(RTX 4080, RTX 4090)"` or `"ThinkPad T14"`).
  - `:limit` - Maximum number of items to return (default: 50).
  - `:sort` - Sort order (default: `"newlyListed"`).
  - `:filter` - Filter string (default: `"buyingOptions:{FIXED_PRICE},deliveryCountry:DE"`).
  - `:category_ids` - Optional comma-separated eBay category IDs.
  - `:token` - Explicit bearer token (optional; fetched via `Auth` if omitted).
  - `:req_options` - Extra options passed to `Req.get/2` (for test stubs).

  Returns `{:ok, [deal_map]}` or `{:error, reason}`.
  """
  def search(opts \\ []) do
    token_result =
      case Keyword.fetch(opts, :token) do
        {:ok, token} -> {:ok, token}
        :error -> Auth.get_token()
      end

    case token_result do
      {:ok, token} ->
        do_search(token, opts, _allow_retry? = true)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_search(token, opts, allow_retry?) do
    url = Config.api_base_url() <> @search_path
    marketplace_id = Config.marketplace_id()

    headers = [
      {"authorization", "Bearer " <> token},
      {"x-ebay-c-marketplace-id", marketplace_id},
      {"accept", "application/json"}
    ]

    params = build_query_params(opts)

    req_opts =
      [
        headers: headers,
        params: params,
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(Config.req_options())
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        items = parse_items(body)
        normalized = Enum.map(items, &normalize_item/1)
        {:ok, normalized}

      {:ok, %Req.Response{status: 401, body: body}} when allow_retry? ->
        Logger.warning(
          "[DealScout.Feeds.Ebay.Client] 401 Unauthorized received, refreshing token and retrying..."
        )

        case Auth.get_token(force_refresh: true) do
          {:ok, new_token} ->
            do_search(new_token, opts, false)

          {:error, reason} ->
            {:error, {:auth_refresh_failed, reason, body}}
        end

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.warning(
          "[DealScout.Feeds.Ebay.Client] Rate limited (429) by eBay Browse API: #{inspect(body)}"
        )

        {:error, {:rate_limited, 429, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "[DealScout.Feeds.Ebay.Client] Search failed with status #{status}: #{inspect(body)}"
        )

        {:error, {:search_failed, status, body}}

      {:error, reason} ->
        Logger.error(
          "[DealScout.Feeds.Ebay.Client] Network error during search: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_query_params(opts) do
    q = Keyword.get(opts, :q)
    limit = Keyword.get(opts, :limit, @default_limit)
    sort = Keyword.get(opts, :sort, @default_sort)
    filter = Keyword.get(opts, :filter, @default_filter)
    category_ids = Keyword.get(opts, :category_ids)

    params = %{
      "limit" => to_string(limit),
      "sort" => sort,
      "filter" => filter
    }

    params =
      if is_binary(q) and String.trim(q) != "" do
        Map.put(params, "q", q)
      else
        params
      end

    if is_binary(category_ids) and String.trim(category_ids) != "" do
      Map.put(params, "category_ids", category_ids)
    else
      params
    end
  end

  defp parse_items(body) do
    payload =
      case body do
        %{} = map -> map
        str when is_binary(str) -> Jason.decode!(str)
        _ -> %{}
      end

    Map.get(payload, "itemSummaries", [])
  rescue
    _ -> []
  end

  @doc """
  Normalizes an individual raw eBay item summary into DealScout deal attributes.
  """
  def normalize_item(item) when is_map(item) do
    item_id = item["itemId"] || "unknown"
    title = item["title"] || "eBay Angebot"
    url = item["itemWebUrl"] || "https://www.ebay.de/itm/" <> item_id
    image_url = extract_image_url(item)
    price = extract_price(item["price"])
    published_at = parse_datetime(item["itemCreationDate"])
    condition = format_condition(item["condition"])
    seller_summary = format_seller(item["seller"])
    shipping_summary = format_shipping(item["shippingOptions"])

    description_parts =
      [
        condition,
        seller_summary,
        shipping_summary
      ]
      |> Enum.reject(&is_nil/1)

    description = Enum.join(description_parts, " | ")
    clean_text = "#{title} #{description}"

    %{
      guid: "ebay-" <> item_id,
      title: title,
      url: url,
      image_url: image_url,
      price: price,
      raw_merchant: "eBay",
      published_at: published_at,
      temperature: 100,
      description: description,
      clean_text: clean_text,
      country: %{
        country_code: "DE",
        is_germany: true,
        is_eu: true,
        flags: "🇩🇪",
        requires_action: false
      },
      keyboard_warning: nil
    }
  end

  defp extract_image_url(item) do
    case get_in(item, ["image", "imageUrl"]) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        case item["thumbnailImages"] do
          [%{"imageUrl" => thumb_url} | _] -> thumb_url
          _ -> nil
        end
    end
  end

  defp extract_price(%{"value" => value}) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp extract_price(_), do: nil

  defp parse_datetime(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp format_condition(nil), do: nil
  defp format_condition("New"), do: "Zustand: Neu"
  defp format_condition("Used"), do: "Zustand: Gebraucht"
  defp format_condition("Refurbished"), do: "Zustand: Generalüberholt"
  defp format_condition(other), do: "Zustand: #{other}"

  defp format_seller(%{"username" => username} = seller) do
    feedback_pct = seller["feedbackPercentage"]
    feedback_score = seller["feedbackScore"]

    cond do
      feedback_pct && feedback_score ->
        "Verkäufer: #{username} (#{feedback_pct}%, #{feedback_score} Bewertungen)"

      feedback_score ->
        "Verkäufer: #{username} (#{feedback_score} Bewertungen)"

      true ->
        "Verkäufer: #{username}"
    end
  end

  defp format_seller(_), do: nil

  defp format_shipping([%{"shippingCost" => %{"value" => "0.00"}} | _]), do: "Versand: Kostenlos"

  defp format_shipping([%{"shippingCost" => %{"value" => val, "currency" => curr}} | _]) do
    "Versand: #{val} #{curr}"
  end

  defp format_shipping(_), do: nil
end
