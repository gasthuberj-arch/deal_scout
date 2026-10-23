defmodule DealScout.KeywordEngine.QueryTest do
  use ExUnit.Case, async: true

  alias DealScout.KeywordEngine.Query

  defp matches?(keywords, text) do
    {:ok, query} = Query.parse(keywords)
    Query.matches?(query, text)
  end

  describe "matches?/2" do
    test "implicit AND requires every word" do
      assert matches?("rtx 4080", "Gigabyte RTX 4080 Super")
      refute matches?("rtx 4080", "Gigabyte RTX 4070")
    end

    test "is case-insensitive and normalises whitespace" do
      assert matches?(~s["smart tv"], "LG  SMART\nTV 55 Zoll")
    end

    test "NOT excludes deals containing the negated term" do
      assert matches?("tv NOT refurbished", "Samsung TV new")
      refute matches?("tv NOT refurbished", "Samsung TV refurbished")
      # the word "not" in a deal must not be required
      assert matches?("tv NOT refurbished", "TV, does not include stand")
    end

    test "enforces word boundaries" do
      refute matches?("tv", "TVOC air quality sensor")
      assert matches?("kühler", "Ein leiser Kühler für CPU")
      refute matches?("kühler", "Wasserkühler")
    end

    test "OR, commas and parentheses" do
      assert matches?("(oled, qled) 55", "Sony QLED 55")
      refute matches?("(oled, qled) 55", "Sony LCD 55")
    end
  end

  describe "excluded?/2" do
    test "any comma-separated negative keyword excludes the text" do
      assert Query.excluded?("refurbished, used", "Used iPhone")
      refute Query.excluded?("refurbished, used", "New iPhone")
    end

    test "uses word boundaries" do
      refute Query.excluded?("used", "unused-looking box, brand new")
    end

    test "blank negative keywords never exclude" do
      refute Query.excluded?(nil, "anything")
      refute Query.excluded?("  ", "anything")
    end
  end

  describe "search_terms/1" do
    test "returns positive literals, never negated ones" do
      assert Query.search_terms("(rtx 4080 OR rx 7900) 16gb NOT used") ==
               ["rtx", "4080", "rx", "7900", "16gb"]
    end

    test "keeps phrases intact" do
      assert Query.search_terms(~s["Apple Watch Ultra" GPS]) == ["apple watch ultra", "gps"]
    end

    test "invalid or blank input yields no terms" do
      assert Query.search_terms(nil) == []
      assert Query.search_terms("   ") == []
    end
  end

  describe "fts_query/1" do
    test "builds prefix terms joined by AND" do
      assert Query.fts_query("RTX 4080") == ~s[("rtx"* AND "4080"*)]
    end

    test "builds exact phrases" do
      assert Query.fts_query(~s["Apple Watch"]) == ~s["apple watch"]
    end

    test "supports OR" do
      assert Query.fts_query("OLED OR QLED") == ~s[("oled"* OR "qled"*)]
    end

    test "drops NOT branches from AND" do
      assert Query.fts_query("tv NOT refurbished") == ~s["tv"*]
    end

    test "nil for blank or invalid input" do
      assert Query.fts_query(nil) == nil
      assert Query.fts_query("") == nil
    end
  end
end
