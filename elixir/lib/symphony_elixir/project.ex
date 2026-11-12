defmodule SymphonyElixir.Project do
  @moduledoc "Immutable project identity bound at OTP and request boundaries. No application configuration is switched."
  alias SymphonyElixir.{Config.Schema, Tracker, Workflow, WorkflowStore}

  defstruct [:id, :workflow_path, :state_dir, :workspace_root, enabled: true]

  @type t :: %__MODULE__{
          id: String.t(),
          workflow_path: Path.t(),
          state_dir: Path.t(),
          workspace_root: Path.t(),
          enabled: boolean()
        }

  @spec all() :: [t()]
  def all, do: Application.get_env(:symphony_elixir, :projects, [])

  @spec current() :: t() | nil
  def current, do: Process.get(__MODULE__, default())

  @spec default() :: t() | nil
  def default, do: Enum.find(all(), & &1.enabled)

  @spec bind(t() | nil) :: :ok
  def bind(project) do
    Logger.metadata(project_id: if(project, do: project.id))
    Process.put(__MODULE__, project)
    :ok
  end

  @spec wrap((-> term())) :: (-> term())
  def wrap(fun) do
    project = current()

    fn ->
      bind(project)
      fun.()
    end
  end

  @spec name(atom(), t() | nil) :: GenServer.server()
  def name(module, project \\ current()) do
    case project do
      nil -> module
      %__MODULE__{id: id} -> {:via, Registry, {SymphonyElixir.ProjectRegistry, {id, module}}}
    end
  end

  @spec whereis(GenServer.server()) :: pid() | nil
  def whereis(server), do: GenServer.whereis(server)

  @spec find(String.t()) :: {:ok, t()} | {:error, :unknown_project}
  def find(id) do
    case Enum.find(all(), &(&1.id == id and &1.enabled)) do
      nil -> {:error, :unknown_project}
      project -> {:ok, project}
    end
  end

  @spec mount(map()) :: :ok
  def mount(params) do
    case params["project_id"] do
      nil ->
        bind(default())

      id ->
        case find(id) do
          {:ok, project} -> bind(project)
          {:error, reason} -> raise ArgumentError, inspect(reason)
        end
    end
  end

  @doc "All project credential names are removed from every coding worker's inherited environment."
  @spec secret_environment_names() :: [String.t()]
  def secret_environment_names do
    Enum.flat_map(all(), fn project ->
      {:ok, settings} = project_settings(project)
      references = settings.management |> Map.take(~w(symphony_github_token_env github_token_env slack_webhook_env m365_secret_env)) |> Map.values()
      Tracker.secret_environment_names(settings.tracker) ++ references
    end)
    |> Enum.uniq()
  end

  defp project_settings(project) do
    case whereis(name(WorkflowStore, project)) do
      nil ->
        with {:ok, workflow} <- Workflow.load(project.workflow_path), do: Schema.parse(workflow.config)

      pid ->
        GenServer.call(pid, :settings)
    end
  end

  @spec path(String.t()) :: String.t()
  def path(suffix) do
    case current() do
      nil -> suffix
      project -> "/projects/#{project.id}" <> suffix
    end
  end
end
