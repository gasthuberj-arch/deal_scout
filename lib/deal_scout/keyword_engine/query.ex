defmodule DealScout.KeywordEngine.Query do
  @moduledoc """
  The single owner of Alert rule keyword semantics (a **Keyword query**).

  Parses the keyword language (see `DealScout.KeywordEngine.Parser`), evaluates
  a parsed query against one piece of text with the same word-boundary rules as
  the compiled Aho-Corasick matcher, evaluates negative keywords, and derives
  search terms / FTS5 queries for historical candidate lookup.
  """

  alias DealScout.KeywordEngine.{Matcher, Parser}

  @type t :: term()

  @doc "Parses a keyword expression. Returns `{:ok, query}` or `{:error, reason}`."
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(keywords) when is_binary(keywords), do: Parser.parse(keywords)
  def parse(_), do: {:error, "Keywords expression cannot be empty"}

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

  # --- Evaluation ---

  defp eval({:lit, lit}, text), do: literal_present?(text, lit)
  defp eval({:not, child}, text), do: not eval(child, text)
  defp eval({:and, children}, text), do: Enum.all?(children, &eval(&1, text))
  defp eval({:or, children}, text), do: Enum.any?(children, &eval(&1, text))

  defp literal_present?(text, lit) do
    text
    |> :binary.matches(lit)
    |> Enum.any?(fn {pos, len} -> Matcher.valid_boundary?(text, pos, len) end)
  end

  defp normalize_text(text), do: text |> String.replace(~r/\s+/, " ") |> String.downcase()

  defp negative_terms(str) do
    ~r/"([^"]+)"|[^\s,;"]+/
    |> Regex.scan(Parser.normalize_quotes(str))
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
end
