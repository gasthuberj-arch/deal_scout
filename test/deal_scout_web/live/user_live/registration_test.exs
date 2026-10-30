defmodule DealScoutWeb.UserLive.RegistrationTest do
  use DealScoutWeb.ConnCase

  import Phoenix.LiveViewTest
  import DealScout.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv
      |> element("#registration_form")
      |> render_change(user: %{"email" => "with spaces", "password" => "short"})

      assert has_element?(lv, "p.text-error", "must have the @ sign and no spaces")
      assert has_element?(lv, "p.text-error", "should be at least 12 character(s)")
    end
  end

  describe "register user" do
    test "creates account and logs in when valid invite code and password are provided", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: %{"email" => email, "password" => valid_user_password()},
          invite_code: "dealscout2026"
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully!"
    end

    test "rejects registration with invalid invite code", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: %{"email" => email, "password" => valid_user_password()},
          invite_code: "wrongcode"
        )

      render_submit(form)
      assert has_element?(lv, "[role=alert]", "Invalid invite code")
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      lv
      |> form("#registration_form",
        user: %{"email" => user.email, "password" => valid_user_password()},
        invite_code: "dealscout2026"
      )
      |> render_submit()

      assert has_element?(lv, "p.text-error", "has already been taken")
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
