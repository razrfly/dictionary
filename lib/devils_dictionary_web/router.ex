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

  # The reader's addresses answer with the status their page deserves — a
  # 301 to the canonical, a 404, a 410 — before the LiveView renders (#219).
  pipeline :reading do
    plug DevilsDictionaryWeb.ReadingStatus
  end

  # What a crawler reads first (#237 C5): robots.txt from the switch, the
  # registry and the launch manifest; the sitemap index and the sitemaps
  # from the published canonical pages. No session, no layout.
  scope "/", DevilsDictionaryWeb do
    get "/robots.txt", RobotsController, :show
    get "/sitemap.xml", SitemapController, :index
    get "/sitemaps/:file", SitemapController, :show
  end

  scope "/", DevilsDictionaryWeb do
    pipe_through :browser

    # The way in (#71 U2): search over the whole index, Surprise me, seed words.
    live "/", HomeLive, :show

    # Saved, reusable works are local-first. The optional Artsy check on this
    # page is explicitly transient and never runs during a word-page render.
    live "/artworks", ArtworkLive, :index

    # One claim, from either endpoint, with its evidence, its review state and
    # its history (#74 §F's connection detail).
    live "/connections/:id", ConnectionLive, :show
    live "/evidence/content/:id", EvidenceLive, :content
    live "/evidence/sense/:id", EvidenceLive, :sense
    live "/evidence/source-record/:id", EvidenceLive, :source_record

    # A source's identity, licence and attribution are reader-facing provenance
    # — #69 backbone rule 1, the thing the footer's Sources column links to — so
    # this one stays public and stays put. Its *coverage* section is the part
    # that needs a population, and it now renders only when one is asked for.
    live "/sources/:slug", SourceLive, :show
  end

  scope "/", DevilsDictionaryWeb do
    pipe_through [:browser, :reading]

    # The reading entry (#219): **On** is the everyday lexical reader, and
    # there are two ways into a word, only one of them identity.
    #
    #   * `/on/:slug` is the aggregate: every word the slug reaches (C++, C+
    #     and c share `c`; Mars, mars and MARS share `mars`), under an
    #     authored overview when one is allocated at that address and names
    #     those words, with the subjects the page's sources and names reach.
    #     It needs no page row: an overview is optional.
    #   * `/words/:id/:slug` is the exact word, addressed by `object_id`
    #     (ADR 0004 decision 10), because a slug is a lossy label. A selected
    #     word goes here and survives a reload; a missing id is a 404, never
    #     a word found by the slug.
    #
    # `/define/:slug` is gone: nothing has been public, so nothing redirects.
    live "/on/:slug", WordLive, :on
    live "/words/:id/:slug", WordLive, :canonical

    # The thing page (#74 §F): one identity, asked different questions. Bierce's
    # biography, his works and his definitions are three sections of the same
    # object id, which is the whole of #74's goal 2. An id that names no
    # entity is 404 before the page renders (ADR 0004 §6).
    live "/entities/:id/:slug", EntityLive, :show

    # A subject's address (ADR 0004 §2, §6): eight explicit families, never a
    # catch-all prefix, each answered only by `Routing.Resolver` — the ledger
    # and nothing else. A subject with no address keeps
    # `/entities/:id/:slug`, the exact-identity route.
    live "/people/:slug", EntityLive, :subject
    live "/organizations/:slug", EntityLive, :subject
    live "/places/:slug", EntityLive, :subject
    live "/events/:slug", EntityLive, :subject
    live "/works/:slug", EntityLive, :subject
    live "/concepts/:slug", EntityLive, :subject
    live "/nature/:slug", EntityLive, :subject
    live "/subjects/:slug", EntityLive, :subject
  end

  # The developer surfaces (#70 S4b), moved off the public paths they used to
  # occupy (#77 §1). They were the whole of the navigation: one test population
  # and two consoles standing in for the product's structure.
  #
  # Deliberately **not** access-controlled and deliberately **not** behind
  # `dev_routes`. #77 is explicit that a diagnostic surface is not automatically
  # access-controlled and that the access policy is a separate decision; and
  # `/ops/health` is most wanted in exactly the environment a compile-time gate
  # would remove it from.
  scope "/ops", DevilsDictionaryWeb do
    pipe_through :browser

    live "/scopes/:slug", ScopeLive, :show
    live "/health", HealthLive, :show
    live "/imports", Admin.ImportsLive, :index
    live "/discovery", DiscoveryLive, :index
  end

  # The retired paths, redirected rather than deleted. Declared after the public
  # scope so nothing above is shadowed. See `OpsRedirectController` for why 302.
  scope "/", DevilsDictionaryWeb do
    pipe_through :browser

    get "/s/:slug", OpsRedirectController, :scope
    get "/health", OpsRedirectController, :health
    get "/admin/imports", OpsRedirectController, :imports
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
      forward "/mailbox", Plug.Swoosh.MailboxPreview
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
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_reviewer,
      on_mount: [{DevilsDictionaryWeb.UserAuth, :require_reviewer}] do
      live "/reconciliation", ReconciliationLive, :index
    end
  end

  scope "/", DevilsDictionaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_internal_contributor,
      on_mount: [{DevilsDictionaryWeb.UserAuth, :require_internal_contributor}] do
      # Proposing a connection is the one thing on this site that needs an
      # account: #74 asks for "a minimal authenticated submit/review flow", and
      # an anonymous claim has nobody to attribute it to.
      #
      # Registration does not grant this capability. The route is gated here,
      # on the server, for the internal contribution-testing account and
      # reviewers; hiding a button would not protect the write path.
      #
      # `/connect` rather than `/connections/new`: routes match in definition
      # order, and `/connections/:id` is declared in the public scope above, so
      # `new` would be read as an id and never reach this.
      live "/connect", ConnectionLive, :new
      live "/connections/:id/edit", ConnectionLive, :edit
      live "/connections/:id/challenge", ConnectionLive, :challenge
    end
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
