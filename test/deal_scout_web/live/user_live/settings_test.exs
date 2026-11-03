defmodule DealScoutWeb.UserLive.SettingsTest do
  use DealScoutWeb.ConnCase

  alias DealScout.Accounts
  import Phoenix.LiveViewTest
  import DealScout.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(%{locale: "en"}))
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture(%{locale: "en"})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture(%{locale: "en"})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "push devices management" do
    setup %{conn: conn} do
      user = user_fixture(%{locale: "en"})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "registers, tests, and removes a push notification device", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      assert has_element?(lv, "#push-settings-container")
      assert has_element?(lv, "#android-battery-guide-card")
      assert has_element?(lv, "#push-subscriptions")
      assert has_element?(lv, "button[phx-click='register_this_device']")

      # Register device via hook event
      render_hook(lv, "save-push-subscription", %{
        "endpoint" => "https://push.example.com/device-1",
        "p256dh" => "mock_p256dh",
        "auth" => "mock_auth",
        "device_name" => "Apple iPhone 15 Pro"
      })

      assert has_element?(lv, "#push-subscriptions", "Apple iPhone 15 Pro")
      assert has_element?(lv, "button[phx-click='send_test_push']")

      # Send test push and verify delivery diagnostics update
      lv |> element("button[phx-click='send_test_push']") |> render_click()
      assert has_element?(lv, "button[phx-click='send_test_push']")
      assert has_element?(lv, "#push-delivery-logs-section")
      assert has_element?(lv, "#push-delivery-logs")

      # Remove device
      [sub] = DealScout.Notifications.list_push_subscriptions_for_user(user.id)

      lv
      |> element("button[phx-click='remove_subscription'][phx-value-id='#{sub.id}']")
      |> render_click()

      refute has_element?(lv, "#push-subscriptions", "Apple iPhone 15 Pro")
      assert DealScout.Notifications.list_push_subscriptions_for_user(user.id) == []
    end

    test "allows renaming device nickname and shows device confirmation health", %{conn: conn} do
      user = user_fixture(%{locale: "en"})

      sub =
        DealScout.Repo.insert!(%DealScout.Notifications.PushSubscription{
          user_id: user.id,
          endpoint:
            "https://push.example.com/device-rename-test-#{System.unique_integer([:positive])}",
          p256dh: "key_p256dh",
          auth: "key_auth",
          device_name: "Original Name",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) Safari/604.1"
        })

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      assert has_element?(lv, "#push-subscriptions", "Original Name")
      assert has_element?(lv, "#push-subscriptions", "Safari on iOS")
      assert has_element?(lv, "#push-subscriptions", "0 confirmed (24h)")

      # Click edit device button
      lv
      |> element("button[phx-click='edit_device'][phx-value-id='#{sub.id}']")
      |> render_click()

      assert has_element?(lv, "#edit-device-form-#{sub.id}")

      # Submit rename form
      lv
      |> form("#edit-device-form-#{sub.id}", %{
        "device" => %{"device_name" => "Renamed iPhone"}
      })
      |> render_submit()

      assert has_element?(lv, "#push-subscriptions", "Renamed iPhone")
      refute has_element?(lv, "#push-subscriptions", "Original Name")

      updated_sub = DealScout.Repo.get!(DealScout.Notifications.PushSubscription, sub.id)
      assert updated_sub.device_name == "Renamed iPhone"
    end
  end

  describe "data export: gdpr data portability" do
    test "renders export my data button and container", %{conn: conn} do
      user = user_fixture(%{locale: "en"})

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      assert has_element?(lv, "#data-export-container h2", "Export My Data (GDPR Art. 15")
      assert has_element?(lv, "#data-export-container")
      assert has_element?(lv, "#download_data_btn[href='/users/settings/export']", "Export Data")
    end
  end

  describe "danger zone: delete account" do
    test "renders danger zone delete form and elements", %{conn: conn} do
      user = user_fixture(%{locale: "en"}) |> set_password()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      assert has_element?(lv, "#danger-zone-container h2", "Danger Zone: Delete Account")
      assert has_element?(lv, "#danger-zone-container")
      assert has_element?(lv, "#delete_account_form")
      assert has_element?(lv, "#delete_account_password")
      assert has_element?(lv, "#delete_account_btn")
    end
  end

  describe "language / sprache settings" do
    test "renders language settings card with options", %{conn: conn} do
      user = user_fixture(%{locale: "de"})

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      assert has_element?(lv, "#language-settings-card")
      assert has_element?(lv, "#locale-settings-form input[value='de'][checked]")
      assert has_element?(lv, "#locale-settings-form input[value='en']")
    end

    test "updates locale on form change and redirects to /locale/:locale", %{conn: conn} do
      user = user_fixture(%{locale: "de"})

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      lv
      |> form("#locale-settings-form")
      |> render_change(%{"locale" => "en"})

      assert_redirect(lv, ~p"/locale/en?redirect_to=%2Fusers%2Fsettings")
      assert Accounts.get_user!(user.id).locale == "en"
    end
  end
end
