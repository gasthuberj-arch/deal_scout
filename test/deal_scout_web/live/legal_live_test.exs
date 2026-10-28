defmodule DealScoutWeb.LegalLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Legal

  test "unauthenticated user can view /impressum", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/impressum")

    assert has_element?(view, "h1", "Impressum")
    assert has_element?(view, "#operator-name", Legal.operator_name())
    assert has_element?(view, "#operator-email", Legal.operator_email())
    assert has_element?(view, "#operator-address", Legal.operator_address())
    assert has_element?(view, "p", "Digitale-Dienste-Gesetz")
    assert has_element?(view, "a[href='/privacy']")
  end

  test "unauthenticated user can view /privacy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/privacy")

    assert has_element?(view, "h1", "Datenschutzerklärung")
    assert has_element?(view, "#operator-name", Legal.operator_name())
    assert has_element?(view, "#operator-email", Legal.operator_email())
    assert has_element?(view, "#privacy-by-design")
    assert has_element?(view, "a[href='/impressum']")
  end

  test "authenticated user can access legal pages and footer links", %{conn: conn} do
    user = DealScout.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/impressum")
    assert has_element?(view, "h1", "Impressum")

    {:ok, view, _html} = live(conn, ~p"/privacy")
    assert has_element?(view, "h1", "Datenschutzerklärung")

    # Verify footer links on root page
    {:ok, root_view, _} = live(conn, ~p"/")
    assert has_element?(root_view, "footer a[href='/impressum']", "Impressum")
    assert has_element?(root_view, "footer a[href='/privacy']", "Datenschutz")
  end
end
