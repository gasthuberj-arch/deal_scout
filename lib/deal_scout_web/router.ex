defmodule DealScoutWeb.Router do
  use DealScoutWeb, :router

  import DealScoutWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DealScoutWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # API Routes
  scope "/api", DealScoutWeb do
    pipe_through :api

    get "/admin/backup", BackupController, :download
    get "/admin/backup/status", BackupController, :status
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:deal_scout, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DealScoutWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DealScoutWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{DealScoutWeb.UserAuth, :require_authenticated}] do
      live "/alerts", AlertLive.Index, :index
      live "/alerts/new", AlertLive.Index, :new
      live "/alerts/:id/edit", AlertLive.Index, :edit
      live "/matches", MatchLive.Index, :index
      live "/analytics", AnalyticsLive.Index, :index

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/admin", DealScoutWeb.Admin do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    live_session :require_admin_user,
      on_mount: [
        {DealScoutWeb.UserAuth, :require_authenticated},
        {DealScoutWeb.UserAuth, :require_admin}
      ] do
      live "/system", SystemLive.Index, :index
    end
  end

  scope "/", DealScoutWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{DealScoutWeb.UserAuth, :mount_current_scope}] do
      live "/", DealLive.Index, :index

      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
