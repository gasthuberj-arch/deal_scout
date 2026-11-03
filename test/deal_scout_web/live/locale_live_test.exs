defmodule DealScoutWeb.LocaleLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest
  import DealScout.AccountsFixtures

  describe "Navbar language switcher" do
    test "renders language switcher with links to /locale/de and /locale/en", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~p"/locale/de"
      assert html =~ ~p"/locale/en"
      assert html =~ "DE"
      assert html =~ "EN"
    end

    test "renders active indicator for current locale", %{conn: conn} do
      # With German locale in session
      conn =
        conn
        |> init_test_session(%{locale: "de"})

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "a[href='/locale/de'].bg-primary")
    end
  end

  describe "AlertLive bilingual rendering" do
    test "renders German strings when user locale is de", %{conn: conn} do
      user = user_fixture(%{locale: "de"})

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> init_test_session(%{locale: "de"})
        |> live(~p"/alerts")

      assert html =~ "Aktive Suchaufträge"
      assert html =~ "Suchauftrag hinzufügen"
    end

    test "renders English strings when user locale is en", %{conn: conn} do
      user = user_fixture(%{locale: "en"})

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> init_test_session(%{locale: "en"})
        |> live(~p"/alerts")

      assert html =~ "Keyword Alert Rules"
      assert html =~ "Add Alert Rule"
    end
  end

  describe "MatchLive bilingual rendering" do
    test "renders German empty state when locale is de", %{conn: conn} do
      user = user_fixture(%{locale: "de"})

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> init_test_session(%{locale: "de"})
        |> live(~p"/matches")

      assert html =~ "Gefundene Treffer"
      assert html =~ "Posteingang leer"
    end
  end
end
