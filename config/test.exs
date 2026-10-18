import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :deal_scout, DealScout.Repo,
  database: Path.expand("../deal_scout_test.db", __DIR__),
  pool_size: 5,
  busy_timeout: 10_000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :deal_scout, DealScoutWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bII2ZfvIZ5QAbhF4guaH0DHJp2I3Grydo7/wUMKzu9sVf1XemODv47ZAAdg9nV+5",
  server: false

# In test we don't send emails
config :deal_scout, DealScout.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Disable background feed poller & in-memory cache in test
config :deal_scout, start_feed_poller: false, start_deals_cache: false
