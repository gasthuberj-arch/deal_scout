defmodule DealScoutWeb.MetricsController do
  @moduledoc """
  Serves Prometheus metrics on the public /metrics endpoint.

  Protected by Bearer token via DealScoutWeb.Plugs.MetricsAuth in the router.
  Intended for the homelab Prometheus scraper over public HTTPS.

  Fly's internal scraper uses the unauthenticated DealScout.MetricsPlug
  on port 9091 instead.
  """
  use DealScoutWeb, :controller

  def index(conn, _params) do
    scrape = TelemetryMetricsPrometheus.Core.scrape(:prometheus_metrics)

    conn
    |> put_resp_content_type("text/plain", "version=0.0.4")
    |> send_resp(200, scrape)
  end
end
