defmodule DealScoutWeb.Plugs.MetricsAuth do
  @moduledoc """
  Protects the public /metrics endpoint with Bearer token authentication.

  Reads METRICS_TOKEN from application config, falling back to the
  ADMIN_BACKUP_TOKEN if no separate metrics token is configured. This keeps
  the homelab setup simple — one secret, two endpoints — while still allowing
  independent rotation if needed.
  """
  @behaviour Plug

  import Plug.Conn
  alias DealScout.Backup

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if authorized?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "Unauthorized. Bearer token required.")
      |> halt()
    end
  end

  defp authorized?(conn) do
    conn.req_headers
    |> Backup.extract_bearer_token()
    |> Backup.valid_token?(:metrics)
  end
end
