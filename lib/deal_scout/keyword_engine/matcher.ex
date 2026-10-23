defmodule DealScout.KeywordEngine.Matcher do
  @moduledoc """
  Executes the single-pass scan, enforces word boundaries (handling German UTF-8
  umlauts properly by checking byte >= 128), and evaluates triggered ASTs.
  """

  @persistent_key :deal_scout_keyword_engine_state

  def put_state(state), do: :persistent_term.put(@persistent_key, state)
  def get_state(), do: :persistent_term.get(@persistent_key, nil)

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
  Matches a single text string against compiled rules state.
  Returns: `[{rule_id, user_id}, ...]`
  """
  def match_single(raw_text, state) when is_binary(raw_text) do
    text =
      raw_text
      |> String.replace(~r/\s+/, " ")
      |> String.downcase()

    if state == nil or state.ac_pattern == nil do
      []
    else
      # Phase 1: Single-pass C-level Aho-Corasick + O(1) byte boundary check
      matched_term_ids =
        for {pos, len} <- :binary.matches(text, state.ac_pattern),
            valid_boundary?(text, pos, len),
            into: MapSet.new() do
          matched_str = :binary.part(text, pos, len)
          Map.fetch!(state.term_to_id, matched_str)
        end

      if MapSet.size(matched_term_ids) == 0 do
        []
      else
        # Phase 2: Candidate lookup via Pruned Inverted Index
        candidate_rule_ids =
          Enum.reduce(matched_term_ids, MapSet.new(), fn term_id, acc ->
            case Map.get(state.inverted_index, term_id) do
              nil -> acc
              rule_ids -> Enum.reduce(rule_ids, acc, &MapSet.put(&2, &1))
            end
          end)

        # Phase 3: Evaluate AST for candidates
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

  # --- AST Evaluator ---
  defp eval_ast({:lit, term_id, _len}, matched_set), do: MapSet.member?(matched_set, term_id)
  defp eval_ast({:not, child}, matched_set), do: not eval_ast(child, matched_set)

  defp eval_ast({:and, children}, matched_set),
    do: Enum.all?(children, &eval_ast(&1, matched_set))

  defp eval_ast({:or, children}, matched_set), do: Enum.any?(children, &eval_ast(&1, matched_set))

  # --- O(1) Byte Boundary Check ---
  # Only enforce word boundaries if the matched edge of the keyword itself is a word char.
  # Example: If keyword is "c++", the '+' is not a word char, so we don't require a non-word char after it.
  def valid_boundary?(text, pos, len) do
    first_kw_byte = :binary.at(text, pos)
    last_kw_byte = :binary.at(text, pos + len - 1)

    before_ok =
      if pos == 0 or not word_char?(first_kw_byte) do
        true
      else
        not word_char?(:binary.at(text, pos - 1))
      end

    after_ok =
      if pos + len == byte_size(text) or not word_char?(last_kw_byte) do
        true
      else
        not word_char?(:binary.at(text, pos + len))
      end

    before_ok and after_ok
  end

  def word_char?(b) when b >= ?a and b <= ?z, do: true
  def word_char?(b) when b >= ?A and b <= ?Z, do: true
  def word_char?(b) when b >= ?0 and b <= ?9, do: true
  def word_char?(?_), do: true
  def word_char?(b) when b >= 128, do: true
  def word_char?(_), do: false
end
