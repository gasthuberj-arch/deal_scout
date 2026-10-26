defmodule DealScout.Deals.CrossBorderGuard do
  @moduledoc """
  Backward compatibility module delegating to `DealScout.Deals.CrossBorder`.
  """

  defdelegate enrich(deal), to: DealScout.Deals.CrossBorder
  defdelegate detect_country(deal), to: DealScout.Deals.CrossBorder
  defdelegate keyboard_warning(deal), to: DealScout.Deals.CrossBorder
end
