defmodule DealScoutWeb.UserDataController do
  use DealScoutWeb, :controller

  alias DealScout.Accounts

  @doc """
  Streams a machine-readable JSON export of all user personal data, configuration,
  alert rules, match history, and registered devices for GDPR Art. 15 and Art. 20 data portability.
  """
  def export(conn, _params) do
    user = conn.assigns.current_scope.user
    export_payload = Accounts.export_user_data(user)
    json = Jason.encode!(export_payload, pretty: true)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "deal_scout_data_export_#{timestamp}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s[attachment; filename="#{filename}"])
    |> send_resp(200, json)
  end
end
