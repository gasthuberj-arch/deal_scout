defmodule DealScout.KeywordEngine.Parser do
  @moduledoc """
  Tokenizes and parses boolean keyword expressions into an AST:
  ("Fernseher" or "SmartTv" or "Smart Tv") and (55 or 65)

  Grammar:
    expr   -> term (OR term)*
    term   -> factor (AND factor)*
    factor -> "(" expr ")" | NOT factor | LITERAL

  Also supports:
  - Implicit AND when multiple literals or grouped expressions appear consecutively
    (e.g., "macbook air" -> {:and, [{:lit, "macbook"}, {:lit, "air"}]})
  - Comma and semicolon as OR delimiters (e.g. "RTX 4080, RX 7900" -> OR)
  - Quoted phrases as single literal tokens (e.g. "Smart Tv")
  - NOT expressions (e.g. NOT refurbished)
  - Rejection of purely negative expressions
  """

  @doc """
  Parses a boolean keyword query string into an AST.
  Enforces:
  - Valid syntax & balance
  - Whitespace normalization
  - Disallows pure negative queries (must have at least one positive match branch)
  """
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

  def parse(_), do: {:error, "Expected binary input"}

  @doc """
  Normalizes typographical / language-specific quotes to standard ASCII `"`.
  """
  def normalize_quotes(str) when is_binary(str) do
    String.replace(str, ["“", "”", "„", "«", "»"], "\"")
  end

  @doc """
  Converts an AST tuple tree to a JSON-serializable map/list structure.
  """
  def to_json({:lit, val}) when is_binary(val), do: %{"type" => "lit", "val" => val}
  def to_json({:not, child}), do: %{"type" => "not", "child" => to_json(child)}

  def to_json({op, children}) when op in [:and, :or] do
    %{"type" => to_string(op), "children" => Enum.map(children, &to_json/1)}
  end

  @doc """
  Converts a JSON map structure back to an AST tuple tree.
  """
  def from_json(%{"type" => "lit", "val" => val}), do: {:lit, val}
  def from_json(%{"type" => "not", "child" => child}), do: {:not, from_json(child)}

  def from_json(%{"type" => "and", "children" => children}),
    do: {:and, Enum.map(children, &from_json/1)}

  def from_json(%{"type" => "or", "children" => children}),
    do: {:or, Enum.map(children, &from_json/1)}

  def from_json(_), do: nil

  @doc """
  Checks if an AST contains at least one positive literal branch.
  """
  def has_positive_branch?({:lit, _}), do: true
  def has_positive_branch?({:not, _}), do: false
  def has_positive_branch?({:or, children}), do: Enum.any?(children, &has_positive_branch?/1)
  def has_positive_branch?({:and, children}), do: Enum.any?(children, &has_positive_branch?/1)
  def has_positive_branch?(_), do: false

  # --- Tokenizer ---
  defp tokenize(str), do: do_tokenize(str, [])

  defp do_tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  # Skip whitespace
  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    do_tokenize(rest, acc)
  end

  defp do_tokenize(<<"(", rest::binary>>, acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize(<<")", rest::binary>>, acc), do: do_tokenize(rest, [:rparen | acc])

  # Comma and semicolon act as OR
  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?,, ?;] do
    do_tokenize(rest, [:or | acc])
  end

  # Pipe/double-pipe as OR
  defp do_tokenize(<<"||", rest::binary>>, acc), do: do_tokenize(rest, [:or | acc])
  defp do_tokenize(<<"|", rest::binary>>, acc), do: do_tokenize(rest, [:or | acc])

  # Ampersand/double-ampersand as AND
  defp do_tokenize(<<"&&", rest::binary>>, acc), do: do_tokenize(rest, [:and | acc])
  defp do_tokenize(<<"&", rest::binary>>, acc), do: do_tokenize(rest, [:and | acc])

  # Quoted phrase
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

  # Unquoted word or operator
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
  # Inserts :and between two value-like tokens: (lit, lit), (lit, lparen), (rparen, lit), (rparen, lparen), (lit, :not), etc.
  defp insert_implicit_ops(tokens) do
    tokens
    |> strip_loose_operators()
    |> do_insert_implicit_and()
  end

  defp strip_loose_operators(tokens) do
    tokens
    # deduplicate duplicate consecutive operators like :or, :or -> :or
    |> Enum.reduce([], fn
      op, [op | rest] when op in [:or, :and] -> [op | rest]
      tok, acc -> [tok | acc]
    end)
    |> Enum.reverse()
    # strip leading / trailing binary ops
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
