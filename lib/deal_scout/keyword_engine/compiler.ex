defmodule DealScout.KeywordEngine.Compiler do
  @moduledoc """
  Compiles parsed ASTs into a single flat Aho-Corasick state machine
  and a cost-pruned inverted index.
  """

  @doc """
  Takes a list of `{rule_id, user_id, ast}` tuples, deduplicates all string literals
  into integer IDs, compiles the :binary Aho-Corasick pattern, and builds the pruned inverted index.
  """
  def compile(rules_list) do
    # 1. Extract all unique string literals across all rules
    unique_terms =
      rules_list
      |> Enum.flat_map(fn {_rule_id, _user_id, ast} -> extract_literals(ast) end)
      |> Enum.uniq()

    # 2. Assign integer IDs (0..K)
    term_to_id =
      unique_terms
      |> Enum.with_index()
      |> Map.new()

    # 3. Compile Erlang C-level Aho-Corasick automaton
    ac_pattern =
      if unique_terms == [] do
        nil
      else
        :binary.compile_pattern(unique_terms)
      end

    # 4. Convert string ASTs to integer ID ASTs and build pruned inverted index
    {compiled_rules, inverted_index} =
      Enum.reduce(rules_list, {%{}, %{}}, fn {rule_id, user_id, ast}, {rules_acc, idx_acc} ->
        int_ast = map_ast_to_ids(ast, term_to_id)
        trigger_ids = select_triggers(int_ast, term_to_id)

        new_rules_acc = Map.put(rules_acc, rule_id, {user_id, int_ast})

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

  def extract_literals({:lit, str}), do: [str]
  def extract_literals({:not, child}), do: extract_literals(child)

  def extract_literals({op, children}) when op in [:and, :or] do
    Enum.flat_map(children, &extract_literals/1)
  end

  defp map_ast_to_ids({:lit, str}, map), do: {:lit, Map.fetch!(map, str), byte_size(str)}
  defp map_ast_to_ids({:not, child}, map), do: {:not, map_ast_to_ids(child, map)}

  defp map_ast_to_ids({op, children}, map) when op in [:and, :or] do
    {op, Enum.map(children, &map_ast_to_ids(&1, map))}
  end

  # --- Cost-Based AND Pruning ---
  # Returns the minimal list of term_ids required to trigger evaluation of this AST.
  # For AND nodes, we pick the child branch with the highest minimum string length
  # (so "fernseher" is chosen as the trigger instead of "55").
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

  # Specificity score = shortest literal inside the branch.
  # Longer strings appear less frequently in random text.
  defp branch_specificity_score({:lit, _id, len}), do: len
  defp branch_specificity_score({:not, _}), do: 0

  defp branch_specificity_score({:or, children}) do
    children |> Enum.map(&branch_specificity_score/1) |> Enum.min(fn -> 0 end)
  end

  defp branch_specificity_score({:and, children}) do
    children |> Enum.map(&branch_specificity_score/1) |> Enum.max(fn -> 0 end)
  end
end
