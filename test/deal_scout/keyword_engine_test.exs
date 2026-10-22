defmodule DealScout.KeywordEngineTest do
  use DealScout.DataCase, async: false

  alias DealScout.KeywordEngine.{Parser, Compiler, Matcher, Server}
  alias DealScout.Alerts
  alias DealScout.AccountsFixtures

  describe "KeywordEngine.Parser" do
    test "parses basic terms, boolean operators, quotes and parentheses" do
      input = ~s|("Fernseher" or "Smart Tv") and (55 or 65)|
      assert {:ok, ast} = Parser.parse(input)

      assert {:and,
              [
                {:or, [{:lit, "fernseher"}, {:lit, "smart tv"}]},
                {:or, [{:lit, "55"}, {:lit, "65"}]}
              ]} == ast
    end

    test "handles implicit AND and comma as OR" do
      assert {:ok, {:and, [{:lit, "macbook"}, {:lit, "air"}]}} = Parser.parse("MacBook Air")

      assert {:ok, {:or, [{:lit, "rtx 4080"}, {:lit, "rx 7900"}]}} =
               Parser.parse("\"RTX 4080\", \"RX 7900\"")
    end

    test "normalizes typographical quotes and consecutive whitespaces" do
      assert {:ok, {:lit, "smart tv"}} = Parser.parse("„Smart    Tv“")
    end

    test "rejects unclosed quotes and purely negative queries" do
      assert {:error, "Unclosed quote"} = Parser.parse(~s|"open quote|)
      assert {:error, "Missing closing parenthesis"} = Parser.parse("(apple or banana")
      assert {:error, msg} = Parser.parse("not apple")
      assert msg =~ "purely negative"
    end

    test "serializes to and from json format" do
      {:ok, ast} = Parser.parse(~s|("OLED" and 65) or not 55|)
      json = Parser.to_json(ast)
      assert is_map(json)
      assert Parser.from_json(json) == ast
    end
  end

  describe "KeywordEngine.Compiler & Matcher" do
    test "compiles Aho-Corasick state and cost-based inverted index" do
      rules = [
        {101, 1,
         {:and,
          [{:or, [{:lit, "fernseher"}, {:lit, "smart tv"}]}, {:or, [{:lit, "55"}, {:lit, "65"}]}]}},
        {102, 2, {:lit, "laptop"}},
        {103, 3, {:and, [{:lit, "macbook"}, {:not, {:lit, "pro"}}]}}
      ]

      state = Compiler.compile(rules)
      assert state.ac_pattern != nil
      assert Map.has_key?(state.rules, 101)
      assert Map.has_key?(state.rules, 102)
      assert Map.has_key?(state.rules, 103)

      # Test boundary matching
      text1 = "LG OLED 65 Zoll Fernseher für 999€"
      matches1 = Matcher.match_single(text1, state)
      assert {101, 1} in matches1

      # Word boundary: "fernsehern" or substrings
      text_substr = "Superlaptop"
      matches_substr = Matcher.match_single(text_substr, state)
      refute {102, 2} in matches_substr

      text_exact = "Ein neuer Laptop im Angebot"
      matches_exact = Matcher.match_single(text_exact, state)
      assert {102, 2} in matches_exact

      # Test NOT branch
      text_mbp = "Apple MacBook Pro M3"
      refute {103, 3} in Matcher.match_single(text_mbp, state)

      text_mba = "Apple MacBook Air M3"
      assert {103, 3} in Matcher.match_single(text_mba, state)
    end

    test "respects German UTF-8 multi-byte characters in boundaries" do
      rules = [{201, 1, {:lit, "kühler"}}]
      state = Compiler.compile(rules)

      # In text with umlauts
      assert [{201, 1}] == Matcher.match_single("Ein leiser Kühler für CPU", state)
      # Word boundary attached to another umlaut/letter
      assert [] == Matcher.match_single("Wasserkühler", state)
    end

    test "batch matching returns item IDs with matched rules" do
      rules = [{301, 1, {:lit, "oled"}}]
      state = Compiler.compile(rules)
      Matcher.put_state(state)

      items = [
        %{id: 1, text: "Toller OLED Bildschirm"},
        %{id: 2, text: "Normales IPS Panel"}
      ]

      assert [{1, [{301, 1}]}, {2, []}] == Matcher.match_batch(items)
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

      state = Matcher.get_state()
      assert Map.has_key?(state.rules, rule.id)

      # Update alert rule
      {:ok, updated_rule} =
        Alerts.update_alert_rule(rule, %{
          keywords: "MacBook Air M3"
        })

      # Re-fresh
      :ok = Server.ensure_fresh_index()
      state2 = Matcher.get_state()
      {_user_id, ast} = Map.fetch!(state2.rules, updated_rule.id)
      assert match?({:and, _}, ast)

      # Delete alert rule
      {:ok, _deleted} = Alerts.delete_alert_rule(updated_rule)
      :ok = Server.ensure_fresh_index()
      state3 = Matcher.get_state()
      refute Map.has_key?(state3.rules, rule.id)
    end
  end
end
