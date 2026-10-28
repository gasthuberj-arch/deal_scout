defmodule DealScout.Feeds.Ebay.QueryAggregator do
  @moduledoc """
  Aggregates and clusters keywords from active user alert rules into optimal eBay queries.

  Uses eBay Browse API boolean syntax: `q=(Term 1, Term 2, Term 3)` to minimize API request
  consumption while maximizing alert coverage.
  """

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule

  @max_query_chars 300
  @max_terms_per_batch 8

  @doc """
  Fetches active alert rules eligible for eBay and constructs query batches.
  """
  def list_active_queries(opts \\ []) do
    rules = Alerts.list_active_rules()
    build_queries(rules, opts)
  end

  @doc """
  Builds batched search queries from a list of `AlertRule` structs or raw keyword strings.
  """
  def build_queries(rules_or_keywords, opts \\ [])

  def build_queries([], _opts), do: []

  def build_queries([%AlertRule{} | _] = rules, opts) do
    keywords = extract_keywords_from_rules(rules)
    batch_keywords(keywords, opts)
  end

  def build_queries(keywords, opts) when is_list(keywords) do
    cleaned =
      keywords
      |> Enum.flat_map(&parse_keyword_string/1)
      |> deduplicate_keywords()

    batch_keywords(cleaned, opts)
  end

  @doc """
  Extracts unique keyword phrases from alert rules that are eligible for eBay.
  Rules qualify if `source_filter` is `nil`, `"all"`, or `"ebay"`.
  """
  def extract_keywords_from_rules(rules) when is_list(rules) do
    rules
    |> Enum.filter(&ebay_eligible_rule?/1)
    |> Enum.flat_map(fn rule ->
      parse_keyword_string(rule.keywords)
    end)
    |> deduplicate_keywords()
  end

  defp ebay_eligible_rule?(%AlertRule{is_active: false}), do: false

  defp ebay_eligible_rule?(%AlertRule{source_filter: filter}) do
    is_nil(filter) or filter in ["", "all", "ebay"]
  end

  defp parse_keyword_string(nil), do: []

  defp parse_keyword_string(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp deduplicate_keywords(keywords) do
    keywords
    |> Enum.reduce({[], MapSet.new()}, fn term, {acc, seen} ->
      normalized = String.downcase(term)

      if MapSet.member?(seen, normalized) do
        {acc, seen}
      else
        {[term | acc], MapSet.put(seen, normalized)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp batch_keywords([], _opts), do: []

  defp batch_keywords(keywords, opts) do
    max_terms = Keyword.get(opts, :max_terms_per_batch, @max_terms_per_batch)
    max_chars = Keyword.get(opts, :max_query_chars, @max_query_chars)

    keywords
    |> Enum.chunk_while(
      {[], 0},
      fn term, {current_batch, current_len} ->
        # Format term without quotes if already alphanumeric or clean
        additional_len = String.length(term) + 2

        if length(current_batch) >= max_terms or
             (current_len + additional_len > max_chars and current_batch != []) do
          {:cont, Enum.reverse(current_batch), {[term], additional_len}}
        else
          {:cont, {[term | current_batch], current_len + additional_len}}
        end
      end,
      fn
        {[], _} -> {:cont, []}
        {batch, _} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&format_query_batch/1)
  end

  defp format_query_batch([single_term]) do
    %{
      q: single_term,
      terms: [single_term]
    }
  end

  defp format_query_batch(terms) when is_list(terms) do
    joined = Enum.join(terms, ", ")

    %{
      q: "(#{joined})",
      terms: terms
    }
  end
end
