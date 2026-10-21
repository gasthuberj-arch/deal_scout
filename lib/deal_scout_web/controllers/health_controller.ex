defmodule DealScoutWeb.HealthController do
  @moduledoc """
  Liveness check endpoint. Returns 200 OK as long as the BEAM is running.

  Intentionally minimal — no DB check, no backup-lag check. Those are metric
  concerns, not traffic-routing concerns. Fly.io uses this endpoint to decide
  when a new VM is ready to receive traffic.
  """
  use DealScoutWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
