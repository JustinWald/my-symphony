defmodule SymphonyElixir.DeploymentControl do
  @moduledoc "Read-only view of an operator-owned durable deployment hold. Agents cannot approve promotion."
  @revision System.get_env("SYMPHONY_BUILD_REVISION", "development")

  @spec revision() :: String.t()
  def revision, do: @revision

  @spec status() :: map()
  def status do
    if System.get_env("SYMPHONY_EXTERNAL_EFFECTS") == "disabled" do
      %{dispatch_paused: true, effects_held: true}
    else
      control_status()
    end
  end

  defp control_status do
    case System.get_env("SYMPHONY_CONTROL_DIR") do
      nil -> %{dispatch_paused: false, effects_held: false}
      directory -> read(Path.join(directory, "pause.json"))
    end
  end

  @spec dispatch_paused?() :: boolean()
  def dispatch_paused?, do: status().dispatch_paused

  @spec effects_held?() :: boolean()
  def effects_held?, do: status().effects_held

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        %{dispatch_paused: false, effects_held: false}

      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"dispatch_paused" => paused, "effects_held" => held}} when is_boolean(paused) and is_boolean(held) ->
            %{dispatch_paused: paused or held, effects_held: held}

          _ ->
            %{dispatch_paused: true, effects_held: true}
        end

      _ ->
        %{dispatch_paused: true, effects_held: true}
    end
  end
end
