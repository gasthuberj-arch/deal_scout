defmodule DealScoutWeb.Admin.SystemLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.AccountsFixtures

  setup do
    admin = AccountsFixtures.admin_fixture()
    regular_user = AccountsFixtures.user_fixture()

    %{admin: admin, regular_user: regular_user}
  end

  test "redirects unauthenticated visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/system")
  end

  test "redirects regular authenticated user to root", %{conn: conn, regular_user: user} do
    conn = log_in_user(conn, user)

    assert {:error,
            {:redirect,
             %{to: "/", flash: %{"error" => "You must be an administrator to access this page."}}}} =
             live(conn, ~p"/admin/system")
  end

  test "admin user mounts system health dashboard and triggers feed polling", %{
    conn: conn,
    admin: admin
  } do
    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert html =~ "System &amp; Infrastructure Health" or
             html =~ "System & Infrastructure Health"

    assert html =~ "Active Connected Sessions"
    assert html =~ "BEAM VM Memory"
    assert html =~ "RSS &amp; Atom Feed Poller Health" or html =~ "RSS & Atom Feed Poller Health"

    # Trigger immediate poll
    assert view
           |> element("button[phx-click='trigger_poll']")
           |> render_click() =~ "Triggered immediate background poll for all feeds."
  end
end
