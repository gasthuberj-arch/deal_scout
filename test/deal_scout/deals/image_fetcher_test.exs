defmodule DealScout.Deals.ImageFetcherTest do
  use ExUnit.Case, async: false

  alias DealScout.Deals.ImageFetcher

  describe "with_permit/2" do
    test "executes function and releases permit" do
      result = ImageFetcher.with_permit(fn -> :computed_value end)
      assert result == :computed_value
    end

    test "handles permit release when caller process crashes" do
      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, _mref} = ImageFetcher.acquire()
          exit(:simulated_crash)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :simulated_crash}

      # Sync with ImageFetcher GenServer
      _ = :sys.get_state(ImageFetcher)

      # Next acquire should succeed immediately
      assert {:ok, permit} = ImageFetcher.acquire(100)
      ImageFetcher.release(permit)
    end

    test "does not leak permits when waiting caller times out" do
      # Acquire all 4 permits
      pids_and_permits =
        for _ <- 1..4 do
          {:ok, permit} = ImageFetcher.acquire(100)
          permit
        end

      # 5th caller attempts to acquire with very short timeout and times out
      assert {:error, :busy} = ImageFetcher.acquire(10)

      # Release one permit
      [first | rest] = pids_and_permits
      ImageFetcher.release(first)

      # The freed permit should be immediately available, NOT lost to the timed-out 5th caller
      assert {:ok, new_permit} = ImageFetcher.acquire(100)

      # Clean up
      ImageFetcher.release(new_permit)
      Enum.each(rest, &ImageFetcher.release/1)
    end
  end
end
