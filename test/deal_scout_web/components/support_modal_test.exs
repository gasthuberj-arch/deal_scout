defmodule DealScoutWeb.Components.SupportModalTest do
  use DealScoutWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias DealScoutWeb.Components.SupportModal

  describe "coffee_url/0" do
    test "defaults to https://ko-fi.com when COFFEE_URL is unset or empty" do
      original = System.get_env("COFFEE_URL")

      try do
        System.delete_env("COFFEE_URL")
        assert SupportModal.coffee_url() == "https://ko-fi.com"

        System.put_env("COFFEE_URL", "")
        assert SupportModal.coffee_url() == "https://ko-fi.com"
      after
        if original,
          do: System.put_env("COFFEE_URL", original),
          else: System.delete_env("COFFEE_URL")
      end
    end

    test "returns COFFEE_URL when configured" do
      original = System.get_env("COFFEE_URL")

      try do
        System.put_env("COFFEE_URL", "https://ko-fi.com/custom")
        assert SupportModal.coffee_url() == "https://ko-fi.com/custom"
      after
        if original,
          do: System.put_env("COFFEE_URL", original),
          else: System.delete_env("COFFEE_URL")
      end
    end
  end

  describe "coffee_modal/1" do
    test "renders only the Ko-fi support option and removes other rails", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#coffee-modal")
      assert has_element?(view, "#kofi-support-link[href='https://ko-fi.com']")
      refute html =~ "Buy Me a Coffee"
      refute html =~ "PayPal.me"
      refute html =~ "GitHub Sponsors"
    end
  end
end
