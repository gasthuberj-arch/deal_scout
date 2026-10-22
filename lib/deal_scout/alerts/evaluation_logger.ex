defmodule DealScout.Alerts.EvaluationLogger do
  @moduledoc """
  Records slow alert rule evaluation runs to a persistent log file (NDJSON format).
  Tracks timing, batch window, rule metadata, and candidate deals for offline performance debugging.
  """

  require Logger

  @default_log_path "log/alert_evaluations.log"
  @default_threshold_us 5_000

  @doc """
  Logs an evaluation run if its total duration meets or exceeds the threshold.
  Options:
  - `:log_path` - destination file path (defaults to config `:alert_eval_log_path` or `log/alert_evaluations.log`)
  - `:threshold_us` - minimum duration in microseconds to log (defaults to config `:alert_eval_log_threshold_us` or 5,000µs / 5ms)
  """
  def log_evaluation(rule, deals, duration_us, normalized_duration_us, matches_count, opts \\ []) do
    threshold_us =
      Keyword.get(opts, :threshold_us) ||
        Application.get_env(:deal_scout, :alert_eval_log_threshold_us, @default_threshold_us)

    if duration_us >= threshold_us do
      log_path =
        Keyword.get(opts, :log_path) ||
          Application.get_env(:deal_scout, :alert_eval_log_path, @default_log_path)

      batch_window = compute_batch_window(deals)
      deal_refs = extract_deal_refs(deals)

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
        batch_window: batch_window,
        deal_references: deal_refs
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
              "[Alerts.EvaluationLogger] Failed to write evaluation log to #{log_path}: #{Exception.message(e)}"
            )

            {:error, e}
        end

      {:error, reason} ->
        Logger.warning(
          "[Alerts.EvaluationLogger] Failed to encode evaluation log entry: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
