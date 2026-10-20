defmodule DealScout.Alerts.Matcher do
  @moduledoc """
  Evaluates whether a Deal matches an AlertRule.
  Supports required keywords (including quoted phrases and AND/OR grouping),
  negative/exclusion keywords, price limits, source filtering, minimum temperature,
  dropshipper exclusions, merchant trust verification, origin country filtering,
  and foreign keyboard exclusion.
  """

  alias DealScout.Deals.Deal
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.MerchantGuard
  alias DealScout.Deals.CrossBorderGuard

  @doc """
  Returns true if the deal matches the alert rule.
  """
  def matches?(%Deal{} = deal, %AlertRule{} = rule) do
    with true <- matches_source?(deal, rule.source_filter),
         true <- matches_price?(deal, rule.max_price),
         true <- matches_temperature?(deal, rule.min_temperature),
         true <- not_dropshipper?(deal, rule.exclude_dropshippers),
         true <- matches_merchant_trust?(deal, rule.merchant_filter),
         true <- matches_country?(deal, rule.country_filter),
         true <- not_foreign_keyboard?(deal, rule.exclude_foreign_keyboards),
         true <- not_excluded?(deal, rule.negative_keywords),
         true <- matches_keywords?(deal, rule.keywords) do
      true
    else
      _ -> false
    end
  end

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

  defp not_dropshipper?(deal, true) do
    trust_level =
      case deal.merchant do
        %{trust_level: level} -> level
        _ -> nil
      end

    merchant_name =
      case deal.merchant do
        %{name: name} -> name
        _ -> deal.raw_merchant
      end

    if trust_level == "dropshipper" or MerchantGuard.dropshipper?(merchant_name, deal.url) do
      false
    else
      true
    end
  end

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

  defp not_excluded?(_deal, nil), do: true
  defp not_excluded?(_deal, ""), do: true

  defp not_excluded?(deal, negative_keywords) do
    text = searchable_text(deal)

    negative_tokens =
      negative_keywords
      |> String.split([",", ";", "\n"], trim: true)
      |> Enum.flat_map(&extract_tokens/1)

    Enum.all?(negative_tokens, fn token ->
      not contains_token?(text, token)
    end)
  end

  defp matches_keywords?(deal, keywords) when is_binary(keywords) do
    text = searchable_text(deal)

    groups =
      keywords
      |> String.split([",", ";"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case groups do
      [] ->
        false

      _ ->
        Enum.any?(groups, fn group ->
          tokens = extract_tokens(group)

          tokens != [] and
            Enum.all?(tokens, fn token ->
              contains_token?(text, token)
            end)
        end)
    end
  end

  defp matches_keywords?(_deal, _), do: false

  defp extract_tokens(str) when is_binary(str) do
    Regex.scan(~r/"([^"]+)"|(\S+)/, str)
    |> Enum.map(fn
      [_, quoted, ""] -> quoted
      [_, "", unquoted] -> unquoted
      [_, quoted] -> quoted
      [full] -> full
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp searchable_text(deal) do
    merchant_name =
      case deal.merchant do
        %{name: name} -> name
        _ -> deal.raw_merchant || ""
      end

    "#{deal.title} #{merchant_name} #{deal.clean_text || ""}"
    |> String.downcase()
  end

  defp contains_token?(text, token) do
    token = String.downcase(token)
    String.contains?(text, token)
  end
end
