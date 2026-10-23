defmodule DealScoutWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Emit startup event with BEAM boot monotonic time
    :telemetry.execute([:deal_scout, :vm, :startup], %{
      boot_time_ms: System.monotonic_time(:millisecond)
    })

    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus Core reporter for both internal :9091 and public /metrics scraping
      {TelemetryMetricsPrometheus.Core,
       [name: :prometheus_metrics, metrics: prometheus_metrics()]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Prometheus-compatible metrics definition (counters, distributions with buckets, and gauges).
  """
  def prometheus_metrics do
    [
      # Phoenix Request Metrics
      counter("phoenix.endpoint.stop.count"),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500]]
      ),

      # Database Metrics
      distribution("deal_scout.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      distribution("deal_scout.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250]]
      ),

      # Alert Evaluation Duration (Compute Budget)
      distribution("deal_scout.alerts.rule_eval.duration_us",
        unit: {:native, :microsecond},
        reporter_options: [buckets: [50, 100, 250, 500, 1000, 2500, 5000, 10000]]
      ),

      # VM & Resource Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Custom Domain Gauges (RTO & RPO proxies)
      last_value("deal_scout.vm.startup.boot_time_ms"),
      last_value("deal_scout.backup.lag_seconds"),
      last_value("deal_scout.backup.client_connected")
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("deal_scout.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("deal_scout.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("deal_scout.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("deal_scout.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("deal_scout.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_backup_metrics, []}
    ]
  end

  @doc false
  def measure_backup_metrics do
    try do
      status = DealScout.Backup.get_status()
      connected = if status.client_connected, do: 1, else: 0

      :telemetry.execute([:deal_scout, :backup], %{
        lag_seconds: status.lag_seconds,
        client_connected: connected
      })
    catch
      _, _ -> :ok
    end
  end
end
