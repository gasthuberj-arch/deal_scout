defmodule DealScoutWeb.Plugs.LocalePlugTest do
  use DealScoutWeb.ConnCase, async: true

  alias DealScout.Accounts.Scope
  alias DealScout.Accounts.User
  alias DealScoutWeb.Plugs.LocalePlug

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, DealScoutWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: conn}
  end

  describe "LocalePlug" do
    test "uses user locale when authenticated", %{conn: conn} do
      user = %User{id: 1, locale: "en"}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "en"
    end

    test "falls back to 'de' when user has invalid locale", %{conn: conn} do
      user = %User{id: 1, locale: "fr"}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "de"
    end

    test "uses session locale when unauthenticated", %{conn: conn} do
      conn =
        conn
        |> put_session(:locale, "en")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "en"
    end

    test "uses cookie locale when session has none", %{conn: conn} do
      conn =
        conn
        |> put_req_cookie("locale", "en")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "en"
    end

    test "uses Accept-Language header matching 'en'", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-language", "en-US,en;q=0.9,de;q=0.8")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "en"
      assert get_session(conn, :locale) == "en"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "en"
    end

    test "defaults to 'de' when Accept-Language matches 'de'", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9,en;q=0.8")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "de"
    end

    test "defaults to 'de' when no locale information is provided", %{conn: conn} do
      conn = LocalePlug.call(conn, [])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "de"
    end

    test "falls back to 'de' when session contains an unsupported locale", %{conn: conn} do
      conn =
        conn
        |> put_session(:locale, "es")
        |> LocalePlug.call([])

      assert conn.assigns.locale == "de"
      assert get_session(conn, :locale) == "de"
      assert Gettext.get_locale(DealScoutWeb.Gettext) == "de"
    end
  end
end
