defmodule DealScout.Alerts.Backtest do
  @moduledoc """
  Historical backtesting engine for alert rules.
  Performs fast candidate lookup on SQLite FTS5 table `deals_fts`,
  falls back safely to the last 100 deals if FTS returns empty or fails,
  and evaluates candidate deals through `DealScout.Alerts.Matcher.matches?/2`.
  """

  import Ecto.Query
  alias DealScout.Repo
  alias DealScout.Deals.Deal
  alias DealScout.Deals.CrossBorderGuard
  alias DealScout.Alerts.AlertRule
  alias DealScout.Alerts.Matcher

  @default_candidate_limit 50
  @default_broad_threshold 10
  @default_fallback_limit 100

  @doc """
  Tests an alert rule (struct or parameter map) against past deals.

  Options:
  - `:limit` - Maximum number of candidate deals to retrieve from FTS (default: 50).
  - `:broad_threshold` - Threshold count above which the status is `:broad_match` (default: 10).
  - `:fallback_limit` - Number of deals to scan when FTS is empty or fails (default: 100).

  Returns:
    %{
      matches: matching_deals,
      total_matches: length(matching_deals),
      last_match: List.first(matching_deals),
      status: :match_found | :no_matches | :broad_match
    }
  """
  def test_rule(rule_params_or_struct, opts \\ []) do
    rule = normalize_rule(rule_params_or_struct)
    limit = Keyword.get(opts, :limit, @default_candidate_limit)
    broad_threshold = Keyword.get(opts, :broad_threshold, @default_broad_threshold)
    fallback_limit = Keyword.get(opts, :fallback_limit, @default_fallback_limit)

    keywords =
      case rule.keywords do
        nil -> ""
        k when is_binary(k) -> String.trim(k)
        _ -> ""
      end

    if keywords == "" do
      %{
        matches: [],
        total_matches: 0,
        last_match: nil,
        status: :no_matches
      }
    else
      candidates = fetch_candidate_deals(keywords, limit, fallback_limit)

      matching_deals =
        candidates
        |> Enum.map(&CrossBorderGuard.enrich/1)
        |> Enum.filter(&Matcher.matches?(&1, rule))

      total = length(matching_deals)
      last = List.first(matching_deals)

      status =
        cond do
          total == 0 -> :no_matches
          total > broad_threshold -> :broad_match
          true -> :match_found
        end

      %{
        matches: matching_deals,
        total_matches: total,
        last_match: last,
        status: status
      }
    end
  end

  @doc """
  Extracts distinct search terms from keywords string.
  """
  def extract_search_terms(keywords) when is_binary(keywords) do
    normalized = Matcher.normalize_quotes(keywords)

    case Matcher.parse_keywords(normalized) do
      {:ok, ast} ->
        ast
        |> extract_terms_from_ast()
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        normalized
        |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
        |> String.split(~r/\s+/, trim: true)
        |> Enum.uniq()
    end
  end

  def extract_search_terms(_), do: []

  defp extract_terms_from_ast({:term, word}), do: [word]
  defp extract_terms_from_ast({:exact, phrase}), do: [phrase]

  defp extract_terms_from_ast({:and, left, right}),
    do: extract_terms_from_ast(left) ++ extract_terms_from_ast(right)

  defp extract_terms_from_ast({:or, left, right}),
    do: extract_terms_from_ast(left) ++ extract_terms_from_ast(right)

  defp extract_terms_from_ast(_), do: []

  @doc """
  Builds a sanitized SQLite FTS5 query string from keywords input.
  Supports exact phrases, AND / OR operators, and grouping.
  """
  def build_fts_query(keywords) when is_binary(keywords) do
    normalized = Matcher.normalize_quotes(keywords)

    case Matcher.parse_keywords(normalized) do
      {:ok, ast} ->
        case ast_to_fts(ast) do
          nil -> fallback_fts_query(normalized)
          "" -> fallback_fts_query(normalized)
          query -> query
        end

      _ ->
        fallback_fts_query(normalized)
    end
  end

  def build_fts_query(_), do: nil

  defp ast_to_fts({:term, word}) do
    clean = sanitize_token(word)
    if clean == "", do: nil, else: "\"#{clean}\"*"
  end

  defp ast_to_fts({:exact, phrase}) do
    clean =
      phrase
      |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.join(" ")

    if clean == "", do: nil, else: "\"#{clean}\""
  end

  defp ast_to_fts({:and, left, right}) do
    case {ast_to_fts(left), ast_to_fts(right)} do
      {nil, right} -> right
      {left, nil} -> left
      {left, right} -> "(#{left} AND #{right})"
    end
  end

  defp ast_to_fts({:or, left, right}) do
    case {ast_to_fts(left), ast_to_fts(right)} do
      {nil, right} -> right
      {left, nil} -> left
      {left, right} -> "(#{left} OR #{right})"
    end
  end

  defp ast_to_fts(_), do: nil

  defp sanitize_token(term) do
    String.replace(term, ~r/[^\p{L}\p{N}\-]/u, "")
  end

  defp fallback_fts_query(term) do
    tokens =
      term
      |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&sanitize_token/1)
      |> Enum.reject(&(&1 == ""))

    case tokens do
      [] ->
        nil

      list ->
        list
        |> Enum.map(&"\"#{&1}\"*")
        |> Enum.join(" OR ")
    end
  end

  defp fetch_candidate_deals(keywords, limit, fallback_limit) do
    fts_query = build_fts_query(keywords)

    if is_nil(fts_query) or fts_query == "" do
      fetch_fallback_deals(fallback_limit)
    else
      case query_fts_candidates(fts_query, limit) do
        {:ok, deals} when deals != [] ->
          deals

        _ ->
          fetch_fallback_deals(fallback_limit)
      end
    end
  end

  defp query_fts_candidates(fts_query, limit) do
    try do
      sql = "SELECT rowid FROM deals_fts WHERE deals_fts MATCH ? ORDER BY rowid DESC LIMIT ?"

      case Ecto.Adapters.SQL.query(Repo, sql, [fts_query, limit]) do
        {:ok, %{rows: rows}} when rows != [] ->
          ids = Enum.map(rows, fn [id] -> id end)
          deals = fetch_deals_by_ids(ids)
          {:ok, deals}

        {:ok, %{rows: []}} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        {:error, e}
    end
  end

  defp fetch_deals_by_ids(ids) do
    from(d in Deal,
      where: d.id in ^ids,
      order_by: [desc: d.published_at, desc: d.id],
      preload: [:merchant, :feed]
    )
    |> Repo.all()
  end

  defp fetch_fallback_deals(fallback_limit) do
    from(d in Deal,
      order_by: [desc: d.published_at, desc: d.id],
      limit: ^fallback_limit,
      preload: [:merchant, :feed]
    )
    |> Repo.all()
  end

  @doc """
  Normalizes an alert rule struct or parameter map into an `%AlertRule{}`.
  """
  def normalize_rule(%AlertRule{} = rule), do: rule

  def normalize_rule(%{"alert_rule" => inner}) when is_map(inner) do
    normalize_rule(inner)
  end

  def normalize_rule(%{alert_rule: inner}) when is_map(inner) do
    normalize_rule(inner)
  end

  def normalize_rule(params) when is_map(params) do
    %AlertRule{
      user_id: 1,
      exclude_dropshippers: true,
      country_filter: "all",
      merchant_filter: "all",
      exclude_foreign_keyboards: false,
      source_filter: "all",
      delivery_mode: "instant",
      is_active: true
    }
    |> AlertRule.changeset(params)
    |> Ecto.Changeset.apply_changes()
  end

  def normalize_rule(_), do: %AlertRule{}
end
