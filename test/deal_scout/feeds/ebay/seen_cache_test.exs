defmodule DealScout.Feeds.Ebay.SeenCacheTest do
  use ExUnit.Case, async: false

  alias DealScout.Feeds.Ebay.SeenCache

  setup do
    SeenCache.clear()
    :ok
  end

  test "seen?/1 returns false initially and true after put/1" do
    refute SeenCache.seen?("item-1")
    assert SeenCache.put("item-1") == :ok
    assert SeenCache.seen?("item-1")
    refute SeenCache.seen?("item-2")
  end

  test "put_all/1 inserts a batch of item IDs" do
    SeenCache.put_all(["item-a", "item-b", "item-c"])
    assert SeenCache.seen?("item-a")
    assert SeenCache.seen?("item-b")
    assert SeenCache.seen?("item-c")
    assert SeenCache.size() == 3
  end

  test "filter_unseen/1 filters out already seen items" do
    items = [
      %{guid: "ebay-101", title: "Item 1"},
      %{guid: "ebay-102", title: "Item 2"},
      %{guid: "ebay-103", title: "Item 3"}
    ]

    SeenCache.put("ebay-102")

    unseen = SeenCache.filter_unseen(items)
    assert length(unseen) == 2
    assert Enum.map(unseen, & &1.guid) == ["ebay-101", "ebay-103"]
  end

  test "prune/1 removes oldest items when capacity is exceeded" do
    # Insert with simulated timestamps
    ensure_table = fn ->
      case :ets.info(:seen_ebay_items) do
        :undefined -> :ets.new(:seen_ebay_items, [:set, :public, :named_table])
        _ -> :seen_ebay_items
      end
    end

    ensure_table.()
    :ets.insert(:seen_ebay_items, {"item-old-1", 100})
    :ets.insert(:seen_ebay_items, {"item-old-2", 200})
    :ets.insert(:seen_ebay_items, {"item-new-1", 500})
    :ets.insert(:seen_ebay_items, {"item-new-2", 600})

    assert SeenCache.size() == 4
    assert {:ok, 2} = SeenCache.prune(2)
    assert SeenCache.size() == 2

    # Old items should be gone, newer items preserved
    refute SeenCache.seen?("item-old-1")
    refute SeenCache.seen?("item-old-2")
    assert SeenCache.seen?("item-new-1")
    assert SeenCache.seen?("item-new-2")
  end
end
