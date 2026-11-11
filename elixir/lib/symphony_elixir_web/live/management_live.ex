defmodule SymphonyElixirWeb.ManagementLive do
  @moduledoc "Native reports, delivery state, audit decisions and notification settings."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixir.Management.{Audit, Delivery, Proposals, Reports, Settings, Store}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 5_000)
    {:ok, load(assign(socket, notice: nil, preview: nil))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("save", params, socket) do
    changes = %{
      "email_sender" => params["sender"] || "",
      "email_recipients" => String.split(params["recipients"] || "", ~r/[,\s]+/, trim: true),
      "m365_tenant" => params["tenant"] || "",
      "m365_client" => params["client"] || "",
      "github_auth_mode" => params["github_auth_mode"],
      "delivery_enabled" => params["delivery"] == "true",
      "publish_enabled" => params["publish"] == "true",
      "weekly" => %{
        "enabled" => params["weekly"] == "true",
        "day" => params["day"],
        "time" => params["time"],
        "timezone" => params["timezone"]
      },
      "notifications" =>
        Map.new(~w(email slack), fn channel ->
          {channel, Map.new(~w(enabled handoffs blockers weekly), &{&1, params[channel <> "_" <> &1] == "true"})}
        end),
      "audit" => audit_changes(params, socket.assigns.settings)
    }

    credentials = credential_changes(params)

    notice =
      case Settings.save(changes, credentials) do
        :ok -> "Settings saved and applied."
        {:error, message} -> message
      end

    {:noreply, load(assign(socket, :notice, notice))}
  end

  def handle_event("test", %{"channel" => channel}, socket) do
    notice =
      case Delivery.test(channel) do
        :ok -> "Provider accepted the test request; check its destination to confirm receipt."
        {:error, message} -> message
      end

    {:noreply, load(assign(socket, :notice, notice))}
  end

  def handle_event("preview", _params, socket), do: {:noreply, assign(socket, :preview, Reports.preview())}

  def handle_event("audit_now", _params, socket) do
    notice =
      if get_in(Settings.config(), ["audit", "enabled"]) == true do
        Task.Supervisor.start_child(SymphonyElixir.Management.Tasks, fn ->
          Reports.weekly(DateTime.utc_now(), notify: false)
          Audit.run()
          Proposals.prepare()
        end)

        "Audit requested; its budget and validation policy still apply."
      else
        "Enable analysis before requesting an audit."
      end

    {:noreply, assign(socket, :notice, notice)}
  end

  def handle_event("rates", params, socket) do
    with {input, ""} when input >= 0 <- Float.parse(params["input"] || ""),
         {output, ""} when output >= 0 <- Float.parse(params["output"] || ""),
         {cached, ""} when cached >= 0 <- Float.parse(params["cached"] || "") do
      change = %{
        "rate_card" => %{
          "version" => params["version"],
          "models" => %{params["model"] => %{"input" => input, "output" => output, "cached_input" => cached}}
        }
      }

      notice =
        case Settings.save(change) do
          :ok -> "Rates saved for future observations; historical prices are preserved."
          {:error, message} -> message
        end

      {:noreply, load(assign(socket, :notice, notice))}
    else
      _ -> {:noreply, assign(socket, :notice, "Enter nonnegative rates per million tokens.")}
    end
  end

  def handle_event("replay", %{"id" => id}, socket) do
    Delivery.replay(id)
    {:noreply, load(assign(socket, :notice, "Delivery queued for retry."))}
  end

  def handle_event("decision", %{"proposal_id" => id, "state" => state, "note" => note}, socket)
      when state in ["proposed", "evaluating", "promoted", "rejected"] do
    if String.trim(note) != "" do
      Store.query!("UPDATE proposals SET status=? WHERE id=?", [state, id])

      Store.event(
        "recommendation:" <> id <> ":" <> Integer.to_string(System.unique_integer([:positive])),
        "recommendation",
        %{id: id, status: state, note: note},
        nil,
        DateTime.utc_now()
      )
    end

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell management-console">
      <header class="hero-card"><a href="/">Operations</a> · <a href="/usage">Usage</a><h1 class="hero-title">Reports and notifications</h1></header>
      <p role="status">{@notice}</p>
      <p :if={!@settings}>Management storage is not enabled.</p>
      <section :if={@settings}>
        <section><h2>Health</h2>
          <p>Last collection: {@health.collector}</p><p>Tracker observation: {@health.github}</p>
          <p>Orchestrator: {@health.runtime}</p><p>Last audit outcome: {@health.audit}</p>
          <p>Last publication error: {@health.publication}</p>
        </section>
        <form phx-submit="save" autocomplete="off">
          <h2>Notifications</h2>
          <label><input type="checkbox" name="delivery" value="true" checked={@settings["delivery_enabled"] == true} /> Enable delivery</label>
          <label><input type="checkbox" name="publish" value="true" checked={@settings["publish_enabled"] == true} /> Publish reports to GitHub</label>
          <p><label>Sender <input name="sender" type="email" value={@settings["email_sender"]} /></label></p>
          <p><label>Recipients <input name="recipients" value={Enum.join(@settings["email_recipients"] || [], ", ")} /></label></p>
          <p><label>Microsoft tenant <input name="tenant" value={@settings["m365_tenant"]} /></label></p>
          <p><label>Microsoft application <input name="client" value={@settings["m365_client"]} /></label></p>
          <p><label>Microsoft application secret <input name="m365_secret" type="password" value="" placeholder="Leave blank to keep existing" /></label></p>
          <p><label>Slack incoming webhook <input name="slack_webhook" type="password" value="" placeholder="Leave blank to keep existing" /></label></p>
          <p><label>GitHub access <select name="github_auth_mode"><option value="symphony" selected={@settings["github_auth_mode"] == "symphony"}>Use Symphony credentials</option><option value="separate" selected={@settings["github_auth_mode"] != "symphony"}>Separate credential</option></select></label></p>
          <p><label>Separate GitHub token <input name="github_token" type="password" value="" placeholder="Leave blank to keep existing" /></label></p>
          <fieldset :for={channel <- ~w(email slack)}>
            <legend>{String.capitalize(channel)} preferences</legend>
            <label :for={flag <- ~w(enabled handoffs blockers weekly)}>
              <input type="checkbox" name={channel <> "_" <> flag} value="true" checked={get_in(@settings, ["notifications", channel, flag]) != false} />
              {String.capitalize(flag)}
            </label>
          </fieldset>
          <p>Test actions send only the requested message and do not change notification preferences.</p>
          <button type="button" phx-click="test" phx-value-channel="email" phx-disable-with="Sending...">Send test email</button>
          <button type="button" phx-click="test" phx-value-channel="slack" phx-disable-with="Sending...">Send test Slack message</button>
          <h2>Weekly heartbeat</h2>
          <label><input type="checkbox" name="weekly" value="true" checked={get_in(@settings, ["weekly", "enabled"]) != false} /> Enable weekly report</label>
          <label>Day <select name="day"><option :for={day <- ~w(Mon Tue Wed Thu Fri Sat Sun)} value={day} selected={day == (get_in(@settings, ["weekly", "day"]) || "Mon")}>{day}</option></select></label>
          <label>Time <input type="time" name="time" value={get_in(@settings, ["weekly", "time"]) || "09:00"} /></label>
          <label>Timezone <input name="timezone" value={get_in(@settings, ["weekly", "timezone"]) || "UTC"} /></label>
          <h2>Improvement audits</h2>
          <label><input type="checkbox" name="audit" value="true" checked={get_in(@settings, ["audit", "enabled"]) == true} /> Enable bounded analysis</label>
          <label><input type="checkbox" name="draft_prs" value="true" checked={get_in(@settings, ["audit", "draft_prs"]) == true} /> Prepare validated draft PRs for human review</label>
          <p>Audit model settings apply to analysis only; coding workers keep their own model configuration.</p>
          <label>Analysis model <input name="audit_model" value={get_in(@settings, ["audit", "model"]) || "gpt-6.1-sol"} /></label>
          <label>Reasoning effort <select name="audit_effort"><option :for={effort <- ~w(none low medium high xhigh max)} value={effort} selected={effort == (get_in(@settings, ["audit", "effort"]) || "high")}>{effort}</option></select></label>
          <label>Maximum seconds per call <input name="audit_timeout" type="number" min="30" max="900" value={get_in(@settings, ["audit", "timeout_seconds"]) || 600} /></label>
          <label>Maximum calls per week <input name="audit_budget" type="number" min="1" max="3" value={get_in(@settings, ["audit", "max_calls_per_week"]) || 2} /></label>
          <fieldset><legend>Stored credentials</legend>
            <p :for={name <- ~w(m365_secret slack_webhook github_token)}>
              {String.replace(name, "_", " ")}: {if @settings["credentials"][name], do: "Configured", else: "Not configured"}
              <label><input type="checkbox" name={"remove_" <> name} value="true" /> Remove stored value</label>
            </p>
          </fieldset>
          <p><button type="submit">Save and apply</button></p>
        </form>
        <h2>Model rate card</h2>
        <p>Configured estimates per million tokens. These are usage proxies, not subscription invoices. Saving rates preserves earlier pricing snapshots.</p>
        <form phx-submit="rates">
          <label>Version <input name="version" required /></label>
          <label>Model <input name="model" required /></label>
          <label>Input <input name="input" type="number" min="0" step="any" required /></label>
          <label>Cached input <input name="cached" type="number" min="0" step="any" required /></label>
          <label>Output <input name="output" type="number" min="0" step="any" required /></label>
          <button>Save model rates</button>
        </form>
        <h2>Delivery history</h2>
        <p :if={@deliveries == []}>No deliveries recorded.</p>
        <table><thead><tr><th>Subject</th><th>Channel</th><th>Status</th><th>Attempts</th><th>Last error</th><th>Action</th></tr></thead><tbody>
          <tr :for={row <- @deliveries}><td>{row["subject"]}</td><td>{row["channel"]}</td><td>{row["status"]}</td><td>{row["attempts"]}</td><td>{row["error"] || ""}</td><td><button :if={row["status"] in ["failed", "suppressed"]} phx-click="replay" phx-value-id={row["id"]}>Retry</button></td></tr>
        </tbody></table>
        <button phx-click="preview">Preview weekly report</button>
        <pre :if={@preview}>{@preview}</pre>
        <h2>Weekly reports</h2>
        <article :for={row <- @reports}><h3>{row["week"]}</h3><pre>{row["body"]}</pre><p>{row["audit"]}</p><a :if={row["url"]} href={row["url"]}>Published report</a></article>
        <button phx-click="audit_now" disabled={get_in(@settings, ["audit", "enabled"]) != true}>Run audit now</button>
        <h2>Recommendations</h2>
        <article :for={row <- @proposals}><h3>{row["recommendation"]["title"] || row["id"]} — {row["status"]}</h3>
          <dl><div :for={field <- ~w(hypothesis evidence evaluation quality_guardrails promotion rollback tradeoff)}><dt>{String.replace(field, "_", " ")}</dt><dd>{row["recommendation"][field]}</dd></div></dl><a :if={row["url"]} href={row["url"]}>Draft proposal</a>
          <form phx-submit="decision"><input type="hidden" name="proposal_id" value={row["id"]} /><label>Decision <select name="state"><option :for={state <- ~w(proposed evaluating promoted rejected)} value={state}>{state}</option></select></label><label>Evaluation evidence <textarea name="note" required></textarea></label><button>Record decision</button></form>
        </article>
      </section>
    </section>
    """
  end

  defp proposals do
    Store.rows("SELECT id,status,url,data FROM proposals ORDER BY week DESC LIMIT 100")
    |> Enum.map(&Map.put(&1, "recommendation", Jason.decode!(&1["data"])))
  end

  defp health do
    %{
      collector: Store.get("collector_at", "Not observed"),
      github: Store.get("github_health", %{})["status"] || "Not observed",
      runtime: Store.get("runtime", %{})["api"] || "Not observed",
      audit: Store.get("audit_health", "Not observed"),
      publication: Store.get("publication_health", "None recorded")
    }
  end

  defp audit_changes(params, settings) do
    previous = settings["audit"] || %{}

    %{
      "enabled" => params["audit"] == "true",
      "draft_prs" => params["draft_prs"] == "true",
      "model" => params["audit_model"] || previous["model"] || "gpt-6.1-sol",
      "effort" => params["audit_effort"] || previous["effort"] || "high",
      "timeout_seconds" => number(params["audit_timeout"], previous["timeout_seconds"] || 600),
      "max_calls_per_week" => number(params["audit_budget"], previous["max_calls_per_week"] || 2)
    }
  end

  defp credential_changes(params) do
    credentials =
      Map.take(params, ~w(slack_webhook m365_secret github_token)) |> Map.reject(fn {_, value} -> value == "" end)

    Enum.reduce(~w(slack_webhook m365_secret github_token), credentials, fn key, acc ->
      if params["remove_" <> key] == "true", do: Map.put(acc, key, ""), else: acc
    end)
  end

  defp number(nil, default), do: default

  defp number(value, _default) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> :invalid
    end
  end

  defp load(socket) do
    if Process.whereis(SymphonyElixir.Management.Repo) do
      assign(socket,
        settings: Settings.public(),
        deliveries: Store.rows("SELECT id,subject,channel,status,attempts,error FROM deliveries ORDER BY rowid DESC LIMIT 100"),
        reports: Store.rows("SELECT week,body,audit,url FROM reports ORDER BY week DESC LIMIT 26"),
        proposals: proposals(),
        health: health()
      )
    else
      assign(socket, settings: nil, deliveries: [], reports: [], proposals: [], health: %{})
    end
  end
end
