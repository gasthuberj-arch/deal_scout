defmodule DealScout.Alerts.Evaluation do
  @moduledoc """
  Pure **Match evaluation** module shared by live ingestion and Backtest.

  Given preloaded `Deal` structs and `AlertRule` structs, enriches deals with
  cross-border metadata, optionally prefilters via the compiled Aho-Corasick
  index (`DealScout.KeywordEngine.Matcher`) ONLY for rules known to be in the
  compiled state, and falls back to `DealScout.Alerts.Matcher.matches?/2` for
  uncompiled or draft rules.
  """

  alias DealScout.Alerts.{AlertRule, Matcher}
  alias DealScout.Deals.{CrossBorderGuard, Deal}
  alias DealScout.KeywordEngine

  @type prepared_batch :: %{
          deals: [Deal.t()],
          prefilter?: boolean(),
          compiled_rules: %{optional(any()) => String.t() | nil},
          candidates_by_deal_id: %{optional(any()) => MapSet.t()}
        }

  @doc """
  Enriches deals and runs the single-pass compiled Aho-Corasick scan once for
  the batch (unless `prefilter: false` is passed, e.g. for draft rules in Backtest).
  """
  @spec prepare([Deal.t()], keyword()) :: prepared_batch()
  def prepare(deals, opts \\ []) when is_list(deals) do
    prefilter? = Keyword.get(opts, :prefilter, true)
    enriched_deals = Enum.map(deals, &CrossBorderGuard.enrich/1)

    {compiled_rules, candidates_by_deal_id} =
      if prefilter? do
        build_prefilter(enriched_deals)
      else
        {%{}, %{}}
      end

    %{
      deals: enriched_deals,
      prefilter?: prefilter?,
      compiled_rules: compiled_rules,
      candidates_by_deal_id: candidates_by_deal_id
    }
  end

  @doc """
  Evaluates a single `AlertRule` against a prepared batch of deals, returning
  the matching enriched deals in batch order.
  """
  @spec evaluate(prepared_batch(), AlertRule.t()) :: [Deal.t()]
  def evaluate(
        %{
          deals: deals,
          prefilter?: prefilter?,
          compiled_rules: compiled_rules,
          candidates_by_deal_id: candidates_by_deal_id
        },
        %AlertRule{} = rule
      ) do
    compiled? =
      case Map.fetch(compiled_rules, rule.id) do
        {:ok, compiled_keywords} when prefilter? and not is_nil(rule.id) ->
          is_nil(compiled_keywords) or compiled_keywords == rule.keywords

        _ ->
          false
      end

    Enum.filter(deals, fn deal ->
      if compiled? do
        candidate_ids = Map.get(candidates_by_deal_id, deal.id, MapSet.new())

        MapSet.member?(candidate_ids, rule.id) and
          Matcher.matches_filters?(deal, rule) and
          Matcher.not_excluded?(deal, rule.negative_keywords)
      else
        Matcher.matches?(deal, rule)
      end
    end)
  end

  @doc """
  Evaluates `rules` against `deals`, returning `[{rule, matching_deals}, ...]`
  for every rule that matched at least one deal.
  """
  @spec match([AlertRule.t()], [Deal.t()], keyword()) :: [{AlertRule.t(), [Deal.t()]}]
  def match(rules, deals, opts \\ []) when is_list(rules) and is_list(deals) do
    batch = prepare(deals, opts)

    for rule <- rules,
        matched = evaluate(batch, rule),
        matched != [] do
      {rule, matched}
    end
  end

  defp build_prefilter(deals) do
    case KeywordEngine.Matcher.get_state() do
      %{rules: rules, ac_pattern: ac_pattern} when is_map(rules) and not is_nil(ac_pattern) ->
        compiled_rules =
          Map.new(rules, fn
            {rule_id, {_user_id, _ast, keywords}} -> {rule_id, keywords}
            {rule_id, {_user_id, _ast}} -> {rule_id, nil}
          end)

        deal_items =
          Enum.map(deals, fn d -> %{id: d.id, text: Matcher.searchable_text(d)} end)

        batch_matches = KeywordEngine.Matcher.match_batch(deal_items)

        candidates_by_deal_id =
          Enum.reduce(batch_matches, %{}, fn {deal_id, rule_user_pairs}, acc ->
            rule_ids = MapSet.new(Enum.map(rule_user_pairs, &elem(&1, 0)))
            Map.put(acc, deal_id, rule_ids)
          end)

        {compiled_rules, candidates_by_deal_id}

      _ ->
        {%{}, %{}}
    end
  end
end
