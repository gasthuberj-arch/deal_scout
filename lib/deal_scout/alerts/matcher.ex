defmodule DealScout.Alerts.Matcher do
  @moduledoc """
  Evaluates whether a Deal matches an AlertRule.
  Keyword and negative-keyword semantics are delegated to `DealScout.KeywordEngine.Query`;
  this module owns the non-keyword filters: price limits, source filtering, minimum temperature,
  dropshipper exclusions, merchant trust verification, origin country filtering,
  and foreign keyboard exclusion.
  """

  alias DealScout.Deals
  alias DealScout.Deals.Deal
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.CrossBorderGuard
  alias DealScout.KeywordEngine.Query

  @doc """
  Returns true if the deal matches the alert rule.
  """
  def matches?(%Deal{} = deal, %AlertRule{} = rule) do
    with true <- matches_filters?(deal, rule),
         true <- not_excluded?(deal, rule.negative_keywords),
         true <- matches_keywords?(deal, rule.keywords) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Evaluates all non-keyword filters (source, price, temp, merchant, country, keyboard, dropshipper).
  Fast and does not perform text scanning.
  """
  def matches_filters?(%Deal{} = deal, %AlertRule{} = rule) do
    with true <- matches_source?(deal, rule.source_filter),
         true <- matches_price?(deal, rule.max_price),
         true <- matches_temperature?(deal, rule.min_temperature),
         true <- not_dropshipper?(deal, rule.exclude_dropshippers),
         true <- matches_merchant_trust?(deal, rule.merchant_filter),
         true <- matches_country?(deal, rule.country_filter),
         true <- not_foreign_keyboard?(deal, rule.exclude_foreign_keyboards) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Returns the canonical searchable text string for a deal.
  """
  defdelegate searchable_text(deal), to: Deals

  defp matches_source?(_deal, nil), do: true
  defp matches_source?(_deal, "all"), do: true

  defp matches_source?(deal, source_slug) do
    if deal.feed do
      deal.feed.slug == source_slug or to_string(deal.feed_id) == source_slug
    else
      to_string(deal.feed_id) == source_slug
    end
  end

  defp matches_price?(_deal, nil), do: true

  defp matches_price?(deal, max_price) do
    case deal.price do
      nil -> true
      price -> Decimal.compare(price, max_price) in [:lt, :eq]
    end
  end

  defp matches_temperature?(_deal, nil), do: true

  defp matches_temperature?(deal, min_temp) when is_integer(min_temp) do
    not is_nil(deal.temperature) and deal.temperature >= min_temp
  end

  defp not_dropshipper?(_deal, false), do: true
  defp not_dropshipper?(_deal, nil), do: true
  defp not_dropshipper?(deal, true), do: not Deals.dropshipper_deal?(deal)

  defp matches_merchant_trust?(_deal, nil), do: true
  defp matches_merchant_trust?(_deal, "all"), do: true

  defp matches_merchant_trust?(deal, "verified_only") do
    case deal.merchant do
      %{trust_level: "verified"} -> true
      _ -> false
    end
  end

  defp matches_merchant_trust?(_deal, _), do: true

  defp matches_country?(_deal, nil), do: true
  defp matches_country?(_deal, "all"), do: true

  defp matches_country?(deal, "de_only") do
    case CrossBorderGuard.detect_country(deal) do
      nil -> true
      %{code: "DE"} -> true
      _ -> false
    end
  end

  defp matches_country?(deal, "eu_only") do
    case CrossBorderGuard.detect_country(deal) do
      nil -> true
      %{code: code} when code in ["US", "UK", "CN"] -> false
      _ -> true
    end
  end

  defp matches_country?(_deal, _), do: true

  defp not_foreign_keyboard?(_deal, false), do: true
  defp not_foreign_keyboard?(_deal, nil), do: true

  defp not_foreign_keyboard?(deal, true) do
    is_nil(CrossBorderGuard.keyboard_warning(deal))
  end

  @doc """
  Returns true unless one of the rule's negative keywords occurs in the deal.
  """
  def not_excluded?(deal, negative_keywords) do
    not Query.excluded?(negative_keywords, searchable_text(deal))
  end

  defp matches_keywords?(deal, keywords) do
    case Query.parse(keywords) do
      {:ok, query} -> Query.matches?(query, searchable_text(deal))
      {:error, _} -> false
    end
  end
end
