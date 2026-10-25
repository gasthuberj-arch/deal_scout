defmodule DealScout.Maintenance.Pruner do
  @moduledoc """
  Background GenServer that automatically purges deals older than 30 days
  daily at 03:00 UTC and runs `PRAGMA incremental_vacuum;` to keep the SQLite
  database file lean and within small hosting/backup footprints.
  """

  use GenServer
  require Logger

  alias DealScout.Deals
  alias DealScout.Repo

  @retention_days 30
  @target_hour_utc 3
  @target_minute_utc 0

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Computes milliseconds until the next occurrence of `target_hour:target_minute:00` UTC.
  """
  @spec ms_until_next_run(DateTime.t(), non_neg_integer(), non_neg_integer()) :: pos_integer()
  def ms_until_next_run(
        %DateTime{} = now \\ DateTime.utc_now(),
        target_hour \\ @target_hour_utc,
        target_minute \\ @target_minute_utc
      ) do
    today_target = %{
      now
      | hour: target_hour,
        minute: target_minute,
        second: 0,
        microsecond: {0, 0}
    }

    next_target =
      if DateTime.compare(now, today_target) == :lt do
        today_target
      else
        DateTime.add(today_target, 24 * 3600, :second)
      end

    max(1_000, DateTime.diff(next_target, now, :millisecond))
  end

  @doc """
  Ensures `PRAGMA auto_vacuum = INCREMENTAL` (mode 2) is enabled on the SQLite database.
  If the database is not currently in incremental mode, sets the pragma and runs a
  one-time `VACUUM;` to rewrite the header and enable incremental page reclamation.
  """
  def ensure_incremental_auto_vacuum do
    case Repo.query("PRAGMA auto_vacuum;") do
      {:ok, %{rows: [[2]]}} ->
        :ok

      {:ok, %{rows: [[mode]]}} ->
        Logger.info(
          "[DealScout.Pruner] SQLite auto_vacuum mode is #{mode}; transitioning to INCREMENTAL (2)..."
        )

        {:ok, _} = Repo.query("PRAGMA auto_vacuum = INCREMENTAL;")
        {:ok, _} = Repo.query("VACUUM;")
        :ok

      other ->
        Logger.warning(
          "[DealScout.Pruner] Unexpected response checking PRAGMA auto_vacuum: #{inspect(other)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "[DealScout.Pruner] Could not configure auto_vacuum (likely inside SQL sandbox): #{Exception.message(e)}"
      )

      :error
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms)
    days = Keyword.get(opts, :retention_days, @retention_days)
    skip_auto_vacuum_setup = Keyword.get(opts, :skip_auto_vacuum_setup, false)

    unless skip_auto_vacuum_setup do
      ensure_incremental_auto_vacuum()
    end

    state = %{interval_ms: interval_ms, days: days}
    schedule_next(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_and_vacuum(state.days)
    schedule_next(state)
    {:noreply, state}
  end

  defp prune_and_vacuum(days) do
    {count, _} = Deals.prune_old_deals(days)

    if count > 0 do
      Logger.info("[DealScout.Pruner] Pruned #{count} deals older than #{days} days.")
    end

    case Repo.query("PRAGMA incremental_vacuum;") do
      {:ok, _} ->
        if count > 0 do
          Logger.info("[DealScout.Pruner] Completed PRAGMA incremental_vacuum.")
        end

      {:error, reason} ->
        Logger.warning("[DealScout.Pruner] PRAGMA incremental_vacuum failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("[DealScout.Pruner] Error pruning deals: #{Exception.message(e)}")
  end

  defp schedule_next(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :prune, interval_ms)
  end

  defp schedule_next(_state) do
    delay_ms = ms_until_next_run()
    Process.send_after(self(), :prune, delay_ms)
  end
end
