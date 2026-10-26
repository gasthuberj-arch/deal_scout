defmodule DealScout.Deals.CrossBorder do
  @moduledoc """
  Pure helper module for detecting cross-border EU deliveries and foreign keyboard layouts.
  Invoked privately within Deal ingestion to persist metadata onto `%Deal{}` records.
  """

  @keyboard_hardware_pattern ~r/\b(laptop|notebook|macbook|thinkpad|zenbook|ideapad|tastatur|keyboard|chromebook)\b/iu

  @doc """
  Enriches a deal struct or candidate map with precomputed country and keyboard layout flags.
  """
  def enrich(%DealScout.Deals.Deal{} = deal) do
    country = detect_country(deal)
    keyboard_warning = keyboard_warning(deal)

    %{deal | country: country, keyboard_warning: keyboard_warning}
  end

  def enrich(deal), do: deal

  @doc """
  Detects the origin country of a deal based on URL and text markers.
  Returns `%{code: string, flag: string, name: string}` or `nil`.
  """
  def detect_country(%{country: country}) when not is_nil(country), do: country

  def detect_country(deal_or_attrs) do
    url = get_val(deal_or_attrs, :url) || ""
    title = get_val(deal_or_attrs, :title) || ""
    clean_text = get_val(deal_or_attrs, :clean_text) || ""
    text = "#{title} #{clean_text}"

    host =
      case URI.parse(url) do
        %URI{host: h} when is_binary(h) -> String.downcase(h)
        _ -> ""
      end

    cond do
      # France
      String.contains?(host, "amazon.fr") or String.contains?(host, "dealabs.com") or
        String.contains?(host, "fnac.com") or
          Regex.run(~r/\[amazon\.fr\]|amazon\s+fr|amazon\s+frankreich|dealabs/iu, text) ->
        %{code: "FR", flag: "🇫🇷", name: "France"}

      # Spain
      String.contains?(host, "amazon.es") or String.contains?(host, "chollometro.com") or
          Regex.run(~r/\[amazon\.es\]|amazon\s+es|amazon\s+spanien/iu, text) ->
        %{code: "ES", flag: "🇪🇸", name: "Spain"}

      # Italy
      String.contains?(host, "amazon.it") or
          Regex.run(~r/\[amazon\.it\]|amazon\s+it|amazon\s+italien/iu, text) ->
        %{code: "IT", flag: "🇮🇹", name: "Italy"}

      # United Kingdom
      String.contains?(host, "amazon.co.uk") or
          Regex.run(~r/\[amazon\.co\.uk\]|amazon\s+uk/iu, text) ->
        %{code: "UK", flag: "🇬🇧", name: "UK"}

      # Austria
      String.contains?(host, "preisjaeger.at") or String.contains?(host, "amazon.at") ->
        %{code: "AT", flag: "🇦🇹", name: "Austria"}

      # United States / Reddit global
      String.contains?(host, "amazon.com") or String.contains?(host, "newegg.com") or
        String.contains?(host, "bestbuy.com") or String.contains?(host, "reddit.com") ->
        %{code: "US", flag: "🇺🇸", name: "US / Global"}

      true ->
        nil
    end
  end

  @doc """
  Returns keyboard warning details if an imported deal is a laptop or keyboard.
  Returns `%{layout: string, flag: string, message: string}` or `nil`.
  """
  def keyboard_warning(%{keyboard_warning: kw}) when not is_nil(kw), do: kw

  def keyboard_warning(deal_or_attrs) do
    country = detect_country(deal_or_attrs)
    title = get_val(deal_or_attrs, :title) || ""
    clean_text = get_val(deal_or_attrs, :clean_text) || ""
    text = "#{title} #{clean_text}"
    is_hardware? = Regex.run(@keyboard_hardware_pattern, text) != nil

    cond do
      # 1. Explicit layout markers in text
      Regex.run(
        ~r/\b(azerty|qwerty|ansi|us-layout|uk-layout|französisches\s+layout|spanisches\s+layout|italienisches\s+layout)\b/iu,
        text
      ) ->
        %{
          layout: "Non-German",
          flag: (country && country[:flag]) || (country && country["flag"]) || "⚠️",
          message: "⚠️ Non-German Keyboard Layout detected (not DE-QWERTZ)"
        }

      # 2. Hardware deal from Amazon FR (default layout is AZERTY)
      country_code(country) == "FR" and is_hardware? ->
        %{
          layout: "AZERTY",
          flag: "🇫🇷",
          message: "🇫🇷 Import warning: French hardware typically ships with AZERTY layout"
        }

      # 3. Hardware deal from Amazon ES (default layout is Spanish QWERTY)
      country_code(country) == "ES" and is_hardware? ->
        %{
          layout: "QWERTY-ES",
          flag: "🇪🇸",
          message: "🇪🇸 Import warning: Spanish hardware typically ships with QWERTY-ES layout"
        }

      # 4. Hardware deal from Amazon IT (default layout is Italian QWERTY)
      country_code(country) == "IT" and is_hardware? ->
        %{
          layout: "QWERTY-IT",
          flag: "🇮🇹",
          message: "🇮🇹 Import warning: Italian hardware typically ships with QWERTY-IT layout"
        }

      # 5. Hardware deal from Amazon UK (default layout is UK-QWERTY)
      country_code(country) == "UK" and is_hardware? ->
        %{
          layout: "QWERTY-UK",
          flag: "🇬🇧",
          message: "🇬🇧 Import warning: UK hardware typically ships with UK-QWERTY layout"
        }

      # 6. Hardware deal from US (default layout is US-ANSI)
      country_code(country) == "US" and is_hardware? ->
        %{
          layout: "ANSI-US",
          flag: "🇺🇸",
          message: "🇺🇸 Import warning: US hardware typically ships with US-ANSI layout"
        }

      true ->
        nil
    end
  end

  defp country_code(%{code: code}), do: code
  defp country_code(%{"code" => code}), do: code
  defp country_code(_), do: nil

  defp get_val(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_val(_, _), do: nil
end
