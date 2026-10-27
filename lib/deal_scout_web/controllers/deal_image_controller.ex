defmodule DealScoutWeb.DealImageController do
  use DealScoutWeb, :controller

  alias DealScout.Media.ImageProxy

  @doc """
  Proxies and caches remote deal images.
  This allows mobile devices (e.g. Pixel/Android) with strict adblockers,
  private DNS, or cellular carrier CDN blocks to reliably load deal thumbnails
  from the same-origin server with zero cross-origin or mixed-content issues.
  """
  def show(conn, %{"id" => id}) do
    case ImageProxy.fetch_image(id) do
      {:ok, content_type, body} ->
        send_image(conn, content_type, body)

      {:redirect, url} ->
        redirect(conn, external: url)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp send_image(conn, content_type, body) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("cache-control", "public, max-age=604800, stale-while-revalidate=86400")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(200, body)
  end
end
