defmodule DealScout.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DealScoutWeb.Telemetry,
        DealScout.Repo,
        DealScout.Deals.StreamCache,
        DealScout.Deals.ImageCache,
        DealScout.Deals.ImageFetcher,
        DealScout.KeywordEngine.Server,
        DealScout.Analytics.Server,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:deal_scout, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:deal_scout, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DealScout.PubSub},
        DealScoutWeb.Presence,
        DealScout.Backup.Status,
        DealScout.Backup.Watcher,
        {Task.Supervisor, name: DealScout.Feeds.TaskSupervisor},
        # Internal Prometheus metrics listener on port 9091 (Fly internal 6PN scraper)
        {Bandit,
         plug: DealScout.MetricsPlug,
         scheme: :http,
         port: metrics_port(),
         ip: {0, 0, 0, 0, 0, 0, 0, 0}},
        # Start to serve requests, typically the last entry
        DealScoutWeb.Endpoint
      ] ++ background_workers()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DealScout.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DealScoutWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp metrics_port do
    Application.get_env(:deal_scout, :metrics_port, 9091)
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp background_workers() do
    if Application.get_env(:deal_scout, :start_feed_poller, true) do
      [
        {DealScout.Feeds.Poller, []},
        {DealScout.Maintenance.Pruner, []},
        {DealScout.Notifications.DigestWorker, []}
      ]
    else
      []
    end
  end
end
