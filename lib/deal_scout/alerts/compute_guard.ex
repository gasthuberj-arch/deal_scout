defmodule DealScout.Alerts.ComputeGuard do
  @moduledoc """
  The **Compute guard** module for per-rule Match evaluation.

  Wraps a single rule's evaluation against a batch of deals, measures duration,
  emits `[:deal_scout, :alerts, :rule_eval]` telemetry, appends slow runs to
  the persistent NDJSON evaluation log, updates `last_eval_duration_us`, and
  enforces the compute-budget circuit breaker (auto-pausing and broadcasting
  `{:rule_auto_paused, updated_rule, reason}` when enabled).
  """

  import Ecto.Query, warn: false
  require Logger

  alias DealScout.{Alerts, Repo}
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.Deal
  alias DealScout.Notifications.Dispatcher

  @default_budget_us 30_000
  @default_log_path "log/alert_evaluations.log"
  @default_threshold_us 5_000

  @doc """
  Executes `eval_fun.()` for `rule` against `deals`, applying telemetry,
  slow-evaluation logging, duration persistence, and compute-budget enforcement.

  Returns `{:ok, matched_deals}` when the rule remains active, or `:paused` when
  the rule exceeds its per-deal compute budget and auto-pause is enabled.

  Options:
  - `:budget_us` - per-deal compute budget in microseconds (default config `:alert_compute_budget_us` or 30,000µs)
  - `:auto_pause` - whether exceeding budget pauses the rule (default config `:alert_auto_pause_enabled` or false)
  - `:threshold_us` - total batch duration threshold for NDJSON slow-eval logging (default config `:alert_eval_log_threshold_us` or 5,000µs)
  - `:log_path` - NDJSON log path (default config `:alert_eval_log_path` or `"log/alert_evaluations.log"`)
  - `:duration_us` - override measured batch duration in microseconds (for deterministic policy tests)
  """
  @spec run(AlertRule.t(), [Deal.t()], keyword(), (-> [Deal.t()])) ::
          {:ok, [Deal.t()]} | :paused
  def run(%AlertRule{} = rule, deals, opts \\ [], eval_fun)
      when is_list(deals) and is_function(eval_fun, 0) do
    budget_us = Keyword.get(opts, :budget_us) || default_budget_us()
    auto_pause? = Keyword.get(opts, :auto_pause, auto_pause_enabled?())
    deal_count = max(length(deals), 1)

    start_time = System.monotonic_time(:microsecond)
    matched_deals = eval_fun.()
    measured_us = System.monotonic_time(:microsecond) - start_time
    duration_us = Keyword.get(opts, :duration_us, measured_us)
    normalized_duration_us = div(duration_us, deal_count)

    emit_telemetry(rule, deals, duration_us, normalized_duration_us)

    maybe_log_slow_evaluation(
      rule,
      deals,
      duration_us,
      normalized_duration_us,
      length(matched_deals),
      opts
    )

    cond do
      normalized_duration_us > budget_us and auto_pause? ->
        apply_auto_pause(rule, duration_us, normalized_duration_us, budget_us, deal_count)
        :paused

      normalized_duration_us > budget_us ->
        Logger.warning(
          "[Compute Guard] Slow alert rule #{rule.id} ('#{rule.name}') took #{normalized_duration_us}µs/deal (batch #{duration_us}µs for #{deal_count} deals), auto-pause is disabled."
        )

        record_duration(rule.id, normalized_duration_us)
        {:ok, matched_deals}

      true ->
        record_duration(rule.id, normalized_duration_us)
        {:ok, matched_deals}
    end
  end

  @doc "Returns true when automatic pausing of over-budget rules is enabled."
  @spec auto_pause_enabled?() :: boolean()
  def auto_pause_enabled? do
    Application.get_env(:deal_scout, :alert_auto_pause_enabled, false)
  end

  defp default_budget_us do
    Application.get_env(:deal_scout, :alert_compute_budget_us, @default_budget_us)
  end

  defp emit_telemetry(rule, deals, duration_us, normalized_duration_us) do
    :telemetry.execute(
      [:deal_scout, :alerts, :rule_eval],
      %{
        duration_us: duration_us,
        normalized_duration_us: normalized_duration_us,
        deal_count: length(deals)
      },
      %{rule_id: rule.id, user_id: rule.user_id, rule_name: rule.name}
    )
  end

  defp apply_auto_pause(rule, duration_us, normalized_duration_us, budget_us, deal_count) do
    budget_ms = Float.round(budget_us / 1000, 1)
    duration_ms = Float.round(normalized_duration_us / 1000, 1)

    reason =
      "Auto-paused: Query evaluation took #{duration_ms}ms/deal (exceeded #{budget_ms}ms compute budget). Simplify keywords or remove broad terms."

    updated_rule =
      case Alerts.auto_pause_rule(rule, reason, normalized_duration_us) do
        {:ok, updated} -> updated
        _ -> rule
      end

    Phoenix.PubSub.broadcast(
      DealScout.PubSub,
      Dispatcher.user_topic(rule.user_id),
      {:rule_auto_paused, updated_rule, reason}
    )

    Logger.warning(
      "[Compute Guard] Auto-paused slow alert rule #{rule.id} ('#{rule.name}') for user #{rule.user_id} - took #{normalized_duration_us}µs/deal (batch #{duration_us}µs for #{deal_count} deals)"
    )
  end

  defp record_duration(nil, _normalized_duration_us), do: :ok

  defp record_duration(rule_id, normalized_duration_us) do
    from(r in AlertRule, where: r.id == ^rule_id)
    |> Repo.update_all(set: [last_eval_duration_us: normalized_duration_us])

    :ok
  end

  # --- Persistent NDJSON slow evaluation log (private detail of ComputeGuard) ---

  defp maybe_log_slow_evaluation(
         rule,
         deals,
         duration_us,
         normalized_duration_us,
         matches_count,
         opts
       ) do
    threshold_us =
      Keyword.get(opts, :threshold_us) ||
        Application.get_env(:deal_scout, :alert_eval_log_threshold_us, @default_threshold_us)

    if duration_us >= threshold_us do
      log_path =
        Keyword.get(opts, :log_path) ||
          Application.get_env(:deal_scout, :alert_eval_log_path, @default_log_path)

      entry = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        rule_id: rule.id,
        rule_name: rule.name,
        user_id: rule.user_id,
        keywords: rule.keywords,
        negative_keywords: rule.negative_keywords,
        source_filter: rule.source_filter,
        country_filter: rule.country_filter,
        merchant_filter: rule.merchant_filter,
        min_temperature: rule.min_temperature,
        max_price: if(rule.max_price, do: to_string(rule.max_price), else: nil),
        exclude_dropshippers: rule.exclude_dropshippers,
        exclude_foreign_keyboards: rule.exclude_foreign_keyboards,
        deal_count: length(deals),
        duration_us: duration_us,
        duration_ms: Float.round(duration_us / 1000, 3),
        normalized_duration_us: normalized_duration_us,
        normalized_duration_ms: Float.round(normalized_duration_us / 1000, 3),
        matches_count: matches_count,
        batch_window: compute_batch_window(deals),
        deal_references: extract_deal_refs(deals)
      }

      write_entry(log_path, entry)
    else
      :ok
    end
  end

  defp compute_batch_window([]), do: nil

  defp compute_batch_window(deals) do
    timestamps =
      deals
      |> Enum.map(& &1.published_at)
      |> Enum.reject(&is_nil/1)

    case timestamps do
      [] ->
        nil

      list ->
        earliest = Enum.min(list, DateTime)
        latest = Enum.max(list, DateTime)

        %{
          earliest_published_at: DateTime.to_iso8601(earliest),
          latest_published_at: DateTime.to_iso8601(latest),
          window_seconds: DateTime.diff(latest, earliest, :second)
        }
    end
  end

  defp extract_deal_refs(deals) do
    Enum.map(deals, fn deal ->
      feed_slug =
        case deal.feed do
          %Ecto.Association.NotLoaded{} -> nil
          %{slug: slug} -> slug
          _ -> nil
        end

      merchant_name =
        case deal.merchant do
          %Ecto.Association.NotLoaded{} -> deal.raw_merchant
          %{name: name} -> name
          _ -> deal.raw_merchant
        end

      %{
        id: deal.id,
        guid: deal.guid,
        feed_id: deal.feed_id,
        feed_slug: feed_slug,
        merchant_id: deal.merchant_id,
        merchant_name: merchant_name,
        title: deal.title,
        price: if(deal.price, do: to_string(deal.price), else: nil),
        published_at: if(deal.published_at, do: DateTime.to_iso8601(deal.published_at), else: nil)
      }
    end)
  end

  defp write_entry(log_path, entry) do
    case Jason.encode(entry) do
      {:ok, json} ->
        try do
          dir = Path.dirname(log_path)
          if dir != "." and not File.dir?(dir), do: File.mkdir_p!(dir)

          File.write(log_path, json <> "\n", [:append])
        rescue
          e ->
            Logger.warning(
              "[Alerts.ComputeGuard] Failed to write evaluation log to #{log_path}: #{Exception.message(e)}"
            )

            {:error, e}
        end

      {:error, reason} ->
        Logger.warning(
          "[Alerts.ComputeGuard] Failed to encode evaluation log entry: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
