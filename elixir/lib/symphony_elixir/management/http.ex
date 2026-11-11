defmodule SymphonyElixir.Management.HTTP do
  @moduledoc "Bounded provider HTTP with redacted failure classifications."
  @spec request(String.t(), keyword()) :: {:ok, term()} | {:error, integer(), non_neg_integer()}
  def request(url, options \\ []) do
    options = Keyword.merge(options, Application.get_env(:symphony_elixir, :management_http_options, []))

    case Req.request(
           Keyword.merge(
             [
               url: url,
               retry: false,
               redirect: false,
               decode_body: false,
               compressed: false,
               into: &receive_chunk/2,
               receive_timeout: 10_000,
               connect_options: [timeout: 5_000]
             ],
             options
           )
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_json(body)}

      {:ok, response} ->
        retry = retry_after(Req.Response.get_header(response, "retry-after"))

        {:error, response.status, retry}

      {:error, _} ->
        {:error, 0, 0}
    end
  rescue
    _error -> {:error, 0, 0}
  end

  defp receive_chunk({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) > 4_000_000 do
      {:halt, {request, %{response | status: 413, body: ""}}}
    else
      {:cont, {request, %{response | body: response.body <> data}}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp retry_after([value | _]) do
    case Integer.parse(value) do
      {n, ""} -> max(0, n)
      _ -> retry_date(value)
    end
  end

  defp retry_after(_), do: 0

  defp retry_date(value) do
    case Req.Utils.parse_http_date(value) do
      {:ok, at} -> max(0, DateTime.diff(at, DateTime.utc_now()))
      _ -> 0
    end
  end
end
