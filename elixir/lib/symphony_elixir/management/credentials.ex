defmodule SymphonyElixir.Management.Credentials do
  @moduledoc false
  defstruct values: %{}
end

defimpl Inspect, for: SymphonyElixir.Management.Credentials do
  @impl true
  def inspect(_credentials, _opts), do: "#Credentials<redacted>"
end
