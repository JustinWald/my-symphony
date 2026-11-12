defmodule SymphonyElixirWeb.UsageLive do
  @moduledoc "Native durable usage history with UTC date filters and pagination."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixir.Management.UsageHistory

  @impl true
  def mount(params, _session, socket) do
    SymphonyElixir.Project.mount(params)
    today = Date.utc_today()

    socket =
      assign(socket,
        from: Date.to_iso8601(Date.add(today, 1 - Date.day_of_week(today))),
        until: Date.to_iso8601(Date.add(today, 1)),
        page: 1,
        totals: nil,
        sessions: [],
        error: nil
      )

    if connected?(socket), do: Process.send_after(self(), :refresh, 5_000)
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "until" => until}, socket) do
    {:noreply, socket |> assign(from: from, until: until, page: 1) |> load()}
  end

  def handle_event("next", _, socket), do: {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load()}

  def handle_event("previous", _, socket),
    do: {:noreply, socket |> assign(:page, max(1, socket.assigns.page - 1)) |> load()}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell management-console">
      <header class="hero-card">
        <a href={SymphonyElixir.Project.path("")}>← Operations dashboard</a>
        <h1 class="hero-title">Usage history</h1>
        <p>Durable token observations. Times and date filters use UTC; the end date is exclusive.</p>
        <p>Token-based costs are estimates, not billed subscription charges.</p>
      </header>
      <form phx-submit="filter">
        <label>From <input type="date" name="from" value={@from} required /></label>
        <label>Until <input type="date" name="until" value={@until} required /></label>
        <button type="submit">Apply dates</button>
      </form>
      <p :if={@error} role="status">{@error}</p>
      <section :if={@totals}>
        <h2>Observed usage</h2>
        <p>Input: {@totals.input} · Output: {@totals.output} · Cached: {@totals.cached}</p>
        <p :if={@totals.cached_unknown}>Cached input data is incomplete.</p>
        <p>Estimated cost: <%= if @totals.estimated_cost.incomplete do %>Unknown or incomplete; configured-rate subtotal <%= @totals.estimated_cost.minimum %>–<%= @totals.estimated_cost.maximum %><% else %><%= @totals.estimated_cost.minimum %>–<%= @totals.estimated_cost.maximum %><% end %> (rate card: {@totals.estimated_cost.rate_card_version}).</p>
        <p :if={@totals.incomplete_sessions > 0}>Missing or incomplete telemetry: {@totals.incomplete_sessions} sessions. Observed totals do not imply complete usage.</p>
        <h2>By model</h2>
        <table><thead><tr><th>Model</th><th>Input</th><th>Output</th></tr></thead><tbody>
          <tr :for={{model, totals} <- Enum.sort(@totals.by_model)}><td>{model}</td><td>{totals.input}</td><td>{totals.output}</td></tr>
        </tbody></table>
        <h2>By issue</h2>
        <table><thead><tr><th>Issue</th><th>Input</th><th>Output</th></tr></thead><tbody>
          <tr :for={{issue, totals} <- Enum.sort(@totals.by_issue)}><td>{issue}</td><td>{totals.input}</td><td>{totals.output}</td></tr>
        </tbody></table>
        <h2>Sessions</h2>
        <p>Session rows show cumulative observed counters; the totals above show increments within the selected dates.</p>
        <p :if={@sessions == []}>No session observations in this range.</p>
        <table :if={@sessions != []}>
          <thead><tr><th>Session</th><th>Issue</th><th>Model</th><th>Effort</th><th>Input</th><th>Output</th><th>Runtime seconds</th><th>Failures</th><th>Completeness</th><th>Last observed</th></tr></thead>
          <tbody><tr :for={row <- @sessions}>
            <td>{row["session"]}</td><td>{row["issue"] || "Unknown"}</td>
            <td>{row["model"] || "Unknown"}</td><td>{row["effort"] || "Unknown"}</td>
            <td>{row["input_tokens"] || "Unknown"}</td><td>{row["output_tokens"] || "Unknown"}</td><td>{row["runtime_seconds"] || "Unknown"}</td><td>{row["failures"]}</td><td>{if row["incomplete"], do: "Incomplete", else: "Finished"}</td><td>{row["observed_at"]}</td>
          </tr></tbody>
        </table>
        <button phx-click="previous" disabled={@page == 1}>Previous</button>
        <span>Page {@page}</span>
        <button phx-click="next" disabled={length(@sessions) < 50}>Next</button>
      </section>
    </section>
    """
  end

  defp load(socket) do
    with {:ok, from} <- Date.from_iso8601(socket.assigns.from),
         {:ok, until} <- Date.from_iso8601(socket.assigns.until),
         true <- Date.compare(from, until) == :lt do
      if SymphonyElixir.Project.whereis(SymphonyElixir.Project.name(SymphonyElixir.Management.Repo)) do
        from = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
        until = DateTime.new!(until, ~T[00:00:00], "Etc/UTC")

        assign(socket,
          totals: UsageHistory.summary(from, until),
          sessions: UsageHistory.sessions(from, until, socket.assigns.page),
          error: nil
        )
      else
        assign(socket, totals: nil, sessions: [], error: "Management storage is not enabled.")
      end
    else
      _ -> assign(socket, totals: nil, sessions: [], error: "Choose a valid date range.")
    end
  end
end
