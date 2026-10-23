defmodule DealScout.KeywordEngine.Query do
  @moduledoc """
  The single owner of Alert rule keyword semantics (a **Keyword query**).

  Tokenizes and parses boolean keyword expressions:
    ("Fernseher" or "SmartTv" or "Smart Tv") and (55 or 65)

  Grammar:
    expr   -> term (OR term)*
    term   -> factor (AND factor)*
    factor -> "(" expr ")" | NOT factor | LITERAL

  Supports:
  - Implicit AND when multiple literals or grouped expressions appear consecutively
  - Comma and semicolon as OR delimiters
  - Quoted phrases as single literal tokens
  - NOT expressions (while rejecting purely negative expressions)
  - Word-boundary evaluation (handling German UTF-8 umlauts with byte >= 128)
  - Negative keyword exclusion
  - Positive search term extraction and SQLite FTS5 candidate query generation
  """

  @type t :: term()

  @doc """
  Parses a boolean keyword query string into an AST.
  Returns `{:ok, query}` or `{:error, reason}`.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    cleaned_input =
      input
      |> normalize_quotes()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if cleaned_input == "" do
      {:error, "Keywords expression cannot be empty"}
    else
      with {:ok, raw_tokens} <- tokenize(cleaned_input),
           tokens <- insert_implicit_ops(raw_tokens),
           {:ok, ast, []} <- parse_expr(tokens) do
        if has_positive_branch?(ast) do
          {:ok, ast}
        else
          {:error, "Query cannot be purely negative; at least one positive term is required"}
        end
      else
        {:ok, _ast, remaining} -> {:error, "Unexpected tokens: #{inspect(remaining)}"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def parse(_), do: {:error, "Keywords expression cannot be empty"}

  @doc "Normalizes typographical / language-specific quotes to standard ASCII `\"`."
  @spec normalize_quotes(String.t()) :: String.t()
  def normalize_quotes(str) when is_binary(str) do
    String.replace(str, ["“", "”", "„", "«", "»"], "\"")
  end

  @doc "Checks if an AST contains at least one positive literal branch."
  @spec has_positive_branch?(t()) :: boolean()
  def has_positive_branch?({:lit, _}), do: true
  def has_positive_branch?({:not, _}), do: false
  def has_positive_branch?({:or, children}), do: Enum.any?(children, &has_positive_branch?/1)
  def has_positive_branch?({:and, children}), do: Enum.any?(children, &has_positive_branch?/1)
  def has_positive_branch?(_), do: false

  @doc "Returns true when the parsed query matches `text`."
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(query, text) when is_binary(text), do: eval(query, normalize_text(text))

  @doc """
  Returns true when any negative keyword (separated by commas, semicolons,
  newlines or whitespace; quoted phrases stay intact) occurs in `text`.
  """
  @spec excluded?(String.t() | nil, String.t()) :: boolean()
  def excluded?(negative_keywords, text) when is_binary(negative_keywords) do
    case negative_terms(negative_keywords) do
      [] ->
        false

      terms ->
        normalized = normalize_text(text)
        Enum.any?(terms, &literal_present?(normalized, &1))
    end
  end

  def excluded?(_, _text), do: false

  @doc "Distinct positive literals of a keyword expression, in order."
  @spec search_terms(term()) :: [String.t()]
  def search_terms(keywords) do
    case parse(keywords) do
      {:ok, ast} -> ast |> positive_literals() |> Enum.uniq()
      _ -> []
    end
  end

  @doc """
  Builds a SQLite FTS5 MATCH expression that over-approximates the query
  (NOT branches are ignored). Returns nil if no candidate query can be built.
  """
  @spec fts_query(term()) :: String.t() | nil
  def fts_query(keywords) do
    with {:ok, ast} <- parse(keywords) do
      to_fts(ast)
    else
      _ -> nil
    end
  end

  @doc """
  O(1) byte boundary check.
  Only enforces word boundaries if the matched edge of the keyword itself is a word char.
  Handles German UTF-8 umlauts properly by checking byte >= 128.
  """
  @spec valid_boundary?(binary(), non_neg_integer(), pos_integer()) :: boolean()
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

  @doc false
  def word_char?(b) when b >= ?a and b <= ?z, do: true
  def word_char?(b) when b >= ?A and b <= ?Z, do: true
  def word_char?(b) when b >= ?0 and b <= ?9, do: true
  def word_char?(?_), do: true
  def word_char?(b) when b >= 128, do: true
  def word_char?(_), do: false

  # --- Evaluation ---

  defp eval({:lit, lit}, text), do: literal_present?(text, lit)
  defp eval({:not, child}, text), do: not eval(child, text)
  defp eval({:and, children}, text), do: Enum.all?(children, &eval(&1, text))
  defp eval({:or, children}, text), do: Enum.any?(children, &eval(&1, text))

  defp literal_present?(text, lit) do
    text
    |> :binary.matches(lit)
    |> Enum.any?(fn {pos, len} -> valid_boundary?(text, pos, len) end)
  end

  defp normalize_text(text), do: text |> String.replace(~r/\s+/, " ") |> String.downcase()

  defp negative_terms(str) do
    ~r/"([^"]+)"|[^\s,;"]+/
    |> Regex.scan(normalize_quotes(str))
    |> Enum.map(fn
      [_, quoted] -> quoted
      [full] -> full
    end)
    |> Enum.map(&(&1 |> normalize_text() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  # --- Term extraction ---

  defp positive_literals({:lit, lit}), do: [lit]
  defp positive_literals({:not, _}), do: []

  defp positive_literals({op, children}) when op in [:and, :or],
    do: Enum.flat_map(children, &positive_literals/1)

  # --- FTS5 ---

  defp to_fts({:lit, lit}) do
    words =
      lit
      |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
      |> String.split(~r/\s+/, trim: true)

    case words do
      [] -> nil
      [word] -> ~s["#{word}"*]
      many -> ~s["#{Enum.join(many, " ")}"]
    end
  end

  defp to_fts({:not, _}), do: nil

  defp to_fts({:and, children}) do
    case children |> Enum.map(&to_fts/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      [single] -> single
      parts -> "(" <> Enum.join(parts, " AND ") <> ")"
    end
  end

  # An OR branch that cannot be expressed would make the FTS query too narrow.
  defp to_fts({:or, children}) do
    parts = Enum.map(children, &to_fts/1)

    if Enum.any?(parts, &is_nil/1),
      do: nil,
      else: "(" <> Enum.join(parts, " OR ") <> ")"
  end

  # --- Tokenizer ---

  defp tokenize(str), do: do_tokenize(str, [])

  defp do_tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    do_tokenize(rest, acc)
  end

  defp do_tokenize(<<"(", rest::binary>>, acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize(<<")", rest::binary>>, acc), do: do_tokenize(rest, [:rparen | acc])

  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?,, ?;] do
    do_tokenize(rest, [:or | acc])
  end

  defp do_tokenize(<<"||", rest::binary>>, acc), do: do_tokenize(rest, [:or | acc])
  defp do_tokenize(<<"|", rest::binary>>, acc), do: do_tokenize(rest, [:or | acc])

  defp do_tokenize(<<"&&", rest::binary>>, acc), do: do_tokenize(rest, [:and | acc])
  defp do_tokenize(<<"&", rest::binary>>, acc), do: do_tokenize(rest, [:and | acc])

  defp do_tokenize(<<"\"", rest::binary>>, acc) do
    case :binary.split(rest, "\"") do
      [phrase, remaining] ->
        clean =
          phrase
          |> String.replace(~r/\s+/, " ")
          |> String.downcase()
          |> String.trim()

        if clean == "",
          do: {:error, "Empty quotes"},
          else: do_tokenize(remaining, [{:lit, clean} | acc])

      [_] ->
        {:error, "Unclosed quote"}
    end
  end

  defp do_tokenize(str, acc) do
    {word, rest} = take_word(str, "")
    down = String.downcase(word)

    token =
      case down do
        "and" -> :and
        "or" -> :or
        "not" -> :not
        _ -> {:lit, down}
      end

    do_tokenize(rest, [token | acc])
  end

  defp take_word(<<c, rest::binary>>, acc)
       when c not in [?\s, ?\t, ?\n, ?\r, ?(, ?), ?", ?,, ?;, ?|, ?&] do
    take_word(rest, <<acc::binary, c>>)
  end

  defp take_word(rest, acc), do: {acc, rest}

  # --- Implicit AND Insertion & Cleaning ---

  defp insert_implicit_ops(tokens) do
    tokens
    |> strip_loose_operators()
    |> do_insert_implicit_and()
  end

  defp strip_loose_operators(tokens) do
    tokens
    |> Enum.reduce([], fn
      op, [op | rest] when op in [:or, :and] -> [op | rest]
      tok, acc -> [tok | acc]
    end)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in [:or, :and, :rparen]))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in [:or, :and, :lparen]))
    |> Enum.reverse()
  end

  defp do_insert_implicit_and([]), do: []
  defp do_insert_implicit_and([single]), do: [single]

  defp do_insert_implicit_and([first | rest]) do
    insert_loop(first, rest, [])
  end

  defp insert_loop(prev, [], acc), do: Enum.reverse([prev | acc])

  defp insert_loop(prev, [curr | rest], acc) do
    if end_token?(prev) and start_token?(curr) do
      insert_loop(curr, rest, [:and, prev | acc])
    else
      insert_loop(curr, rest, [prev | acc])
    end
  end

  defp end_token?({:lit, _}), do: true
  defp end_token?(:rparen), do: true
  defp end_token?(_), do: false

  defp start_token?({:lit, _}), do: true
  defp start_token?(:lparen), do: true
  defp start_token?(:not), do: true
  defp start_token?(_), do: false

  # --- Recursive Descent Parser ---

  defp parse_expr(tokens) do
    with {:ok, left, rest} <- parse_term(tokens) do
      parse_or_loop(left, rest)
    end
  end

  defp parse_or_loop(left, [:or | rest]) do
    with {:ok, right, rest2} <- parse_term(rest) do
      parse_or_loop(merge_node(:or, left, right), rest2)
    end
  end

  defp parse_or_loop(left, rest), do: {:ok, left, rest}

  defp parse_term(tokens) do
    with {:ok, left, rest} <- parse_factor(tokens) do
      parse_and_loop(left, rest)
    end
  end

  defp parse_and_loop(left, [:and | rest]) do
    with {:ok, right, rest2} <- parse_factor(rest) do
      parse_and_loop(merge_node(:and, left, right), rest2)
    end
  end

  defp parse_and_loop(left, rest), do: {:ok, left, rest}

  defp parse_factor([:not | rest]) do
    with {:ok, child, rest2} <- parse_factor(rest) do
      {:ok, {:not, child}, rest2}
    end
  end

  defp parse_factor([:lparen | rest]) do
    with {:ok, expr, [:rparen | rest2]} <- parse_expr(rest) do
      {:ok, expr, rest2}
    else
      {:ok, _expr, []} -> {:error, "Missing closing parenthesis"}
      {:ok, _expr, [tok | _]} -> {:error, "Expected closing parenthesis, got #{inspect(tok)}"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Missing closing parenthesis"}
    end
  end

  defp parse_factor([{:lit, val} | rest]), do: {:ok, {:lit, val}, rest}
  defp parse_factor([]), do: {:error, "Unexpected end of expression"}
  defp parse_factor([t | _]), do: {:error, "Unexpected token: #{inspect(t)}"}

  defp merge_node(op, {op, list1}, {op, list2}), do: {op, list1 ++ list2}
  defp merge_node(op, {op, list1}, right), do: {op, list1 ++ [right]}
  defp merge_node(op, left, {op, list2}), do: {op, [left | list2]}
  defp merge_node(op, left, right), do: {op, [left, right]}
end
