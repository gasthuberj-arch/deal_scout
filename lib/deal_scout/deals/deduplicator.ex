defmodule DealScout.Deals.Deduplicator do
  @moduledoc """
  Multi-factor cross-platform deal de-duplication engine.
  Identifies identical product offers published across multiple deal portals
  within a 24-hour sliding window.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.Deal

  @stop_words ~w(
    für mit und der die das ein eine einen einem einer im in an auf von ab inkl
    versand kostenfrei gratis kostenlos prime euro rabatt gutschein deal angebot
    neu edition black friday cyber monday
  )

  @doc """
  Finds an existing canonical deal matching the given candidate attributes or struct.
  Returns `%Deal{}` if a match is found, or `nil`.
  """
  def find_canonical_deal(deal_attrs, window_hours \\ 24)

  def find_canonical_deal(%Deal{} = deal, window_hours) do
    find_canonical_deal(Map.from_struct(deal), window_hours)
  end

  def find_canonical_deal(attrs, window_hours) when is_map(attrs) do
    published_at = attrs[:published_at] || attrs["published_at"] || DateTime.utc_now()
    merchant_id = attrs[:merchant_id] || attrs["merchant_id"]
    title = attrs[:title] || attrs["title"] || ""
    price = attrs[:price] || attrs["price"]
    url = attrs[:url] || attrs["url"] || ""
    asin = extract_asin(url)

    if merchant_id && title != "" do
      since = DateTime.add(published_at, -window_hours * 3600, :second)
      until = DateTime.add(published_at, window_hours * 3600, :second)

      candidates =
        from(d in Deal,
          where: d.merchant_id == ^merchant_id,
          where: is_nil(d.canonical_deal_id),
          where: d.published_at >= ^since and d.published_at <= ^until,
          order_by: [asc: d.published_at, asc: d.id]
        )
        |> Repo.all()

      Enum.find(candidates, fn candidate ->
        matches_deal?(candidate, title, price, asin, url)
      end)
    else
      nil
    end
  end

  @doc """
  Checks if a candidate deal matches the target deal attributes.
  """
  def matches_deal?(candidate, target_title, target_price, target_asin, target_url) do
    cand_asin = extract_asin(candidate.url)

    # 1. Direct ASIN match (Amazon products)
    if target_asin && cand_asin && target_asin == cand_asin do
      true
    else
      # 2. Direct clean URL match
      cand_clean_url = clean_product_url(candidate.url)
      target_clean_url = clean_product_url(target_url)

      if cand_clean_url != "" and cand_clean_url == target_clean_url do
        true
      else
        # 3. Multi-factor: Title Token Similarity + Price Tolerance
        title_sim = token_similarity(candidate.title, target_title)
        price_match? = price_within_tolerance?(candidate.price, target_price, 0.03)

        title_sim >= 0.75 and price_match?
      end
    end
  end

  @doc """
  Calculates token-based Jaccard similarity between two titles (0.0 to 1.0).
  """
  def token_similarity(title_a, title_b) when is_binary(title_a) and is_binary(title_b) do
    tokens_a = tokenize(title_a)
    tokens_b = tokenize(title_b)

    if MapSet.size(tokens_a) == 0 or MapSet.size(tokens_b) == 0 do
      0.0
    else
      intersection = MapSet.intersection(tokens_a, tokens_b) |> MapSet.size()
      union = MapSet.union(tokens_a, tokens_b) |> MapSet.size()

      intersection / union
    end
  end

  def token_similarity(_, _), do: 0.0

  @doc """
  Tokenizes text into a MapSet of meaningful normalized words.
  """
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words or String.length(&1) < 2))
    |> MapSet.new()
  end

  def tokenize(_), do: MapSet.new()

  @doc """
  Checks if two prices are within a relative tolerance (default ±3%).
  If either price is nil, returns true.
  """
  def price_within_tolerance?(nil, _, _), do: true
  def price_within_tolerance?(_, nil, _), do: true

  def price_within_tolerance?(%Decimal{} = a, %Decimal{} = b, tolerance) do
    fa = Decimal.to_float(a)
    fb = Decimal.to_float(b)

    if fa == 0.0 or fb == 0.0 do
      fa == fb
    else
      diff = abs(fa - fb)
      max_val = max(fa, fb)
      diff / max_val <= tolerance
    end
  end

  def price_within_tolerance?(_, _, _), do: true

  @doc """
  Extracts an Amazon ASIN from a URL if present.
  """
  def extract_asin(nil), do: nil

  def extract_asin(url) when is_binary(url) do
    case Regex.run(~r/(?:\/dp\/|\/gp\/product\/|\/asin\/)([A-Z0-9]{10})/i, url) do
      [_, asin] -> String.upcase(asin)
      _ -> nil
    end
  end

  @doc """
  Strips query parameters and tracking hashes from product URLs for clean comparison.
  """
  def clean_product_url(nil), do: ""

  def clean_product_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        "#{String.downcase(host)}#{path}"
        |> String.replace(~r/\/+$/, "")

      _ ->
        ""
    end
  end
end
