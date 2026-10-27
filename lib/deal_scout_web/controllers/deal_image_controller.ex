defmodule DealScoutWeb.DealImageController do
  use DealScoutWeb, :controller

  alias DealScout.Deals.ThumbnailProxy

  @doc """
  Proxies and caches remote deal images via same-origin delivery.
  Allows mobile devices with strict adblockers, private DNS, or carrier restrictions
  to reliably load deal thumbnails without cross-origin or anti-hotlinking issues.

  Delegates the entire proxy, caching, and concurrency lifecycle to `DealScout.Deals.ThumbnailProxy`.
  """
  def show(conn, %{"id" => id}) do
    case ThumbnailProxy.get_thumbnail(id) do
      {:ok, content_type, body} ->
        send_image(conn, content_type, body)

      {:redirect, external_url} ->
        redirect(conn, external: external_url)

      :not_found ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp send_image(conn, content_type, body) do
    etag = Integer.to_string(:erlang.phash2(body), 16)

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=86400, stale-while-revalidate=3600")
      |> put_resp_header("etag", etag)

    if get_req_header(conn, "if-none-match") == [etag] do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_resp(200, body)
    end
  end
end
