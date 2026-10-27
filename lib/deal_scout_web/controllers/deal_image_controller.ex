defmodule DealScoutWeb.DealImageController do
  use DealScoutWeb, :controller

  alias DealScout.Repo
  alias DealScout.Deals.Deal
  alias DealScout.Deals.ImageCache

  @doc """
  Proxies and caches remote deal images.
  This allows mobile devices (e.g. Pixel/Android) with strict adblockers,
  private DNS, or cellular carrier CDN blocks to reliably load deal thumbnails
  from the same-origin server with zero cross-origin or mixed-content issues.
  """
  def show(conn, %{"id" => id}) do
    case ImageCache.get(id) do
      {:ok, content_type, body} ->
        send_image(conn, content_type, body)

      :miss ->
        fetch_and_serve(conn, id)
    end
  end

  defp fetch_and_serve(conn, id) do
    case Repo.get(Deal, id) do
      %Deal{image_url: url} when is_binary(url) and url != "" ->
        case Req.get(url,
               headers: [
                 {"user-agent",
                  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"},
                 {"accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"}
               ],
               receive_timeout: 4000,
               max_retries: 1
             ) do
          {:ok, %Req.Response{status: 200, body: body} = resp} when is_binary(body) ->
            content_type = extract_content_type(resp)
            ImageCache.put(id, content_type, body)
            send_image(conn, content_type, body)

          _ ->
            redirect(conn, external: url)
        end

      _ ->
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

  defp extract_content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] when is_binary(ct) -> ct
      ct when is_binary(ct) -> ct
      _ -> "image/jpeg"
    end
  end
end
