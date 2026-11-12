defmodule SymphonyElixir.Management.Delivery do
  @moduledoc "Independent durable notification delivery with leases and bounded retries."
  alias SymphonyElixir.Management.{HTTP, Settings, Store}

  @spec drain() :: :ok
  def drain do
    config = Settings.config()
    now = System.system_time(:second)

    rows =
      Store.rows(
        "SELECT * FROM deliveries WHERE status IN ('pending','sending') AND due<=? AND lease<=? ORDER BY CASE WHEN id LIKE 'weekly:%' THEN 0 ELSE 1 END,due,id LIMIT 30",
        [now, now]
      )

    deadline = System.monotonic_time(:millisecond) + 80_000

    rows
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
    |> Enum.each(&deliver(config, &1, System.system_time(:second)))

    :ok
  end

  @spec replay(String.t()) :: :ok
  def replay(id) do
    Store.query!(
      "UPDATE deliveries SET status='pending',attempts=0,due=0,lease=0,error=NULL WHERE id=? AND status IN ('failed','suppressed')",
      [id]
    )

    :ok
  end

  @spec send_message(map(), map()) :: {:ok, term()} | {:error, integer(), non_neg_integer()}
  def send_message(config, %{"channel" => "slack"} = row) do
    url = Settings.secret(config, "slack_webhook")

    if String.starts_with?(url, "https://hooks.slack.com/services/") do
      text =
        (row["subject"] <> "\n" <> String.slice(row["body"], 0, 12_000))
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;")

      HTTP.request(url, method: :post, json: %{text: text, unfurl_links: false, unfurl_media: false})
    else
      {:error, 400, 0}
    end
  end

  def send_message(config, %{"channel" => "email"} = row) do
    case email_token(config) do
      {:ok, %{"access_token" => token}} -> send_email(config, row, token)
      {:error, _, _} = error -> error
      _ -> {:error, 400, 0}
    end
  end

  def send_message(_config, _row), do: {:error, 400, 0}

  @spec test(String.t()) :: :ok | {:error, String.t()}
  def test(channel) when channel in ["email", "slack"] do
    config = Settings.config()

    if Settings.ready?(config, channel),
      do: test_with_lease(config, channel),
      else: {:error, "Configure this channel before sending a test"}
  end

  def test(_channel), do: {:error, "Select a supported channel"}

  defp test_with_lease(config, channel) do
    name = "test-delivery:" <> channel

    case Store.claim_job(name, 120) do
      {:ok, token} ->
        try do
          test_once(config, channel)
        after
          Store.release_job(name, token)
        end

      :busy ->
        {:error, "A test is already in progress"}
    end
  end

  defp test_once(config, channel) do
    key = "last_test:" <> channel
    now = System.system_time(:second)

    if Store.get(key, 0) + 20 > now do
      {:error, "Wait before sending another test"}
    else
      Store.put(key, now)
      id = "test:" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      Store.enqueue(
        id,
        channel,
        "Symphony — test notification",
        "A test notification requested from the local Symphony console."
      )

      full_id = id <> ":" <> channel
      Store.query!("UPDATE deliveries SET status='sending',attempts=1,lease=? WHERE id=?", [now + 120, full_id])
      row = hd(Store.rows("SELECT * FROM deliveries WHERE id=?", [full_id]))
      finish_test(send_message(config, row), full_id)
    end
  end

  defp finish_test({:ok, _}, id) do
    Store.query!("UPDATE deliveries SET status='accepted',error=NULL,lease=0 WHERE id=?", [id])
    :ok
  end

  defp finish_test({:error, status, _retry}, id) do
    Store.query!("UPDATE deliveries SET status='failed',error=?,lease=0 WHERE id=?", ["HTTP #{status}", id])
    {:error, "Test failed (HTTP #{status}); check channel configuration"}
  end

  defp email_token(config) do
    tenant = URI.encode_www_form(config["m365_tenant"] || "")

    form = [
      client_id: config["m365_client"],
      client_secret: Settings.secret(config, "m365_secret"),
      scope: "https://graph.microsoft.com/.default",
      grant_type: "client_credentials"
    ]

    HTTP.request("https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token", method: :post, form: form)
  end

  defp send_email(config, row, token) do
    sender = URI.encode_www_form(config["email_sender"] || "")
    recipients = Enum.map(config["email_recipients"] || [], &%{emailAddress: %{address: &1}})
    message = %{subject: row["subject"], body: %{contentType: "Text", content: row["body"]}, toRecipients: recipients}

    HTTP.request("https://graph.microsoft.com/v1.0/users/#{sender}/sendMail",
      method: :post,
      headers: [{"authorization", "Bearer " <> token}],
      json: %{message: message, saveToSentItems: true}
    )
  end

  defp deliver(config, row, now) do
    cond do
      suppressed?(config, row) ->
        Store.query!(
          "UPDATE deliveries SET status='suppressed',error='disabled by notification preferences',lease=0 WHERE id=?",
          [row["id"]]
        )

      config["delivery_enabled"] != true ->
        :ok

      not Settings.ready?(config, row["channel"]) ->
        defer_unconfigured(row, now)

      true ->
        claim_and_send(config, row, now)
    end
  end

  defp defer_unconfigured(row, now) do
    Store.query!("UPDATE deliveries SET error='delivery unconfigured',due=? WHERE id=?", [now + 300, row["id"]])
  end

  defp suppressed?(config, row) do
    kind = kind(row["id"])
    flags = get_in(config, ["notifications", row["channel"]]) || %{}
    flags["enabled"] == false or flags[kind] == false or weekly_disabled?(config, kind)
  end

  defp kind("weekly:" <> _), do: "weekly"
  defp kind("handoff:" <> _), do: "handoffs"
  defp kind(_), do: "blockers"
  defp weekly_disabled?(config, "weekly"), do: get_in(config, ["weekly", "enabled"]) == false
  defp weekly_disabled?(_config, _kind), do: false

  defp claim_and_send(config, row, now) do
    attempts = row["attempts"] + 1

    claim =
      Store.query!(
        "UPDATE deliveries SET status='sending',lease=?,attempts=? WHERE id=? AND lease<=? AND status IN ('pending','sending')",
        [now + 120, attempts, row["id"], now]
      )

    if claim.num_rows == 1, do: settle(send_message(config, row), row, now, attempts)
  end

  defp settle({:ok, _}, row, _now, _attempts) do
    Store.query!("UPDATE deliveries SET status='accepted',error=NULL,lease=0 WHERE id=?", [row["id"]])
    Store.put("delivery_last_accepted:" <> row["channel"], DateTime.to_iso8601(DateTime.utc_now()))
  end

  defp settle({:error, status, retry}, row, now, attempts) do
    pending = attempts < 8 and retryable?(status)
    delay = max(min(3600, 30 * Integer.pow(2, attempts - 1)), retry)

    Store.query!("UPDATE deliveries SET status=?,error=?,due=?,lease=0 WHERE id=?", [
      if(pending, do: "pending", else: "failed"),
      "HTTP #{status}",
      now + delay,
      row["id"]
    ])
  end

  defp retryable?(status), do: status in [0, 408, 429] or status >= 500
end
