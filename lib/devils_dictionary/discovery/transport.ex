defmodule DevilsDictionary.Discovery.Transport do
  @moduledoc "Bounded Req transport with budgeted retries and safe error codes."

  alias DevilsDictionary.Discovery.Budget

  def graphql(provider, run_id, payload) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    max_retries = Keyword.fetch!(config, :max_retries)
    do_request(provider, run_id, payload, 0, max_retries, config)
  end

  defp do_request(provider, run_id, payload, attempt, max_retries, config) do
    case Budget.claim(run_id) do
      :ok ->
        options =
          provider.request_options(payload)
          |> Keyword.merge(
            receive_timeout: Keyword.fetch!(config, :timeout_ms),
            retry: false
          )
          |> Keyword.merge(Application.get_env(:devils_dictionary, :discovery_req_options, []))

        case Req.post(options) do
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
            {:ok, body}

          {:ok, %Req.Response{status: status} = response} when status == 429 or status >= 500 ->
            retry_or_fail(provider, run_id, payload, attempt, max_retries, config, response)

          {:ok, %Req.Response{status: status}} when status in [401, 403] ->
            {:error, "authentication_failed"}

          {:ok, %Req.Response{}} ->
            {:error, "provider_http_error"}

          {:error, %Req.TransportError{reason: :timeout}} ->
            retry_transport(provider, run_id, payload, attempt, max_retries, config, "timeout")

          {:error, _reason} ->
            retry_transport(
              provider,
              run_id,
              payload,
              attempt,
              max_retries,
              config,
              "provider_unavailable"
            )
        end

      {:deferred, seconds} ->
        {:deferred, "request_budget", seconds}
    end
  end

  defp retry_or_fail(provider, run_id, payload, attempt, max_retries, config, response) do
    if attempt < max_retries do
      delay = retry_after_ms(response) || backoff_ms(config, attempt)
      maybe_sleep(delay)
      do_request(provider, run_id, payload, attempt + 1, max_retries, config)
    else
      code = if response.status == 429, do: "provider_throttled", else: "provider_unavailable"
      {:error, code}
    end
  end

  defp retry_transport(provider, run_id, payload, attempt, max_retries, config, code) do
    if attempt < max_retries do
      maybe_sleep(backoff_ms(config, attempt))
      do_request(provider, run_id, payload, attempt + 1, max_retries, config)
    else
      {:error, code}
    end
  end

  defp backoff_ms(config, attempt) do
    Keyword.fetch!(config, :retry_delay_ms) * round(:math.pow(2, attempt))
  end

  defp retry_after_ms(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, ""} -> min(seconds * 1_000, 5_000)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_sleep(0), do: :ok
  defp maybe_sleep(ms), do: Process.sleep(ms)
end
