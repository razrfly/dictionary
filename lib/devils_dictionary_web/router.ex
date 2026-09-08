defmodule DevilsDictionaryWeb.Router do
  use DevilsDictionaryWeb, :router

  import DevilsDictionaryWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DevilsDictionaryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DevilsDictionaryWeb do
    pipe_through :browser

    # The way in (#71 U2): search over the whole index, Surprise me, seed words.
    live "/", HomeLive, :show

    # The word page (#71 U1a, U1b, U2): a page for every one of the 1.5 million
    # index words, bare ones included, with the thing it names and the
    # provenance of every card.
    live "/define/:slug", WordLive, :show

    # The developer surfaces (#70 S4b).
    live "/s/:slug", ScopeLive, :show
    live "/sources/:slug", SourceLive, :show
    live "/health", HealthLive, :show
    live "/admin/imports", Admin.ImportsLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", DevilsDictionaryWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:devils_dictionary, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DevilsDictionaryWeb.Telemetry
    end

    # The theme boilerplate check (#71 §3, U0): the ported Oatmeal primitives,
    # to be held next to the kit's own demo. Never routed in production.
    scope "/", DevilsDictionaryWeb do
      pipe_through :browser

      live "/kit", KitLive, :show
    end
  end

  ## Authentication routes

  scope "/", DevilsDictionaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{DevilsDictionaryWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", DevilsDictionaryWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{DevilsDictionaryWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
