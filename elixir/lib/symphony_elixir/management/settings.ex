defmodule SymphonyElixir.Management.Settings do
  @moduledoc "Host policy plus durable operator settings and write-only credentials."
  alias SymphonyElixir.Management.{Credentials, Repo, Store}

  @editable ~w(github_auth_mode email_sender email_recipients m365_tenant m365_client delivery_enabled publish_enabled weekly notifications audit rate_card)
  @audit ~w(enabled draft_prs model effort timeout_seconds max_calls_per_week)
  @secrets ~w(github_token slack_webhook m365_secret)

  @spec config() :: map()
  def config do
    {:ok, config} =
      Repo.transaction(fn ->
        path = Path.join(SymphonyElixir.Config.management_state_dir(), "policy.json")
        policy = Application.get_env(:symphony_elixir, :management_policy) || workflow_policy(path)

        merge(policy, Store.get("operator_settings", %{}))
        |> Map.put("_managed_secrets", %Credentials{values: read_credentials()})
      end)

    config
  end

  defp execution_policy do
    path = Path.join(SymphonyElixir.Config.management_state_dir(), "policy.json")
    Application.get_env(:symphony_elixir, :management_policy) || workflow_policy(path)
  end

  defp workflow_policy(legacy_path) do
    case SymphonyElixir.Config.settings() do
      {:ok, %{management: policy}} when map_size(policy) > 0 -> policy
      _ -> if File.regular?(legacy_path), do: Jason.decode!(File.read!(legacy_path)), else: %{}
    end
  end

  @spec worker_secret_environment_names() :: [String.t()]
  def worker_secret_environment_names do
    policy = execution_policy()

    references =
      Map.take(policy, ~w(symphony_github_token_env github_token_env slack_webhook_env m365_secret_env)) |> Map.values()

    Enum.uniq(~w(VISIBILITY_GITHUB_TOKEN VISIBILITY_SLACK_WEBHOOK VISIBILITY_M365_SECRET) ++ references)
  end

  @spec public() :: map()
  def public do
    config = config()

    Map.take(config, @editable)
    |> Map.update("audit", %{}, &Map.take(&1, @audit))
    |> Map.put("credentials", Map.new(@secrets, &{&1, secret(config, &1) != ""}))
  end

  @spec secret(map(), String.t()) :: String.t()
  def secret(config, name) do
    if name == "github_token" and config["github_auth_mode"] == "symphony" do
      System.get_env(config["symphony_github_token_env"] || "SYMPHONY_GITHUB_TOKEN", "")
    else
      managed =
        case config["_managed_secrets"] do
          %Credentials{values: values} -> values
          _ -> read_credentials()
        end

      Map.get(managed, name, System.get_env(config[name <> "_env"] || "VISIBILITY_" <> String.upcase(name), ""))
    end
  end

  @spec save(map(), map()) :: :ok | {:error, String.t()}
  def save(changes, credentials \\ %{}) do
    with :ok <- validate(changes, credentials) do
      save_validated(changes, credentials)
    end
  end

  defp save_validated(changes, credentials) do
    config = merge(config(), changes)

    if config["github_auth_mode"] == "symphony" and Map.has_key?(credentials, "github_token") do
      {:error, "Shared GitHub credentials are managed on the host"}
    else
      with :ok <- validate_enabling(config, credentials) do
        persist_settings(changes, credentials)
      end
    end
  end

  def ready?(config, channel, overrides \\ %{})
  @spec ready?(map(), String.t(), map()) :: boolean()
  def ready?(config, "slack", overrides), do: credential(config, "slack_webhook", overrides) != ""
  def ready?(config, "github", overrides), do: credential(config, "github_token", overrides) != ""

  def ready?(config, "email", overrides) do
    Enum.all?(~w(email_sender m365_tenant m365_client), &(is_binary(config[&1]) and config[&1] != "")) and
      (config["email_recipients"] || []) != [] and credential(config, "m365_secret", overrides) != ""
  end

  def ready?(_config, _channel, _overrides), do: false

  defp credential(config, "github_token", overrides) do
    if config["github_auth_mode"] == "symphony",
      do: secret(config, "github_token"),
      else: Map.get(overrides, "github_token", secret(config, "github_token"))
  end

  defp credential(config, name, overrides), do: Map.get(overrides, name, secret(config, name))

  defp validate_enabling(config, credentials) do
    delivery_missing = config["delivery_enabled"] == true and not deliverable?(config, credentials)
    weekly_missing = weekly_email?(config) and not ready?(config, "email", credentials)
    publication_missing = publication?(config) and not ready?(config, "github", credentials)
    drafts_missing = drafts_missing?(config)

    cond do
      delivery_missing -> {:error, "Configure an enabled delivery channel before enabling delivery"}
      weekly_missing -> {:error, "Configure email before enabling its weekly heartbeat"}
      publication_missing -> {:error, "Configure GitHub access before enabling publication"}
      drafts_missing -> {:error, "Draft proposals require analysis and publication"}
      true -> :ok
    end
  end

  defp drafts_missing?(config), do: get_in(config, ["audit", "draft_prs"]) == true and not drafts_allowed?(config)

  defp deliverable?(config, credentials) do
    Enum.any?(
      ~w(email slack),
      &(get_in(config, ["notifications", &1, "enabled"]) != false and ready?(config, &1, credentials))
    )
  end

  defp weekly_email?(config) do
    config["delivery_enabled"] == true and get_in(config, ["weekly", "enabled"]) != false and
      get_in(config, ["notifications", "email", "enabled"]) != false and
      get_in(config, ["notifications", "email", "weekly"]) != false
  end

  defp publication?(config), do: config["publish_enabled"] == true or get_in(config, ["audit", "draft_prs"]) == true
  defp drafts_allowed?(config), do: config["publish_enabled"] == true and get_in(config, ["audit", "enabled"]) == true

  defp persist_settings(changes, credentials) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        version = if map_size(credentials) > 0, do: write_credentials(credentials)
        commit_settings(changes, version)
      end)

    :ok
  rescue
    _error -> {:error, "Settings save could not be confirmed; reload before retrying"}
  end

  defp commit_settings(changes, version) do
    Store.put("operator_settings", merge(Store.get("operator_settings", %{}), changes))
    if version, do: Store.put("active_credentials_file", version)
    :ok
  end

  defp write_credentials(credentials) do
    filename = "credentials-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".json"
    path = Path.join(SymphonyElixir.Config.management_state_dir(), filename)
    atomic_write(path, Jason.encode!(Map.merge(read_credentials(), credentials)))
    filename
  end

  defp read_credentials do
    filename = Store.get("active_credentials_file", "credentials.json")

    if is_binary(filename) and Regex.match?(~r/\Acredentials(?:-[A-Za-z0-9_-]+)?\.json\z/, filename) do
      path = Path.join(SymphonyElixir.Config.management_state_dir(), filename)

      with {:ok, text} <- File.read(path), {:ok, values} when is_map(values) <- Jason.decode(text) do
        sanitize_credentials(values)
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp sanitize_credentials(values),
    do: values |> Map.take(@secrets) |> Map.reject(fn {_key, value} -> not is_binary(value) end)

  @spec validate(map(), map()) :: :ok | {:error, String.t()}
  def validate(changes, credentials) do
    cond do
      Enum.any?(Map.keys(changes), &(&1 not in @editable)) ->
        {:error, "Unsupported setting"}

      Enum.any?(Map.keys(credentials), &(&1 not in @secrets)) ->
        {:error, "Unsupported credential"}

      Enum.any?(credentials, &invalid_credential?/1) ->
        {:error, "Invalid credential"}

      Map.has_key?(changes, "audit") and
          (not is_map(changes["audit"]) or Enum.any?(Map.keys(changes["audit"]), &(&1 not in @audit))) ->
        {:error, "Audit execution policy is host managed"}

      true ->
        validate_values(merge(config(), changes))
    end
  end

  defp invalid_credential?({"slack_webhook", value}) when is_binary(value) and value != "" do
    not Regex.match?(~r/\Ahttps:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9_\/-]+\z/, value)
  end

  defp invalid_credential?({_key, value}) do
    not is_binary(value) or byte_size(value) > 4096 or String.match?(value, ~r/[\x00-\x1f]/)
  end

  @spec merge(map(), map()) :: map()
  def merge(left, right),
    do: Map.merge(left, right, fn _, a, b -> if is_map(a) and is_map(b), do: merge(a, b), else: b end)

  @spec atomic_write(Path.t(), String.t()) :: :ok
  def atomic_write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> "." <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :exclusive, :binary])

    try do
      File.chmod!(temporary, 0o600)
      :ok = :file.write(file, content)
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    File.rename!(temporary, path)
    :ok
  end

  defp validate_values(config) do
    validations = [
      validate_switches(config),
      validate_schedule(config["weekly"] || %{}),
      validate_audit(Map.get(config, "audit", %{})),
      validate_email(config),
      validate_identity(config),
      validate_channels(config["notifications"] || %{}),
      validate_rate_card(config["rate_card"] || %{})
    ]

    Enum.find(validations, :ok, &(&1 != :ok))
  end

  defp validate_switches(config) do
    valid = Enum.all?(~w(delivery_enabled publish_enabled), &(not Map.has_key?(config, &1) or is_boolean(config[&1])))

    cond do
      not valid -> {:error, "Enable switches must be booleans"}
      config["github_auth_mode"] not in [nil, "symphony", "separate"] -> {:error, "Invalid GitHub authentication mode"}
      true -> :ok
    end
  end

  defp validate_schedule(weekly) when is_map(weekly) do
    values = Map.merge(%{"enabled" => true, "day" => "Mon", "time" => "09:00", "timezone" => "UTC"}, weekly)

    cond do
      Enum.any?(Map.keys(weekly), &(&1 not in ~w(enabled day time timezone))) -> {:error, "Unsupported schedule field"}
      not is_boolean(values["enabled"]) -> {:error, "Schedule enabled must be a boolean"}
      values["day"] not in ~w(Mon Tue Wed Thu Fri Sat Sun) -> {:error, "Invalid weekday"}
      not valid_time?(values["time"]) -> {:error, "Invalid schedule time"}
      not valid_zone?(values["timezone"]) -> {:error, "Invalid timezone"}
      true -> :ok
    end
  end

  defp validate_schedule(_), do: {:error, "Invalid schedule"}
  defp valid_time?(value), do: is_binary(value) and Regex.match?(~r/^(?:[01]\d|2[0-3]):[0-5]\d$/, value)
  defp valid_zone?(value), do: is_binary(value) and (value == "UTC" or Tzdata.zone_exists?(value))

  defp validate_audit(audit) when is_map(audit) do
    cond do
      not valid_budget?(audit) ->
        {:error, "Invalid audit budget"}

      not valid_timeout?(audit) ->
        {:error, "Invalid audit timeout"}

      not audit_switches?(audit) ->
        {:error, "Audit switches must be booleans"}

      not valid_model?(audit["model"] || "gpt-6.1-sol") ->
        {:error, "Invalid audit model"}

      audit["effort"] not in [nil | ~w(none low medium high xhigh max)] ->
        {:error, "Invalid audit effort"}

      true ->
        :ok
    end
  end

  defp validate_audit(_), do: {:error, "Invalid audit settings"}

  defp valid_budget?(audit), do: bounded_integer?(audit["max_calls_per_week"] || 2, 1..3)
  defp valid_timeout?(audit), do: bounded_integer?(audit["timeout_seconds"] || 600, 30..900)

  defp audit_switches?(audit), do: Enum.all?(~w(enabled draft_prs), &(not Map.has_key?(audit, &1) or is_boolean(audit[&1])))

  defp bounded_integer?(value, range), do: is_integer(value) and value in range

  defp validate_email(config) do
    recipients = config["email_recipients"] || []
    sender = config["email_sender"] || ""

    cond do
      not is_list(recipients) -> {:error, "Invalid recipients"}
      length(recipients) > 25 -> {:error, "Too many recipients"}
      not Enum.all?(recipients, &valid_email?/1) -> {:error, "Invalid recipient address"}
      sender != "" and not valid_email?(sender) -> {:error, "Invalid sender address"}
      true -> :ok
    end
  end

  defp valid_model?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,100}\z/, value)

  defp validate_identity(config) do
    if Enum.all?(~w(m365_tenant m365_client), &valid_identity?(config[&1])),
      do: :ok,
      else: {:error, "Invalid Microsoft identity"}
  end

  defp valid_identity?(nil), do: true
  defp valid_identity?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]{0,253}\z/, value)

  defp valid_email?(value), do: is_binary(value) and Regex.match?(~r/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/, value)

  defp validate_channels(channels) when is_map(channels) do
    if Enum.all?(channels, fn {channel, flags} -> channel in ~w(email slack) and valid_flags?(flags) end),
      do: :ok,
      else: {:error, "Invalid notification preferences"}
  end

  defp validate_channels(_), do: {:error, "Invalid notification preferences"}

  defp valid_flags?(flags) when is_map(flags),
    do: Enum.all?(flags, fn {key, value} -> key in ~w(enabled handoffs blockers weekly) and is_boolean(value) end)

  defp valid_flags?(_), do: false

  defp validate_rate_card(card) when is_map(card) do
    models = card["models"] || %{}
    version = card["version"] || "unconfigured"

    if is_binary(version) and byte_size(version) <= 100 and is_map(models) and Enum.all?(models, &valid_model_rates?/1),
      do: :ok,
      else: {:error, "Invalid model rates"}
  end

  defp validate_rate_card(_), do: {:error, "Invalid rate card"}

  defp valid_model_rates?({model, rates}) when is_binary(model) and is_map(rates) do
    Regex.match?(~r/^[A-Za-z0-9_.:-]{1,100}$/, model) and
      Enum.all?(~w(input output cached_input), &(is_number(rates[&1]) and rates[&1] >= 0))
  end

  defp valid_model_rates?(_), do: false
end
