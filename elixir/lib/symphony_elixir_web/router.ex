defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :project do
    plug(SymphonyElixirWeb.ProjectContext)
  end

  pipeline :management do
    plug(SymphonyElixirWeb.ManagementAccess)
  end

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:project, :browser])

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:project, :management, :browser])
    live("/usage", UsageLive, :index)
    live("/settings/notifications", ManagementLive, :index)
    live("/reports", ManagementLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:project, :management])
    get("/api/v1/usage", UsageApiController, :summary)
    get("/api/v1/usage/sessions", UsageApiController, :sessions)
  end

  scope "/projects/:project_id", SymphonyElixirWeb do
    pipe_through([:project, :browser])
    live("/", DashboardLive, :index)
  end

  scope "/projects/:project_id", SymphonyElixirWeb do
    pipe_through([:project, :management, :browser])
    live("/usage", UsageLive, :index)
    live("/reports", ManagementLive, :index)
    live("/settings/notifications", ManagementLive, :index)
  end

  scope "/api/v1/projects/:project_id", SymphonyElixirWeb do
    pipe_through(:project)
    get("/state", ObservabilityApiController, :state)
    post("/refresh", ObservabilityApiController, :refresh)
    get("/issues/:issue_identifier", ObservabilityApiController, :issue)
  end

  scope "/api/v1/projects/:project_id", SymphonyElixirWeb do
    pipe_through([:project, :management])
    get("/settings", ProjectsApiController, :settings)
    get("/settings/notifications", ProjectsApiController, :settings)
    get("/reports", ProjectsApiController, :reports)
    get("/usage", UsageApiController, :summary)
    get("/usage/sessions", UsageApiController, :sessions)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/projects", ProjectsApiController, :index)
    get("/api/v1/health", ProjectsApiController, :health)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:project)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
