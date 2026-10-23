defmodule DealScout.KeywordEngineTest do
  use DealScout.DataCase, async: false

  alias DealScout.KeywordEngine
  alias DealScout.KeywordEngine.{Query, Server}
  alias DealScout.Alerts
  alias DealScout.AccountsFixtures

  describe "KeywordEngine.Query.parse/1" do
    test "parses basic terms, boolean operators, quotes and parentheses" do
      input = ~s|("Fernseher" or "Smart Tv") and (55 or 65)|
      assert {:ok, ast} = Query.parse(input)

      assert {:and,
              [
                {:or, [{:lit, "fernseher"}, {:lit, "smart tv"}]},
                {:or, [{:lit, "55"}, {:lit, "65"}]}
              ]} == ast
    end

    test "handles implicit AND and comma as OR" do
      assert {:ok, {:and, [{:lit, "macbook"}, {:lit, "air"}]}} = Query.parse("MacBook Air")

      assert {:ok, {:or, [{:lit, "rtx 4080"}, {:lit, "rx 7900"}]}} =
               Query.parse("\"RTX 4080\", \"RX 7900\"")
    end

    test "normalizes typographical quotes and consecutive whitespaces" do
      assert {:ok, {:lit, "smart tv"}} = Query.parse("„Smart    Tv“")
    end

    test "rejects unclosed quotes and purely negative queries" do
      assert {:error, "Unclosed quote"} = Query.parse(~s|"open quote|)
      assert {:error, "Missing closing parenthesis"} = Query.parse("(apple or banana")
      assert {:error, msg} = Query.parse("not apple")
      assert msg =~ "purely negative"
    end
  end

  describe "KeywordEngine compilation & batch matching" do
    test "compiles Aho-Corasick state and cost-based inverted index" do
      rules = [
        %{id: 101, user_id: 1, keywords: ~s|("Fernseher" or "Smart Tv") and (55 or 65)|},
        %{id: 102, user_id: 2, keywords: "laptop"},
        %{id: 103, user_id: 3, keywords: "macbook not pro"}
      ]

      state = KeywordEngine.compile(rules)
      assert state.ac_pattern != nil
      assert Map.has_key?(state.rules, 101)
      assert Map.has_key?(state.rules, 102)
      assert Map.has_key?(state.rules, 103)

      # Test boundary matching
      text1 = "LG OLED 65 Zoll Fernseher für 999€"
      matches1 = KeywordEngine.match_single(text1, state)
      assert {101, 1} in matches1

      # Word boundary: "fernsehern" or substrings
      text_substr = "Superlaptop"
      matches_substr = KeywordEngine.match_single(text_substr, state)
      refute {102, 2} in matches_substr

      text_exact = "Ein neuer Laptop im Angebot"
      matches_exact = KeywordEngine.match_single(text_exact, state)
      assert {102, 2} in matches_exact

      # Test NOT branch
      text_mbp = "Apple MacBook Pro M3"
      refute {103, 3} in KeywordEngine.match_single(text_mbp, state)

      text_mba = "Apple MacBook Air M3"
      assert {103, 3} in KeywordEngine.match_single(text_mba, state)
    end

    test "respects German UTF-8 multi-byte characters in boundaries" do
      rules = [%{id: 201, user_id: 1, keywords: "kühler"}]
      state = KeywordEngine.compile(rules)

      # In text with umlauts
      assert [{201, 1}] == KeywordEngine.match_single("Ein leiser Kühler für CPU", state)
      # Word boundary attached to another umlaut/letter
      assert [] == KeywordEngine.match_single("Wasserkühler", state)
    end

    test "prefilter_batch/1 returns compiled rule keywords and candidate rule IDs per item" do
      rules = [%{id: 301, user_id: 1, keywords: "oled"}]
      KeywordEngine.compile_and_store(rules)

      items = [
        %{id: 1, text: "Toller OLED Bildschirm"},
        %{id: 2, text: "Normales IPS Panel"}
      ]

      assert {%{301 => "oled"}, candidates} = KeywordEngine.prefilter_batch(items)
      assert MapSet.member?(candidates[1], 301)
      assert MapSet.size(candidates[2]) == 0
    end
  end

  describe "KeywordEngine.Server & Ecto Integration" do
    test "validates syntax and synchronizes dirty state on rule lifecycle" do
      user = AccountsFixtures.user_fixture()

      # Reject invalid syntax at changeset level
      {:error, changeset} =
        Alerts.create_alert_rule(user, %{
          name: "Invalid Rule",
          keywords: "not valid"
        })

      assert "Query cannot be purely negative; at least one positive term is required" in errors_on(
               changeset
             ).keywords

      # Create alert rule with valid keywords
      {:ok, rule} =
        Alerts.create_alert_rule(user, %{
          name: "TV Hunter",
          keywords: "(\"Fernseher\" or \"Smart Tv\") and (55 or 65)"
        })

      # Trigger ensure_fresh_index to sync into :persistent_term
      :ok = Server.ensure_fresh_index()

      {compiled_rules, _} = KeywordEngine.prefilter_batch([%{id: 1, text: "55 Fernseher"}])
      assert Map.has_key?(compiled_rules, rule.id)

      # Update alert rule
      {:ok, updated_rule} =
        Alerts.update_alert_rule(rule, %{
          keywords: "MacBook Air M3"
        })

      # Re-fresh
      :ok = Server.ensure_fresh_index()

      {compiled_rules2, candidates2} =
        KeywordEngine.prefilter_batch([%{id: 1, text: "Apple MacBook Air M3"}])

      assert compiled_rules2[updated_rule.id] == "MacBook Air M3"
      assert MapSet.member?(candidates2[1], updated_rule.id)

      # Delete alert rule
      {:ok, _deleted} = Alerts.delete_alert_rule(updated_rule)
      :ok = Server.ensure_fresh_index()

      {compiled_rules3, _} =
        KeywordEngine.prefilter_batch([%{id: 1, text: "Apple MacBook Air M3"}])

      refute Map.has_key?(compiled_rules3, rule.id)
    end
  end
end
