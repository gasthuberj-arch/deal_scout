defmodule DealScout.Alerts.Matcher do
  @moduledoc """
  Evaluates whether a Deal matches an AlertRule.
  Supports required keywords (including quoted phrases, AND/OR operators, and parentheses grouping),
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
         true <- matches_merchant_trust?(deal, rule.merchant_filter),
         true <- not_excluded?(deal, rule.negative_keywords),
         true <- matches_keywords?(deal, rule.keywords),
         true <- not_dropshipper?(deal, rule.exclude_dropshippers),
         true <- matches_country?(deal, rule.country_filter),
         true <- not_foreign_keyboard?(deal, rule.exclude_foreign_keyboards) do
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
      |> normalize_quotes()
      |> String.split([",", ";", "\n"], trim: true)
      |> Enum.flat_map(&extract_tokens/1)

    Enum.all?(negative_tokens, fn token ->
      not contains_token?(text, token)
    end)
  end

  defp matches_keywords?(deal, keywords) when is_binary(keywords) do
    text = searchable_text(deal)
    normalized = normalize_quotes(keywords)

    case parse_keywords(normalized) do
      {:ok, :empty} ->
        false

      {:ok, ast} ->
        eval_ast(ast, text)

      {:error, _reason} ->
        legacy_matches_keywords?(text, normalized)
    end
  end

  defp matches_keywords?(_deal, _), do: false

  @doc """
  Normalizes typographical or language-specific quotation marks to standard ASCII quotes.
  """
  def normalize_quotes(str) when is_binary(str) do
    String.replace(str, ["“", "”", "„", "«", "»"], "\"")
  end

  @doc """
  Parses a keywords query into an AST supporting:
  - Boolean AND (explicit AND/&/&& or implicit whitespace)
  - Boolean OR (explicit OR/|/|| or comma/semicolon)
  - Quoted exact phrases ("...")
  - Parentheses grouping (...)
  """
  def parse_keywords(str) when is_binary(str) do
    tokens = tokenize(str)

    if tokens == [] do
      {:ok, :empty}
    else
      case parse_or(tokens) do
        {:ok, ast, []} ->
          {:ok, ast}

        {:ok, ast, remaining} ->
          if Enum.all?(remaining, &(&1 in [:or, :and, :rparen])) do
            {:ok, ast}
          else
            {:error, :unparsed_tokens}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def tokenize(str) when is_binary(str) do
    Regex.scan(~r/"[^"]*"|[(),;]|&&|\|\||[^\s(),;"]+/, str)
    |> Enum.map(fn [token] ->
      cond do
        String.starts_with?(token, "\"") and String.ends_with?(token, "\"") and
            String.length(token) >= 2 ->
          phrase = token |> String.slice(1..-2//1) |> String.trim()
          if phrase == "", do: nil, else: {:exact, phrase}

        token == "(" ->
          :lparen

        token == ")" ->
          :rparen

        token in [",", ";", "|", "||"] ->
          :or

        token in ["&", "&&"] ->
          :and

        String.upcase(token) == "OR" ->
          :or

        String.upcase(token) == "AND" ->
          :and

        true ->
          {:term, token}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> clean_tokens()
    |> insert_implicit_and()
  end

  defp clean_tokens(tokens) do
    tokens
    |> Enum.reduce([], fn
      :or, [:or | rest] -> [:or | rest]
      :and, [:and | rest] -> [:and | rest]
      tok, acc -> [tok | acc]
    end)
    |> Enum.reverse()
    |> strip_leading_trailing_ops()
  end

  defp strip_leading_trailing_ops(tokens) do
    tokens
    |> Enum.drop_while(&(&1 in [:or, :and, :rparen]))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in [:or, :and, :lparen]))
    |> Enum.reverse()
  end

  defp insert_implicit_and([]), do: []
  defp insert_implicit_and([single]), do: [single]

  defp insert_implicit_and([first | rest]) do
    do_insert_implicit_and(first, rest, [])
  end

  defp do_insert_implicit_and(prev, [], acc) do
    Enum.reverse([prev | acc])
  end

  defp do_insert_implicit_and(prev, [curr | rest], acc) do
    if value_token_end?(prev) and value_token_start?(curr) do
      do_insert_implicit_and(curr, rest, [:and, prev | acc])
    else
      do_insert_implicit_and(curr, rest, [prev | acc])
    end
  end

  defp value_token_end?({:term, _}), do: true
  defp value_token_end?({:exact, _}), do: true
  defp value_token_end?(:rparen), do: true
  defp value_token_end?(_), do: false

  defp value_token_start?({:term, _}), do: true
  defp value_token_start?({:exact, _}), do: true
  defp value_token_start?(:lparen), do: true
  defp value_token_start?(_), do: false

  defp parse_or(tokens) do
    case parse_and(tokens) do
      {:ok, left, [:or | rest]} ->
        case rest do
          [] ->
            {:ok, left, []}

          _ ->
            case parse_or(rest) do
              {:ok, right, rem} -> {:ok, {:or, left, right}, rem}
              error -> error
            end
        end

      other ->
        other
    end
  end

  defp parse_and(tokens) do
    case parse_primary(tokens) do
      {:ok, left, [:and | rest]} ->
        case rest do
          [] ->
            {:ok, left, []}

          _ ->
            case parse_and(rest) do
              {:ok, right, rem} -> {:ok, {:and, left, right}, rem}
              error -> error
            end
        end

      other ->
        other
    end
  end

  defp parse_primary([{:term, word} | rest]), do: {:ok, {:term, word}, rest}
  defp parse_primary([{:exact, phrase} | rest]), do: {:ok, {:exact, phrase}, rest}

  defp parse_primary([:lparen | rest]) do
    case parse_or(rest) do
      {:ok, expr, [:rparen | after_rparen]} ->
        {:ok, expr, after_rparen}

      {:ok, expr, []} ->
        # Missing closing paren - be lenient and accept the expr
        {:ok, expr, []}

      error ->
        error
    end
  end

  defp parse_primary([other | rest]) when other in [:or, :and, :rparen] do
    # Skip stray leading or duplicate operators
    parse_primary(rest)
  end

  defp parse_primary([]), do: {:error, :unexpected_end}
  defp parse_primary(_), do: {:error, :unexpected_token}

  defp eval_ast(:empty, _text), do: false
  defp eval_ast({:term, word}, text), do: contains_token?(text, word)
  defp eval_ast({:exact, phrase}, text), do: contains_token?(text, phrase)
  defp eval_ast({:and, left, right}, text), do: eval_ast(left, text) and eval_ast(right, text)
  defp eval_ast({:or, left, right}, text), do: eval_ast(left, text) or eval_ast(right, text)

  defp legacy_matches_keywords?(text, keywords) do
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

  defp extract_tokens(str) when is_binary(str) do
    Regex.scan(~r/"([^"]+)"|[^\s(),;"]+/, str)
    |> Enum.map(fn
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
