defmodule DealScout.Feeds.Ebay.AuthTest do
  use ExUnit.Case, async: false

  alias DealScout.Feeds.Ebay.Auth

  setup do
    original_config = Application.get_env(:deal_scout, DealScout.Feeds.Ebay)
    Auth.clear_cache()

    on_exit(fn ->
      Auth.clear_cache()

      if original_config do
        Application.put_env(:deal_scout, DealScout.Feeds.Ebay, original_config)
      else
        Application.delete_env(:deal_scout, DealScout.Feeds.Ebay)
      end
    end)

    :ok
  end

  test "returns {:error, :not_configured} when client credentials are unset" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay, client_id: nil, client_secret: nil)
    assert Auth.get_token() == {:error, :not_configured}
  end

  test "fetches token from eBay OAuth endpoint and caches it" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay,
      client_id: "test-app-id",
      client_secret: "test-secret"
    )

    expected_auth = "Basic " <> Base.encode64("test-app-id:test-secret")

    plug = fn conn ->
      [auth_header] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth_header == expected_auth
      assert conn.method == "POST"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "client_credentials"
      assert params["scope"] == "https://api.ebay.com/oauth/api_scope"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "v^1.1#test_token_123",
          "expires_in" => 7200,
          "token_type" => "Application Access Token"
        })
      )
    end

    assert {:ok, "v^1.1#test_token_123"} = Auth.get_token(req_options: [plug: plug])

    # Second call should use cache without invoking the plug
    failing_plug = fn _conn ->
      raise "Should not make HTTP request when token is cached"
    end

    assert {:ok, "v^1.1#test_token_123"} = Auth.get_token(req_options: [plug: failing_plug])
  end

  test "forces refresh when force_refresh: true option is provided" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay,
      client_id: "test-app-id",
      client_secret: "test-secret"
    )

    plug1 = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"access_token" => "token_one", "expires_in" => 7200})
      )
    end

    assert {:ok, "token_one"} = Auth.get_token(req_options: [plug: plug1])

    plug2 = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"access_token" => "token_two", "expires_in" => 7200})
      )
    end

    assert {:ok, "token_two"} = Auth.get_token(force_refresh: true, req_options: [plug: plug2])
    assert {:ok, "token_two"} = Auth.get_token()
  end

  test "handles authentication failure with 401 error" do
    Application.put_env(:deal_scout, DealScout.Feeds.Ebay,
      client_id: "bad-id",
      client_secret: "bad-secret"
    )

    error_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "invalid_client"}))
    end

    assert {:error, {:auth_failed, 401, _body}} = Auth.get_token(req_options: [plug: error_plug])
  end
end
