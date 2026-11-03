defmodule DealScoutWeb.LocaleControllerTest do
  use DealScoutWeb.ConnCase

  alias DealScout.Accounts
  import DealScout.AccountsFixtures

  describe "GET /locale/:locale" do
    test "sets locale in session and cookie and redirects to root by default", %{conn: conn} do
      conn = get(conn, ~p"/locale/en")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :locale) == "en"
      assert conn.resp_cookies["locale"][:value] == "en"
    end

    test "redirects to referer when provided", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "/alerts")
        |> get(~p"/locale/de")

      assert redirected_to(conn) == "/alerts"
      assert get_session(conn, :locale) == "de"
      assert conn.resp_cookies["locale"][:value] == "de"
    end

    test "falls back to 'de' for unsupported locales", %{conn: conn} do
      conn = get(conn, ~p"/locale/fr")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :locale) == "de"
      assert conn.resp_cookies["locale"][:value] == "de"
    end

    test "updates user locale when user is authenticated", %{conn: conn} do
      user = user_fixture(%{locale: "de"})
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/locale/en")

      assert redirected_to(conn) == ~p"/"
      updated_user = Accounts.get_user!(user.id)
      assert updated_user.locale == "en"
    end
  end

  describe "POST /locale/:locale" do
    test "sets locale via POST request", %{conn: conn} do
      conn = post(conn, ~p"/locale/en")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :locale) == "en"
      assert conn.resp_cookies["locale"][:value] == "en"
    end
  end
end
