defmodule SymphonyElixir.Management.Command do
  @moduledoc "Bounded process-group execution for disposable audit workspaces."
  @spec run(String.t(), [String.t()], Path.t(), pos_integer(), map()) :: {:ok, String.t()} | {:error, atom()}
  def run(binary, args, cwd, timeout, overrides \\ %{}) do
    if SymphonyElixir.DeploymentControl.effects_held?() do
      {:error, :effects_held}
    else
      execute(binary, args, cwd, timeout, overrides)
    end
  end

  defp execute(binary, args, cwd, timeout, overrides) do
    executable = System.find_executable(binary) || binary

    args =
      if Path.basename(executable) == "git",
        do: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" | args],
        else: args

    env =
      System.get_env()
      |> Map.put("GIT_CONFIG_NOSYSTEM", "1")
      |> Map.put("GIT_CONFIG_GLOBAL", "/dev/null")
      |> Map.merge(overrides)
      |> Enum.map(fn {key, value} ->
        {String.to_charlist(key),
         if(key in ~w(HOME CODEX_HOME PATH LANG TZ XDG_RUNTIME_DIR GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL),
           do: String.to_charlist(value),
           else: false
         )}
      end)

    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("setsid"))}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["--fork", "--wait", executable | args],
        cd: cwd,
        env: env
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    await(port, deadline, "")
  end

  defp await(port, deadline, output) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) > 1_000_000 do
          kill(port)
          {:error, :output_limit}
        else
          await(port, deadline, output <> data)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim(output)}

      {^port, {:exit_status, _}} ->
        {:error, :command_failed}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill_group(child) do
    if Regex.match?(~r/^\d+$/, child), do: System.cmd("kill", ["-KILL", "--", "-" <> child], stderr_to_stdout: true)
  end

  defp kill(port) do
    info = Port.info(port) || []

    if pid = info[:os_pid] do
      {children, _} = System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true)

      children |> String.split("\n", trim: true) |> Enum.each(&kill_group/1)

      System.cmd("kill", ["-KILL", "--", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    if Port.info(port), do: Port.close(port)
  end
end
