defmodule DealScout.Alerts.EvaluationTest do
  # KeywordEngine compiled state lives in :persistent_term (global)
  use ExUnit.Case, async: false

  alias DealScout.Alerts.{AlertRule, Evaluation}
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.KeywordEngine

  setup do
    previous = KeywordEngine.get_state()
    on_exit(fn -> KeywordEngine.put_state(previous) end)
    KeywordEngine.put_state(nil)

    feed = %Feed{id: 1, slug: "mydealz", name: "MyDealz"}
    merchant = %Merchant{id: 1, name: "Mindfactory", slug: "mindfactory", trust_level: "verified"}

    deal = fn id, title ->
      %Deal{
        id: id,
        feed_id: 1,
        feed: feed,
        merchant: merchant,
        title: title,
        price: Decimal.new("500.00"),
        temperature: 100
      }
    end

    %{deal: deal}
  end

  defp compile!(rules) do
    KeywordEngine.compile_and_store(rules)
  end

  defp ids(deals), do: deals |> Enum.map(& &1.id) |> Enum.sort()

  test "matches keywords, filters and negative keywords together", %{deal: deal} do
    deals = [
      deal.(1, "Samsung TV 55"),
      deal.(2, "Samsung TV 55 refurbished"),
      deal.(3, "Samsung TVOC sensor")
    ]

    rule = %AlertRule{id: 10, user_id: 1, keywords: "tv", negative_keywords: "refurbished"}

    assert [{^rule, matched}] = Evaluation.match([rule], deals)
    assert ids(matched) == [1]
  end

  test "NOT in keywords behaves the same with and without the compiled index", %{deal: deal} do
    deals = [deal.(1, "Samsung TV new"), deal.(2, "Samsung TV refurbished")]
    rule = %AlertRule{id: 10, user_id: 1, keywords: "tv NOT refurbished"}

    [{_, uncompiled}] = Evaluation.match([rule], deals)
    compile!([rule])
    [{_, compiled}] = Evaluation.match([rule], deals)

    assert ids(uncompiled) == [1]
    assert ids(compiled) == [1]
  end

  test "a rule missing from the compiled index still matches when another rule triggered",
       %{deal: deal} do
    compiled_rule = %AlertRule{id: 10, user_id: 1, keywords: "samsung"}
    new_rule = %AlertRule{id: 11, user_id: 1, keywords: "tv"}
    compile!([compiled_rule])

    result = Evaluation.match([compiled_rule, new_rule], [deal.(1, "Samsung TV 55")])

    assert {new_rule, [1]} in Enum.map(result, fn {r, ds} -> {r, ids(ds)} end)
  end

  test "prefilter: false ignores the compiled index (draft rules)", %{deal: deal} do
    saved = %AlertRule{id: 10, user_id: 1, keywords: "samsung"}
    compile!([saved])
    draft = %{saved | keywords: "lg"}

    assert [{_, [%Deal{id: 1}]}] =
             Evaluation.match([draft], [deal.(1, "LG OLED")], prefilter: false)
  end

  test "evaluate/2 applies non-keyword filters", %{deal: deal} do
    batch = Evaluation.prepare([deal.(1, "Samsung TV")])
    cheap = %AlertRule{id: 10, user_id: 1, keywords: "tv", max_price: Decimal.new("100")}
    any = %AlertRule{id: 11, user_id: 1, keywords: "tv"}

    assert Evaluation.evaluate(batch, cheap) == []
    assert ids(Evaluation.evaluate(batch, any)) == [1]
  end
end
