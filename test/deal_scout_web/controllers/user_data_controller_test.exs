defmodule DealScoutWeb.UserDataControllerTest do
  use DealScoutWeb.ConnCase

  import DealScout.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "GET /users/settings/export" do
    test "redirects to log-in when unauthenticated", %{conn: conn} do
      conn = get(conn, ~p"/users/settings/export")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "downloads valid JSON payload with user data", %{conn: conn, user: user} do
      {:ok, _rule} =
        DealScout.Alerts.create_alert_rule(user, %{
          name: "My Rule",
          keywords: "steam deck",
          delivery_mode: "instant"
        })

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/users/settings/export")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"deal_scout_export_"

      {:ok, decoded} = Jason.decode(response(conn, 200))
      assert decoded["service"] == "DealScout"
      assert decoded["version"] == "1.0"
      assert decoded["account"]["email"] == user.email
      assert is_list(decoded["alert_rules"])
      assert length(decoded["alert_rules"]) == 1
      assert hd(decoded["alert_rules"])["keywords"] == "steam deck"
    end
  end
end
