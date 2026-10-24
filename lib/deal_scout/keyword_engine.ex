defmodule DealScout.KeywordEngine do
  @moduledoc """
  The **Compiled keyword index** module for DealScout.

  Compiles active `AlertRule` expressions (parsed via `DealScout.KeywordEngine.Query`)
  into a single flat Erlang `:binary` Aho-Corasick automaton and a cost-pruned
  inverted index stored in `:persistent_term`.

  Exposes a high-level prefilter interface (`prefilter_batch/1`) so callers
  such as `DealScout.Alerts.Matcher` never inspect internal tuple shapes or
  `:persistent_term` keys.
  """

  alias DealScout.KeywordEngine.{Query, Server}

  @persistent_key :deal_scout_keyword_engine_state

  @type compiled_index :: %{
          ac_pattern: :binary.cp() | nil,
          term_to_id: %{String.t() => non_neg_integer()},
          rules: %{any() => {any(), term(), String.t() | nil}},
          inverted_index: %{non_neg_integer() => [any()]}
        }

  defdelegate mark_dirty(), to: Server
  defdelegate ensure_fresh_index(), to: Server
  defdelegate force_rebuild(), to: Server

  @doc "Stores the compiled index in `:persistent_term`."
  @spec put_state(compiled_index() | nil) :: :ok
  def put_state(state), do: :persistent_term.put(@persistent_key, state)

  @doc "Retrieves the current compiled index from `:persistent_term`."
  @spec get_state() :: compiled_index() | nil
  def get_state, do: :persistent_term.get(@persistent_key, nil)

  @doc """
  Compiles a list of `AlertRule`-like maps/structs (`%{id, user_id, keywords}`)
  or pre-parsed `{rule_id, user_id, ast}` / `{rule_id, user_id, ast, keywords}` tuples
  into a compiled index and stores it in `:persistent_term`.
  """
  @spec compile_and_store([term()]) :: compiled_index()
  def compile_and_store(rules_list) when is_list(rules_list) do
    state = compile(rules_list)
    put_state(state)
    state
  end

  @doc """
  Compiles a list of `AlertRule`-like maps/structs or `{rule_id, user_id, ast[, keywords]}`
  tuples into a flat Aho-Corasick state machine and a cost-pruned inverted index.
  """
  @spec compile([term()]) :: compiled_index()
  def compile(rules_list) when is_list(rules_list) do
    normalized_rules = normalize_rules_input(rules_list)

    unique_terms =
      normalized_rules
      |> Enum.flat_map(fn {_rule_id, _user_id, ast, _keywords} -> extract_literals(ast) end)
      |> Enum.uniq()

    term_to_id =
      unique_terms
      |> Enum.with_index()
      |> Map.new()

    ac_pattern =
      if unique_terms == [] do
        nil
      else
        :binary.compile_pattern(unique_terms)
      end

    {compiled_rules, inverted_index} =
      Enum.reduce(normalized_rules, {%{}, %{}}, fn {rule_id, user_id, ast, keywords},
                                                   {rules_acc, idx_acc} ->
        int_ast = map_ast_to_ids(ast, term_to_id)
        trigger_ids = select_triggers(int_ast, term_to_id)

        new_rules_acc = Map.put(rules_acc, rule_id, {user_id, int_ast, keywords})

        new_idx_acc =
          Enum.reduce(trigger_ids, idx_acc, fn term_id, acc ->
            Map.update(acc, term_id, [rule_id], &[rule_id | &1])
          end)

        {new_rules_acc, new_idx_acc}
      end)

    %{
      ac_pattern: ac_pattern,
      term_to_id: term_to_id,
      rules: compiled_rules,
      inverted_index: inverted_index
    }
  end

  @doc """
  Runs a single-pass Aho-Corasick prefilter scan across `items` (`[%{id: id, text: text}, ...]`)
  using the active `:persistent_term` index.

  Returns `{compiled_rules_keywords_by_id, candidate_rule_ids_by_item_id}` where:
  - `compiled_rules_keywords_by_id` is `%{rule_id => compiled_keywords_or_nil}`
  - `candidate_rule_ids_by_item_id` is `%{item_id => MapSet.t(rule_id)}`
  """
  @spec prefilter_batch([%{id: any(), text: String.t()}]) ::
          {%{optional(any()) => String.t() | nil}, %{optional(any()) => MapSet.t()}}
  def prefilter_batch(items) when is_list(items) do
    case get_state() do
      %{rules: rules, ac_pattern: ac_pattern} = state
      when is_map(rules) and not is_nil(ac_pattern) ->
        compiled_rules =
          Map.new(rules, fn
            {rule_id, {_user_id, _ast, keywords}} -> {rule_id, keywords}
            {rule_id, {_user_id, _ast}} -> {rule_id, nil}
          end)

        candidates_by_item_id =
          Map.new(items, fn %{id: item_id, text: text} ->
            rule_ids =
              text
              |> match_single(state)
              |> MapSet.new(&elem(&1, 0))

            {item_id, rule_ids}
          end)

        {compiled_rules, candidates_by_item_id}

      _ ->
        {%{}, %{}}
    end
  end

  @doc """
  Takes a batch of items: `[%{id: item_id, text: "title + description"}, ...]`
  Returns: `[{item_id, [{rule_id, user_id}, ...]}, ...]`
  """
  def match_batch(items) when is_list(items) do
    case get_state() do
      nil ->
        Enum.map(items, fn item -> {item.id, []} end)

      %{ac_pattern: nil} ->
        Enum.map(items, fn item -> {item.id, []} end)

      state ->
        Enum.map(items, fn item ->
          matches = match_single(item.text, state)
          {item.id, matches}
        end)
    end
  end

  @doc """
  Matches a single text string against a compiled index state.
  Returns: `[{rule_id, user_id}, ...]`
  """
  def match_single(raw_text, state \\ get_state()) when is_binary(raw_text) do
    text =
      raw_text
      |> String.replace(~r/\s+/, " ")
      |> String.downcase()

    if state == nil or state.ac_pattern == nil do
      []
    else
      matched_term_ids =
        for {pos, len} <- :binary.matches(text, state.ac_pattern),
            Query.valid_boundary?(text, pos, len),
            into: MapSet.new() do
          matched_str = :binary.part(text, pos, len)
          Map.fetch!(state.term_to_id, matched_str)
        end

      if MapSet.size(matched_term_ids) == 0 do
        []
      else
        candidate_rule_ids =
          Enum.reduce(matched_term_ids, MapSet.new(), fn term_id, acc ->
            case Map.get(state.inverted_index, term_id) do
              nil -> acc
              rule_ids -> Enum.reduce(rule_ids, acc, &MapSet.put(&2, &1))
            end
          end)

        Enum.reduce(candidate_rule_ids, [], fn rule_id, acc ->
          case Map.get(state.rules, rule_id) do
            {user_id, ast} ->
              if eval_ast(ast, matched_term_ids), do: [{rule_id, user_id} | acc], else: acc

            {user_id, ast, _keywords} ->
              if eval_ast(ast, matched_term_ids), do: [{rule_id, user_id} | acc], else: acc

            _ ->
              acc
          end
        end)
      end
    end
  end

  # --- Internal Helpers ---

  defp normalize_rules_input(rules_list) do
    Enum.flat_map(rules_list, fn
      {rule_id, user_id, ast, keywords} ->
        [{rule_id, user_id, ast, keywords}]

      {rule_id, user_id, ast} ->
        [{rule_id, user_id, ast, nil}]

      %{id: rule_id, user_id: user_id, keywords: keywords} ->
        case Query.parse(keywords || "") do
          {:ok, ast} -> [{rule_id, user_id, ast, keywords}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp extract_literals({:lit, str}), do: [str]
  defp extract_literals({:not, child}), do: extract_literals(child)

  defp extract_literals({op, children}) when op in [:and, :or] do
    Enum.flat_map(children, &extract_literals/1)
  end

  defp map_ast_to_ids({:lit, str}, map), do: {:lit, Map.fetch!(map, str), byte_size(str)}
  defp map_ast_to_ids({:not, child}, map), do: {:not, map_ast_to_ids(child, map)}

  defp map_ast_to_ids({op, children}, map) when op in [:and, :or] do
    {op, Enum.map(children, &map_ast_to_ids(&1, map))}
  end

  defp select_triggers({:lit, id, _len}, _map), do: [id]
  defp select_triggers({:not, _child}, _map), do: []

  defp select_triggers({:or, children}, map) do
    Enum.flat_map(children, &select_triggers(&1, map)) |> Enum.uniq()
  end

  defp select_triggers({:and, children}, map) do
    positive_children = Enum.reject(children, &match?({:not, _}, &1))

    case positive_children do
      [] ->
        []

      list ->
        best_child = Enum.max_by(list, &branch_specificity_score/1)
        select_triggers(best_child, map)
    end
  end

  defp branch_specificity_score({:lit, _id, len}), do: len
  defp branch_specificity_score({:not, _}), do: 0

  defp branch_specificity_score({:or, children}) do
    children |> Enum.map(&branch_specificity_score/1) |> Enum.min(fn -> 0 end)
  end

  defp branch_specificity_score({:and, children}) do
    children |> Enum.map(&branch_specificity_score/1) |> Enum.max(fn -> 0 end)
  end

  defp eval_ast({:lit, term_id, _len}, matched_set), do: MapSet.member?(matched_set, term_id)
  defp eval_ast({:not, child}, matched_set), do: not eval_ast(child, matched_set)

  defp eval_ast({:and, children}, matched_set),
    do: Enum.all?(children, &eval_ast(&1, matched_set))

  defp eval_ast({:or, children}, matched_set), do: Enum.any?(children, &eval_ast(&1, matched_set))
end
