defmodule DealScout.Repo do
  use Ecto.Repo,
    otp_app: :deal_scout,
    adapter: Ecto.Adapters.SQLite3
end
