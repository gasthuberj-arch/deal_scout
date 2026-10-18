defmodule DealScout.Feeds.Parser do
  @moduledoc """
  Parses RSS 2.0 and Atom XML feeds into normalized Deal structs.
  Extracts titles, prices, merchants, images, links, and clean text.
  """

  @doc """
  Parses an XML feed string for a given feed_id.
  Returns a list of deal attribute maps.
  """
  def parse_feed(xml_string, feed_id) when is_binary(xml_string) do
    case Floki.parse_document(xml_string) do
      {:ok, document} ->
        items = Floki.find(document, "item")

        Enum.map(items, fn item ->
          parse_item(item, feed_id)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_item(item, feed_id) do
    title = item |> Floki.find("title") |> Floki.text() |> strip_cdata()
    link = item |> Floki.find("link") |> Floki.text() |> strip_cdata()
    guid = item |> Floki.find("guid") |> Floki.text() |> strip_cdata()
    guid = if guid == "", do: link, else: guid

    pub_date_str = item |> Floki.find("pubdate") |> Floki.text() |> strip_cdata()
    published_at = parse_datetime(pub_date_str)

    description = item |> Floki.find("description") |> Floki.text() |> strip_cdata()
    clean_text = clean_html(description)

    merchant = extract_merchant(item, description)
    price = extract_price(item, title, description)
    image_url = extract_image_url(item, description)

    if title != "" and link != "" do
      %{
        feed_id: feed_id,
        guid: guid,
        title: title,
        url: link,
        description: description,
        clean_text: clean_text,
        price: price,
        merchant: merchant,
        image_url: image_url,
        published_at: published_at
      }
    else
      nil
    end
  end

  defp clean_html(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, fragment} ->
        fragment
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        html
        |> String.replace(~r/<[^>]*>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
    end
  end

  defp clean_html(_), do: ""

  defp strip_cdata(text) when is_binary(text) do
    text
    |> String.replace("<![CDATA[", "")
    |> String.replace("]]>", "")
    |> String.trim()
  end

  defp strip_cdata(other), do: other

  defp extract_merchant(item, description) do
    # 1. Check pepper:merchant attribute
    merchant_tag = Floki.find(item, "pepper\\:merchant, merchant")

    case Floki.attribute(merchant_tag, "name") do
      [name | _] when is_binary(name) and name != "" ->
        String.trim(name)

      _ ->
        # 2. Check strong/b tag in description or regex like "6,99€ - EDEKA"
        case Regex.run(~r/\d+[,.]\d{2}\s*€?\s*-\s*([A-Za-z0-9\s&]+?)(?:<|\n|$)/, description) do
          [_, merchant] -> String.trim(merchant)
          _ -> nil
        end
    end
  end

  defp extract_price(item, title, description) do
    # 1. Check pepper:merchant price attribute
    merchant_tag = Floki.find(item, "pepper\\:merchant, merchant")

    pepper_price =
      case Floki.attribute(merchant_tag, "price") do
        [p | _] when is_binary(p) -> parse_price_string(p)
        _ -> nil
      end

    if pepper_price do
      pepper_price
    else
      # 2. Check title or description for price pattern (e.g. "19,99€" or "19.99 €")
      find_price_in_text(title) || find_price_in_text(description)
    end
  end

  defp find_price_in_text(text) when is_binary(text) do
    case Regex.run(~r/(?:^|[^\d])(\d{1,4}[,.]\d{2})\s*€/, text) do
      [_, price_str] ->
        parse_price_string(price_str)

      _ ->
        case Regex.run(~r/(\d{1,4})\s*€/, text) do
          [_, int_str] -> parse_price_string(int_str <> ",00")
          _ -> nil
        end
    end
  end

  defp find_price_in_text(_), do: nil

  defp parse_price_string(str) when is_binary(str) do
    cleaned =
      str
      |> String.replace("€", "")
      |> String.replace(" ", "")
      |> String.replace(".", "")
      |> String.replace(",", ".")
      |> String.trim()

    case Decimal.parse(cleaned) do
      {dec, ""} -> dec
      _ -> nil
    end
  end

  defp parse_price_string(_), do: nil

  defp extract_image_url(item, description) do
    # 1. media:content or media:thumbnail or enclosure
    media =
      Floki.find(item, "media\\:content, media\\:thumbnail, enclosure")
      |> Floki.attribute("url")

    case media do
      [url | _] when is_binary(url) and url != "" ->
        url

      _ ->
        # 2. First img src in description
        case Floki.parse_fragment(description) do
          {:ok, fragment} ->
            case Floki.find(fragment, "img") |> Floki.attribute("src") do
              [src | _] when is_binary(src) and src != "" -> src
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp parse_datetime(""), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_datetime(str) when is_binary(str) do
    # Try RFC 1123 / 822 format (e.g. "Sun, 18 Oct 2026 16:37:58 +0200")
    # or ISO 8601
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        DateTime.truncate(dt, :second)

      _ ->
        case parse_rfc2822(str) do
          {:ok, dt} -> dt
          _ -> DateTime.utc_now() |> DateTime.truncate(:second)
        end
    end
  end

  defp parse_rfc2822(str) do
    # Parse e.g. "Sun, 18 Oct 2026 16:37:58 +0200" or "18 Oct 2026 16:37:58 +0200"
    regex =
      ~r/(?:[A-Za-z]{3},\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4}|GMT|UTC)?/

    with [_, day, month_str, year, hour, min, sec | tz_rest] <- Regex.run(regex, str),
         month <- month_name_to_int(month_str),
         true <- month != nil,
         {:ok, date} <-
           Date.new(
             String.to_integer(year),
             month,
             String.to_integer(day)
           ),
         {:ok, time} <-
           Time.new(
             String.to_integer(hour),
             String.to_integer(min),
             String.to_integer(sec)
           ),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      tz = List.first(tz_rest) || "+0000"
      offset_seconds = parse_tz_offset(tz)

      # Convert naive + offset into UTC DateTime
      utc_naive = NaiveDateTime.add(naive, -offset_seconds, :second)
      {:ok, DateTime.from_naive!(utc_naive, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp month_name_to_int(m) do
    case String.downcase(m) do
      "jan" -> 1
      "feb" -> 2
      "mar" -> 3
      "apr" -> 4
      "may" -> 5
      "jun" -> 6
      "jul" -> 7
      "aug" -> 8
      "sep" -> 9
      "oct" -> 10
      "nov" -> 11
      "dec" -> 12
      _ -> nil
    end
  end

  defp parse_tz_offset("+0000"), do: 0
  defp parse_tz_offset("-0000"), do: 0
  defp parse_tz_offset("GMT"), do: 0
  defp parse_tz_offset("UTC"), do: 0

  defp parse_tz_offset(<<sign::binary-size(1), h::binary-size(2), m::binary-size(2)>>) do
    hours = String.to_integer(h)
    mins = String.to_integer(m)
    total = hours * 3600 + mins * 60

    if sign == "-", do: -total, else: total
  end

  defp parse_tz_offset(_), do: 0
end
