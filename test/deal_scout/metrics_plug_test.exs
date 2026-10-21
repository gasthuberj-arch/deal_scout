defmodule DealScout.MetricsPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  test "GET /metrics on internal plug returns 200 with prometheus content type" do
    conn =
      :get
      |> conn("/metrics")
      |> DealScout.MetricsPlug.call([])

    assert conn.status == 200
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert content_type =~ "version=0.0.4"
    assert is_binary(conn.resp_body)
  end

  test "GET /unknown on internal plug returns 404" do
    conn =
      :get
      |> conn("/other")
      |> DealScout.MetricsPlug.call([])

    assert conn.status == 404
  end
end
