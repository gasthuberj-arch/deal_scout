defmodule DealScout.Feeds.Ebay.QueryAggregatorTest do
  use ExUnit.Case, async: true

  alias DealScout.Alerts.AlertRule
  alias DealScout.Feeds.Ebay.QueryAggregator

  test "returns empty list when input is empty" do
    assert QueryAggregator.build_queries([]) == []
  end

  test "extracts and deduplicates keywords from eligible alert rules" do
    rules = [
      %AlertRule{
        is_active: true,
        source_filter: "all",
        keywords: "RTX 4080, RTX 4090"
      },
      %AlertRule{
        is_active: true,
        source_filter: "ebay",
        keywords: "rtx 4080, 7900 XTX"
      },
      # Inactive rule -> ignored
      %AlertRule{
        is_active: false,
        source_filter: "all",
        keywords: "PlayStation 5"
      },
      # Portal-specific rule -> ignored for eBay
      %AlertRule{
        is_active: true,
        source_filter: "mydealz",
        keywords: "Nintendo Switch"
      }
    ]

    queries = QueryAggregator.build_queries(rules)

    assert length(queries) == 1
    [query] = queries
    assert query.q == "(RTX 4080, RTX 4090, 7900 XTX)"
    assert query.terms == ["RTX 4080", "RTX 4090", "7900 XTX"]
  end

  test "formats single keyword without parentheses" do
    queries = QueryAggregator.build_queries(["MacBook Air M2"])

    assert length(queries) == 1
    [query] = queries
    assert query.q == "MacBook Air M2"
    assert query.terms == ["MacBook Air M2"]
  end

  test "splits queries across batches when exceeding max_terms_per_batch" do
    keywords = for i <- 1..10, do: "Keyword #{i}"

    queries = QueryAggregator.build_queries(keywords, max_terms_per_batch: 4)

    assert length(queries) == 3
    assert length(Enum.at(queries, 0).terms) == 4
    assert length(Enum.at(queries, 1).terms) == 4
    assert length(Enum.at(queries, 2).terms) == 2
  end
end
