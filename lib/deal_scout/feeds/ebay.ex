defmodule DealScout.Feeds.Ebay do
  @moduledoc """
  The **eBay Sofort-Kauf sniper** intake context module.

  Provides a deep, unified interface for demand-driven eBay item polling,
  candidate pre-filtering, in-memory alert evaluation with compute-guard protection,
  and match persistence.
  """

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.Ingestion
  alias DealScout.Feeds
  alias DealScout.Feeds.Ebay.{Config, Poller, SeenCache}

  @doc """
  Executes a synchronous poll cycle across all active eBay queries.
  Filters unseen items via in-memory SeenCache, evaluates candidates in RAM,
  and persists only matching deals.
  """
  def poll(opts \\ []) do
    Poller.perform_poll_cycle(opts)
  end

  @doc """
  Triggers an immediate asynchronous polling cycle in the background.
  """
  def poll_now do
    Poller.poll_now()
  end

  @doc """
  Returns the operational status of the eBay sniper.
  """
  def status do
    base = Poller.status()
    Map.put(base, :seen_items, SeenCache.size())
  end

  @doc """
  Evaluates candidate deal items in memory against alert rules.
  Only items matching at least one active rule are persisted to SQLite.

  Options:
  - `:rules` - Explicit list of `AlertRule` structs (defaults to eBay-eligible `Alerts.list_active_rules()`).

  Returns `{:ok, %{matched_deals: [Deal.t()], discarded_count: integer()}}`.
  """
  def evaluate_and_persist(items, opts \\ []) when is_list(items) do
    ebay_feed = Feeds.ensure_ebay_feed()

    rules =
      case Keyword.get(opts, :rules) do
        nil ->
          Alerts.list_active_rules()
          |> Enum.filter(&AlertRule.ebay_eligible?/1)

        custom_rules ->
          custom_rules
      end

    Ingestion.ingest_ephemeral(items, ebay_feed, Keyword.put(opts, :rules, rules))
  end

  # ============================================================================
  # Configuration & Cache Invariants
  # ============================================================================

  @doc """
  Returns true if eBay client ID and client secret are configured.
  """
  def configured?, do: Config.configured?()

  @doc """
  Returns true if eBay integration is configured and enabled.
  """
  def enabled?, do: Config.enabled?()

  @doc """
  Returns the configured eBay Marketplace ID (e.g. EBAY_DE).
  """
  def marketplace_id, do: Config.marketplace_id()

  @doc """
  Returns the configured eBay Client ID.
  """
  def client_id, do: Config.client_id()

  @doc """
  Returns the polling interval in seconds.
  """
  def poll_interval_seconds, do: Config.poll_interval_seconds()

  @doc """
  Returns the number of seen items tracked in the in-memory ETS cache.
  """
  def seen_cache_size, do: SeenCache.size()

  @doc """
  Clears the seen cache ETS table (primarily for testing).
  """
  def clear_seen_cache, do: SeenCache.clear()
end
