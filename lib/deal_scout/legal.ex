defmodule DealScout.Legal do
  @moduledoc """
  Provides configuration and operator metadata for legal pages (Impressum and Privacy Policy).

  Allows self-hosters and maintainers to customize the displayed operator details
  via environment variables without hardcoding personal data into the source code.
  """

  @doc """
  Returns the operator or maintainer name.
  """
  def operator_name do
    get_config(:operator_name, "DealScout Maintainer")
  end

  @doc """
  Returns the public operator contact email address.
  """
  def operator_email do
    get_config(:operator_email, "support@example.com")
  end

  @doc """
  Returns the postal address or project location description.
  """
  def operator_address do
    get_config(:operator_address, "Privates Open-Source-Projekt")
  end

  defp get_config(key, default) do
    case Application.get_env(:deal_scout, __MODULE__) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _ -> default
    end
  end
end
