defmodule DealScout.MetricsPlug do
  @moduledoc """
  Minimal Plug serving Prometheus metrics on the internal metrics port (9091).

  This port is only reachable via Fly's internal 6PN network — it is not
  publicly routed — so no authentication is required. Fly's built-in metrics
  scraper is directed here via the [metrics] block in fly.toml.

  All other paths return 404 so the port is not useful for anything else.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/metrics"} = conn, _opts) do
    scrape = TelemetryMetricsPrometheus.Core.scrape(:prometheus_metrics)

    conn
    |> put_resp_content_type("text/plain", "version=0.0.4")
    |> send_resp(200, scrape)
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "Not found")
  end
end
