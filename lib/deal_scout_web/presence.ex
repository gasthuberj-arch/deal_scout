defmodule DealScoutWeb.Presence do
  @moduledoc """
  Provides real-time presence tracking of active connected sessions.
  """
  use Phoenix.Presence,
    otp_app: :deal_scout,
    pubsub_server: DealScout.PubSub
end
