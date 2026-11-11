defmodule SymphonyElixir.Codex.Protocol do
  @moduledoc "Compatibility for an explicitly configured host permission profile."

  @spec preserve_profile(map(), boolean()) :: map()
  def preserve_profile(%{"method" => "thread/start", "params" => params} = message, true),
    do: %{message | "params" => Map.delete(params, "sandbox")}

  def preserve_profile(%{"method" => "turn/start", "params" => params} = message, true),
    do: %{message | "params" => Map.delete(params, "sandboxPolicy")}

  def preserve_profile(message, _enabled), do: message
end
