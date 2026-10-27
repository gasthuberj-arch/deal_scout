defmodule DealScout.Deals.ImageCacheTest do
  use ExUnit.Case, async: false

  alias DealScout.Deals.ImageCache

  setup do
    ImageCache.clear()
    :ok
  end

  describe "ImageCache" do
    test "stores and retrieves images within size limit" do
      payload = "fake-jpeg-data"
      assert :ok = ImageCache.put(1, "image/jpeg", payload)
      assert {:ok, "image/jpeg", ^payload} = ImageCache.get(1)
      assert {:ok, "image/jpeg", ^payload} = ImageCache.get("1")
    end

    test "returns :miss on nonexistent key" do
      assert :miss = ImageCache.get(999_999)
      assert :miss = ImageCache.get("invalid")
    end

    test "rejects images exceeding 60 KB size limit" do
      large_payload = :binary.copy("x", 65_000)
      assert {:error, :too_large} = ImageCache.put(2, "image/png", large_payload)
      assert :miss = ImageCache.get(2)
    end

    test "pruning oldest items works without error" do
      # Insert multiple items
      for i <- 1..160 do
        payload = "img-#{i}"
        ImageCache.put(i, "image/jpeg", payload)
      end

      # Size should be bounded and not explode
      assert ImageCache.size() <= 150
      assert ImageCache.size() > 0
    end

    test "clear/0 empties the cache" do
      ImageCache.put(10, "image/jpeg", "test")
      assert ImageCache.size() > 0
      ImageCache.clear()
      assert ImageCache.size() == 0
    end

    test "recovers from disk when ETS is wiped" do
      payload = "persistent-image-bytes"
      assert :ok = ImageCache.put(42, "image/webp", payload)
      assert File.exists?(ImageCache.disk_path(42))

      # Simulate server reboot / memory loss by deleting ETS table entry only
      :ets.delete(:deal_image_cache, 42)
      assert :ets.lookup(:deal_image_cache, 42) == []

      # Reading should reload from disk and repopulate ETS
      assert {:ok, "image/webp", ^payload} = ImageCache.get(42)
      assert [{42, "image/webp", ^payload, _}] = :ets.lookup(:deal_image_cache, 42)
    end

    test "rejects non-integer and path traversal keys" do
      assert {:error, :invalid_id} = ImageCache.put("../../etc/passwd", "image/png", "abc")
      assert :miss = ImageCache.get("../../etc/passwd")
      assert :miss = ImageCache.get("-1")
    end
  end
end
