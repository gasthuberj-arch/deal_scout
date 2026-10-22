defmodule DealScout.KeywordEngine.Server do
  @moduledoc """
  State lifecycle and dirty-rebuild manager for `KeywordEngine`.
  Synchronizes active alert rules from the database into compiled in-memory
  `:persistent_term` state.

  Debounces re-compilation: rule changes mark the GenServer dirty, and the state
  is recompiled only when `ensure_fresh_index/0` is invoked prior to processing
  an ingestion or matching batch.
  """

  use GenServer
  require Logger

  alias DealScout.Repo
  alias DealScout.Alerts.AlertRule
  alias DealScout.KeywordEngine.{Parser, Compiler, Matcher}
  import Ecto.Query, warn: false

  @timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Marks the engine state dirty when a rule is created, updated, or deleted"
  def mark_dirty do
    if GenServer.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :mark_dirty)
    else
      :ok
    end
  end

  @doc "Ensures the index in `:persistent_term` is fresh before batch evaluation"
  def ensure_fresh_index do
    if GenServer.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :ensure_fresh, @timeout)
    else
      :ok
    end
  end

  @doc "Forces an immediate rebuild of the index"
  def force_rebuild do
    if GenServer.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :force_rebuild, @timeout)
    else
      :ok
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{dirty: true}, {:continue, :initial_build}}
  end

  @impl true
  def handle_continue(:initial_build, state) do
    rebuild_from_db()
    {:noreply, %{state | dirty: false}}
  end

  @impl true
  def handle_cast(:mark_dirty, state) do
    {:noreply, %{state | dirty: true}}
  end

  @impl true
  def handle_call(:ensure_fresh, _from, %{dirty: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:ensure_fresh, _from, %{dirty: true} = state) do
    rebuild_from_db()
    {:reply, :ok, %{state | dirty: false}}
  end

  def handle_call(:force_rebuild, _from, state) do
    rebuild_from_db()
    {:reply, :ok, %{state | dirty: false}}
  end

  # ============================================================================
  # Rebuild Logic
  # ============================================================================

  defp rebuild_from_db do
    start_time = System.monotonic_time(:microsecond)
    rules_from_db = fetch_active_rules_from_db()

    parsed_rules =
      Enum.flat_map(rules_from_db, fn %{
                                        id: rule_id,
                                        user_id: user_id,
                                        keywords: keywords
                                      } ->
        case Parser.parse(keywords || "") do
          {:ok, parsed} -> [{rule_id, user_id, parsed}]
          _ -> []
        end
      end)

    compiled_state = Compiler.compile(parsed_rules)
    Matcher.put_state(compiled_state)

    duration_us = System.monotonic_time(:microsecond) - start_time

    Logger.info(
      "[KeywordEngine] Rebuilt index for #{length(parsed_rules)} active rules in #{Float.round(duration_us / 1000, 2)}ms"
    )
  end

  defp fetch_active_rules_from_db do
    Repo.all(
      from r in AlertRule,
        where: r.is_active == true,
        select: %{id: r.id, user_id: r.user_id, keywords: r.keywords}
    )
  rescue
    _ -> []
  end
end
