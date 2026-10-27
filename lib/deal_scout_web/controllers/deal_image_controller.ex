defmodule DealScoutWeb.DealImageController do
  use DealScoutWeb, :controller

  alias DealScout.Repo
  alias DealScout.Deals.Deal
  alias DealScout.Deals.ImageCache

  @max_download_bytes 60_000

  @doc """
  Proxies and caches remote deal images.
  This allows mobile devices (e.g. Pixel/Android/iOS) with strict adblockers,
  private DNS, or cellular carrier CDN restrictions to reliably load deal thumbnails
  from the same-origin server with zero cross-origin or anti-hotlinking issues.

  Includes:
  - Cache-Control (24h) and ETag support for client-side HTTP 304 caching.
  - Memory-safe bounded streaming download (caps payloads <= 60 KB).
  - Bounded in-memory caching for thumbnails <= 60 KB.
  - Direct upstream fallback on errors or oversized entries.
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
        case fetch_remote_thumbnail(url) do
          {:ok, content_type, body} ->
            _ = ImageCache.put(id, content_type, body)
            send_image(conn, content_type, body)

          _ ->
            redirect(conn, external: url)
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp fetch_remote_thumbnail(url) do
    collect_chunks = fn {:data, chunk}, {acc, size} ->
      new_size = size + byte_size(chunk)

      if new_size > @max_download_bytes do
        {:halt, {:too_large, ""}}
      else
        {:cont, {[chunk | acc], new_size}}
      end
    end

    case Req.get(url,
           headers: [
             {"user-agent",
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"},
             {"accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"}
           ],
           into: {collect_chunks, {[], 0}},
           receive_timeout: 4000,
           max_retries: 1
         ) do
      {:ok, %Req.Response{status: 200, body: {chunks, _size}} = resp} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        content_type = extract_content_type(resp)
        {:ok, content_type, body}

      _ ->
        :error
    end
  rescue
    _ -> :error
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

  defp extract_content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] when is_binary(ct) -> ct
      _ -> "image/jpeg"
    end
  end
end
