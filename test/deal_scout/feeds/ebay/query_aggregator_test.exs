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
    assert query.q == "(rtx 4080, rtx 4090, 7900 xtx)"
    assert query.terms == ["rtx 4080", "rtx 4090", "7900 xtx"]
  end

  test "formats single keyword without parentheses" do
    queries = QueryAggregator.build_queries(["MacBook Air M2"])

    assert length(queries) == 1
    [query] = queries
    assert query.q == "macbook air m2"
    assert query.terms == ["macbook air m2"]
  end

  test "splits queries across batches when exceeding max_terms_per_batch" do
    keywords = for i <- 1..10, do: "Keyword #{i}"

    queries = QueryAggregator.build_queries(keywords, max_terms_per_batch: 4)

    assert length(queries) == 3
    assert length(Enum.at(queries, 0).terms) == 4
    assert length(Enum.at(queries, 1).terms) == 4
    assert length(Enum.at(queries, 2).terms) == 2
  end

  test "splits keywords on case-insensitive OR and strips quotes/whitespace" do
    rules = [
      %AlertRule{
        is_active: true,
        source_filter: "all",
        keywords: "Laufschuh or Novablast 6 or evo sl"
      },
      %AlertRule{
        is_active: true,
        source_filter: "all",
        keywords: ~s["Google Pixel" ]
      }
    ]

    [query] = QueryAggregator.build_queries(rules)
    assert query.terms == ["laufschuh", "novablast 6", "evo sl", "google pixel"]
    assert query.q == "(laufschuh, novablast 6, evo sl, google pixel)"
  end
end
