defmodule DealScout.Deals.CrossBorderGuard do
  @moduledoc """
  Detects cross-border EU deliveries (Amazon FR, ES, IT, UK, etc.)
  and warns about foreign keyboard layouts (AZERTY, QWERTY-ES, etc.).
  """

  @keyboard_hardware_pattern ~r/\b(laptop|notebook|macbook|thinkpad|zenbook|ideapad|tastatur|keyboard|chromebook)\b/iu

  @doc """
  Detects the origin country of a deal based on URL and text markers.
  Returns `%{code: string, flag: string, name: string}` or `nil`.
  """
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
          flag: (country && country.flag) || "⚠️",
          message: "⚠️ Non-German Keyboard Layout detected (not DE-QWERTZ)"
        }

      # 2. Hardware originating from non-DE/AT regions
      (is_hardware? and country) && country.code in ["FR", "ES", "IT", "UK", "US"] ->
        layout_info(country)

      true ->
        nil
    end
  end

  defp layout_info(%{code: "FR", flag: flag}) do
    %{
      layout: "AZERTY",
      flag: flag,
      message: "⚠️ Foreign Keyboard Layout (AZERTY likely, not DE-QWERTZ)"
    }
  end

  defp layout_info(%{code: "ES", flag: flag}) do
    %{
      layout: "QWERTY-ES",
      flag: flag,
      message: "⚠️ Foreign Keyboard Layout (QWERTY-ES likely, not DE-QWERTZ)"
    }
  end

  defp layout_info(%{code: "IT", flag: flag}) do
    %{
      layout: "QWERTY-IT",
      flag: flag,
      message: "⚠️ Foreign Keyboard Layout (QWERTY-IT likely, not DE-QWERTZ)"
    }
  end

  defp layout_info(%{code: "UK", flag: flag}) do
    %{
      layout: "UK-QWERTY",
      flag: flag,
      message: "⚠️ Foreign Keyboard Layout & UK Plug (UK-QWERTY / 3-Pin)"
    }
  end

  defp layout_info(%{code: "US", flag: flag}) do
    %{
      layout: "US-ANSI",
      flag: flag,
      message: "⚠️ Foreign Keyboard Layout (US-ANSI QWERTY, not DE-QWERTZ)"
    }
  end

  defp layout_info(_) do
    %{
      layout: "Non-German",
      flag: "⚠️",
      message: "⚠️ Non-German Keyboard Layout (not DE-QWERTZ)"
    }
  end

  defp get_val(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_val(_, _), do: nil
end
