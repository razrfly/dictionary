defmodule DevilsDictionary.Discovery.Transport do
  @moduledoc "Bounded Req transport with budgeted retries and safe error codes."

  alias DevilsDictionary.Discovery.Budget

  @doc """
  Performs one budgeted provider request.

  The method and any query parameters come from the provider's
  `request_options/1`, so a REST provider returns `method: :get, params: %{...}`
  and a GraphQL provider returns a `:json` body and gets `:post` by default.
  """
  def request(provider, run_id, stage, payload) do
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

        case Req.request(Keyword.put_new(options, :method, :post)) do
          # A JSON object or a JSON array are both well-formed provider answers;
          # PoetryDB-shaped REST providers return a bare list.
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
            {:ok, body}

          {:ok, %Req.Response{} = response} ->
            classify(provider, run_id, stage, payload, config, response)

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

  # A status is a provider's dialect, not a fact: the same 403 is an
  # authentication verdict from a keyed API and a throttle from a keyless one.
  # The provider decides, and the default decides for those that do not.
  defp classify(
         provider,
         run_id,
         stage,
         payload,
         config,
         %Req.Response{status: status} = response
       ) do
    cond do
      retryable_status?(provider, status) ->
        retry_or_fail(provider, run_id, stage, payload, config, response)

      status in [401, 403] ->
        {:error, "authentication_failed"}

      true ->
        {:error, "provider_http_error"}
    end
  end

  defp retryable_status?(provider, status) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :retryable_status?, 1) do
      provider.retryable_status?(status)
    else
      default_retryable_status?(status)
    end
  end

  @doc """
  The statuses every provider retries unless it says otherwise: `429` and `5xx`.

  Public so a provider widening `c:DevilsDictionary.Discovery.Provider.retryable_status?/1`
  can delegate its remaining clause here instead of restating the rule and
  drifting from it.
  """
  def default_retryable_status?(status), do: status == 429 or status >= 500

  defp retry_or_fail(provider, run_id, stage, payload, config, response) do
    case retry_after_seconds(response) do
      seconds when is_integer(seconds) and seconds > 0 ->
        retry_at = DateTime.add(DateTime.utc_now(), seconds, :second)
        {:ok, _source} = Budget.defer_provider(run_id, retry_at, "retry_after")
        {:deferred, "provider_retry_after", seconds}

      _ ->
        maybe_sleep(retry_delay_ms(provider, config))
        # 429 and a provider-declared retryable 4xx are both backpressure; only a
        # 5xx is the provider itself being unwell.
        code = if response.status >= 500, do: "provider_unavailable", else: "provider_throttled"
        do_request(provider, run_id, stage, payload, config, code)
    end
  end

  defp retry_transport(provider, run_id, stage, payload, config, code) do
    maybe_sleep(retry_delay_ms(provider, config))
    do_request(provider, run_id, stage, payload, config, code)
  end

  @doc """
  How long to wait before the next bounded attempt, in milliseconds.

  The shared `:retry_delay_ms` is a floor, not a ceiling. A provider that knows
  its own throttle declares `min_retry_interval_ms` in `capabilities/0` and the
  longer of the two wins, so retrying into the same throttle that produced the
  failure is not the shared code's decision to get wrong. The Met answers a
  keyless burst with `403` and no `Retry-After`, and a 250 ms retry simply
  collects another one.
  """
  def retry_delay_ms(provider, config) do
    max(Keyword.fetch!(config, :retry_delay_ms), min_retry_interval_ms(provider))
  end

  defp min_retry_interval_ms(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) do
      case provider.capabilities() do
        %{min_retry_interval_ms: ms} when is_integer(ms) and ms >= 0 -> ms
        _ -> 0
      end
    else
      0
    end
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
