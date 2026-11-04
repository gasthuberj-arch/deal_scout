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
    client_etag =
      case get_req_header(conn, "if-none-match") do
        [tag | _] -> String.trim(tag, "\"")
        _ -> nil
      end

    case ThumbnailProxy.get_thumbnail(id, if_none_match: client_etag) do
      {:not_modified, etag} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=86400, stale-while-revalidate=3600")
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")

      {:ok, content_type, body, etag} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=86400, stale-while-revalidate=3600")
        |> put_resp_header("etag", etag)
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("access-control-allow-origin", "*")
        |> send_resp(200, body)

      {:redirect, external_url} ->
        redirect(conn, external: external_url)

      :not_found ->
        send_resp(conn, 404, "Not Found")
    end
  end
end
