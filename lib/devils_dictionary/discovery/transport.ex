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
    case Budget.claim(run_id, stage, request_interval_ms: request_interval_ms(provider)) do
      {:ok, wait_ms} ->
        maybe_sleep(wait_ms)

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

          # A provider that declares `body: :xml` answers with a document Req
          # does not decode, and its own `parse_body/1` is the only thing that
          # knows the dialect. It returns the map the rest of the pipeline
          # expects, so `retrieve/4`'s `request_fun` never sees XML and no
          # provider parses its body twice. An unparseable document is the same
          # `"malformed_response"` a bad JSON envelope gets.
          {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
            if body_format(provider) == :xml do
              case provider.parse_body(body) do
                {:ok, parsed} when is_map(parsed) or is_list(parsed) -> {:ok, parsed}
                _other -> {:error, "malformed_response"}
              end
            else
              {:error, "malformed_response"}
            end

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
    case retry_after_seconds(response, DateTime.utc_now(), retry_after_headers(provider)) do
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

  defp min_retry_interval_ms(provider), do: interval(provider, :min_retry_interval_ms)

  @doc """
  The sustained gap this provider's API tolerates between its requests, in ms.

  Pacing is a capability, not a provider's private `Process.sleep/1` (K5 of
  #109): a run's cost is `1 + n` requests through this transport whoever issues
  them, so the one place that can hold a rate is the one place they all pass
  through. The Met's is 3,000 — measured, and the difference between 44% of
  2,600 requests refused and none of them.

  The interval is held per *provider*, not per process: `Budget.claim/3` places
  each request in a slot the interval after the provider's latest one, under the
  source's advisory lock, and this transport sleeps until its slot. Two
  concurrent runs on the same provider therefore alternate at the declared gap
  rather than each keeping the gap privately and issuing together.

  A provider that does not declare one is not paced, which is right for a keyed
  API with a published budget.
  """
  def request_interval_ms(provider), do: interval(provider, :request_interval_ms)

  @doc """
  The wire format this provider's body arrives in: `:json` unless it says `:xml`.

  Read from `capabilities/0`'s optional `body` key. Absent means JSON, which is
  every provider but one: Req decodes a JSON body to a map or a list and the
  transport hands that straight on. Bing's news feed is RSS (#135), so the
  transport accepts a **binary** 200 for a provider that declared `:xml` and
  gives it to that provider's `parse_body/1` — the one place the dialect is
  known — rather than growing a branch per format of its own.
  """
  def body_format(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) and
         function_exported?(provider, :parse_body, 1) do
      case Map.get(provider.capabilities(), :body) do
        :xml -> :xml
        _other -> :json
      end
    else
      :json
    end
  end

  defp interval(provider, key) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) do
      case Map.get(provider.capabilities(), key) do
        ms when is_integer(ms) and ms >= 0 -> ms
        _ -> 0
      end
    else
      0
    end
  end

  @doc """
  The header names this provider's API states a backoff in, in order.

  `Retry-After` unless the provider says otherwise, which is every provider
  but one. The Guardian's Content API (#142) answers with `ratelimit-reset`
  — seconds, the same units — and sends no `Retry-After` at all, so a
  transport that only ever read one header name would ignore a throttle that
  was plainly stated and retry straight back into it.

  It is a capability read in one place, like `body: :xml` (#135), rather than
  a branch per dialect in shared code: which header an API states its backoff
  in is the provider's knowledge.
  """
  def retry_after_headers(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) do
      case Map.get(provider.capabilities(), :retry_after_headers) do
        [_ | _] = names -> Enum.filter(names, &is_binary/1)
        _ -> ["retry-after"]
      end
    else
      ["retry-after"]
    end
  end

  @doc """
  Parses delta-seconds and IMF-fixdate backoff values without shortening them.

  `header_names` is the provider's, from `retry_after_headers/1`; the first
  name that is present and parses wins, so a provider naming two dialects
  gets the one its API actually sent.
  """
  def retry_after_seconds(response, now \\ DateTime.utc_now(), header_names \\ ["retry-after"]) do
    Enum.find_value(header_names, fn name ->
      # `get_header/2` answers `[]` for a header that is not there, and `[]` is
      # truthy — so the absent case is matched explicitly rather than left to
      # fall out of a `with`, which is how the first draft of this returned
      # `[]` where every caller expected `nil`.
      case Req.Response.get_header(response, name) do
        [value | _] -> parse_retry_after(String.trim(value), now)
        [] -> nil
      end
    end)
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
