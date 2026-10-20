defmodule DealScoutWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import DealScoutWeb.ChannelCase

      @endpoint DealScoutWeb.Endpoint
    end
  end

  setup tags do
    DealScout.DataCase.setup_sandbox(tags)
    :ok
  end
end
