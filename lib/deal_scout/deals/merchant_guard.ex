defmodule DealScout.Deals.MerchantGuard do
  @moduledoc """
  Rule engine for evaluating merchant trustworthiness, fake shop risks,
  and retailer classifications.
  """

  @verified_retailers [
    "amazon",
    "amazon.de",
    "mediamarkt",
    "saturn",
    "mindfactory",
    "alternate",
    "cyberport",
    "otto",
    "lidl",
    "edeka",
    "galaxus",
    "coolblue",
    "notebooksbilliger",
    "nbb",
    "kaufland",
    "decathlon",
    "bauhaus",
    "hornbach",
    "obi",
    "rewe",
    "aldi",
    "aldi süd",
    "aldi nord",
    "conrad",
    "caseking",
    "expert",
    "euronics",
    "proshop",
    "gog",
    "steam",
    "playstation direct",
    "xbox",
    "apple",
    "samsung",
    "lenovo",
    "dell",
    "ikea",
    "zalando",
    "about you",
    "douglas",
    "rossmann",
    "dm"
  ]

  @dropshippers [
    "temu",
    "aliexpress",
    "ali express",
    "wish",
    "shein",
    "dhgate",
    "banggood",
    "lightinthebox"
  ]

  @suspicious_tlds ~w(.top .xyz .buzz .cam .icu .loan .cfd .rest .sbs .click .monster)

  @high_risk_patterns [
    ~r/\bnur\s+vorkasse\b/iu,
    ~r/\bnur\s+überweisung\b/iu,
    ~r/\bkein\s+käuferschutz\b/iu,
    ~r/\bfakeshop\b/iu,
    ~r/\bfake-shop\b/iu,
    ~r/\bbetrug\b/iu
  ]

  @aggregator_domains [
    "mydealz.de",
    "dealdoktor.de",
    "monsterdealz.de",
    "schnaeppchenfuchs.com",
    "mein-deal.com",
    "preisjaeger.at",
    "dealabs.com",
    "chollometro.com",
    "pepper.com",
    "gg.deals"
  ]

  @doc """
  Classifies a merchant based on name, URL, and context text.
  Returns "verified", "dropshipper", "high_risk", or "unverified".
  """
  def classify(merchant_name, url \\ nil, context_text \\ nil) do
    norm_name = normalize_name(merchant_name)
    domain = extract_domain(url)

    cond do
      matches_dropshipper?(norm_name, domain) ->
        "dropshipper"

      matches_high_risk?(norm_name, domain, context_text) ->
        "high_risk"

      matches_verified?(norm_name, domain) ->
        "verified"

      true ->
        "unverified"
    end
  end

  @doc """
  Checks if a given name or domain is verified.
  """
  def verified?(merchant_name, url \\ nil) do
    classify(merchant_name, url) == "verified"
  end

  @doc """
  Checks if a given merchant is high risk.
  """
  def high_risk?(merchant_name, url \\ nil, context_text \\ nil) do
    classify(merchant_name, url, context_text) == "high_risk"
  end

  @doc """
  Checks if a merchant is a dropshipper.
  """
  def dropshipper?(merchant_name, url \\ nil) do
    classify(merchant_name, url) == "dropshipper"
  end

  @doc """
  Normalizes a merchant name string.
  """
  def normalize_name(nil), do: ""

  def normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/^(https?:\/\/)?(www\.)?/, "")
    |> String.replace(~r/\.de$|\.com$|\.at$|\.eu$/i, "")
    |> String.trim()
  end

  @doc """
  Generates a URL-safe slug from a merchant name.
  """
  def slugify(nil), do: "unknown"
  def slugify(""), do: "unknown"

  def slugify(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace("ä", "ae")
      |> String.replace("ö", "oe")
      |> String.replace("ü", "ue")
      |> String.replace("ß", "ss")
      |> String.replace(~r/[^a-z0-9]+/i, "-")
      |> String.trim("-")

    if slug == "", do: "unknown", else: slug
  end

  @doc """
  Extracts the merchant root domain from a URL, ignoring aggregator domains.
  """
  def extract_domain(nil), do: nil
  def extract_domain(""), do: nil

  def extract_domain(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        clean_host =
          host
          |> String.downcase()
          |> String.replace(~r/^www\./, "")

        if clean_host in @aggregator_domains do
          nil
        else
          clean_host
        end

      _ ->
        nil
    end
  end

  defp matches_verified?(norm_name, domain) do
    down_name = String.downcase(norm_name)

    Enum.any?(@verified_retailers, fn v ->
      down_name == v ||
        String.starts_with?(down_name, v <> " ") ||
        (is_binary(domain) && String.contains?(domain, v))
    end)
  end

  defp matches_dropshipper?(norm_name, domain) do
    down_name = String.downcase(norm_name)

    Enum.any?(@dropshippers, fn d ->
      down_name == d ||
        String.contains?(down_name, d) ||
        (is_binary(domain) && String.contains?(domain, d))
    end)
  end

  defp matches_high_risk?(_norm_name, domain, context_text) do
    has_suspicious_tld? =
      is_binary(domain) && Enum.any?(@suspicious_tlds, &String.ends_with?(domain, &1))

    has_risk_text? =
      is_binary(context_text) &&
        Enum.any?(@high_risk_patterns, &Regex.run(&1, context_text))

    has_suspicious_tld? == true || has_risk_text? == true
  end
end
