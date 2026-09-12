defmodule DevilsDictionary.Discovery.Transport do
  @moduledoc "Bounded Req transport with budgeted retries and safe error codes."

  alias DevilsDictionary.Discovery.Budget

  def graphql(provider, run_id, stage, payload) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    do_request(provider, run_id, stage, payload, config)
  end

  defp do_request(provider, run_id, stage, payload, config, failure_code \\ nil) do
    case Budget.claim(run_id, stage) do
      :ok ->
        options =
          provider.request_options(payload)
          |> Keyword.merge(
            receive_timeout: Keyword.fetch!(config, :timeout_ms),
            connect_options: [timeout: Keyword.fetch!(config, :timeout_ms)],
            retry: false
          )
          |> Keyword.merge(Application.get_env(:devils_dictionary, :discovery_req_options, []))

        case Req.post(options) do
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
            {:ok, body}

          {:ok, %Req.Response{status: status} = response} when status == 429 or status >= 500 ->
            retry_or_fail(provider, run_id, stage, payload, config, response)

          {:ok, %Req.Response{status: status}} when status in [401, 403] ->
            {:error, "authentication_failed"}

          {:ok, %Req.Response{}} ->
            {:error, "provider_http_error"}

          {:error, %Req.TransportError{reason: :timeout}} ->
            retry_transport(provider, run_id, stage, payload, config, "timeout")

          {:error, _reason} ->
            retry_transport(
              provider,
              run_id,
              stage,
              payload,
              config,
              "provider_unavailable"
            )
        end

      {:deferred, seconds} ->
        {:deferred, "request_budget", seconds}

      {:error, :attempts_exhausted} ->
        {:error, failure_code || "retry_budget_exhausted"}
    end
  end

  defp retry_or_fail(provider, run_id, stage, payload, config, response) do
    case retry_after_seconds(response) do
      seconds when is_integer(seconds) and seconds > 0 ->
        retry_at = DateTime.add(DateTime.utc_now(), seconds, :second)
        {:ok, _source} = Budget.defer_provider(run_id, retry_at, "retry_after")
        {:deferred, "provider_retry_after", seconds}

      _ ->
        maybe_sleep(Keyword.fetch!(config, :retry_delay_ms))
        code = if response.status == 429, do: "provider_throttled", else: "provider_unavailable"
        do_request(provider, run_id, stage, payload, config, code)
    end
  end

  defp retry_transport(provider, run_id, stage, payload, config, code) do
    maybe_sleep(Keyword.fetch!(config, :retry_delay_ms))
    do_request(provider, run_id, stage, payload, config, code)
  end

  @doc "Parses delta-seconds and IMF-fixdate Retry-After values without shortening them."
  def retry_after_seconds(response, now \\ DateTime.utc_now()) do
    with [value | _] <- Req.Response.get_header(response, "retry-after") do
      parse_retry_after(String.trim(value), now)
    end
  end

  defp parse_retry_after(value, now) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> :http_date
    end
    |> case do
      seconds when is_integer(seconds) -> seconds
      :http_date -> parse_http_date(value, now)
    end
  end

  defp parse_http_date(value, now) do
    try do
      case :httpd_util.convert_request_date(String.to_charlist(value)) do
        {{_, _, _}, {_, _, _}} = erl_datetime ->
          retry_at = erl_datetime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
          max(DateTime.diff(retry_at, now, :second), 0)

        _ ->
          nil
      end
    rescue
      FunctionClauseError -> nil
    end
  end

  defp maybe_sleep(0), do: :ok
  defp maybe_sleep(ms), do: Process.sleep(ms)
end
