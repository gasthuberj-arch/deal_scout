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
    with token when is_binary(token) <- configured_token(),
         ["Bearer " <> provided] <- get_req_header(conn, "authorization"),
         provided = String.trim(provided),
         true <- provided != "" do
      Plug.Crypto.secure_compare(provided, token)
    else
      _ -> false
    end
  end

  defp configured_token do
    token =
      Application.get_env(:deal_scout, :metrics_token) ||
        Application.get_env(:deal_scout, :backup_token)

    case token do
      t when is_binary(t) ->
        t = String.trim(t)
        if t != "", do: t, else: nil

      _ ->
        nil
    end
  end
end
