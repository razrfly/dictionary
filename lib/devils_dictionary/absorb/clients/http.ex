defmodule DevilsDictionary.Absorb.Clients.HTTP do
  @moduledoc """
  The shared half of both Wikimedia clients: one user agent, one rate limiter,
  one reading of a 429.

  Rate limiting is a `Process.sleep/1` before each call rather than a token
  bucket. #69 §2's budget is "≤ 5 req/s, politely", the absorbs are sequential
  inside one process, and `EnrichWorker` sleeps for the same interval before its
  own call — a bucket would be machinery with nothing to do.

  Every request goes through `Application.get_env(:devils_dictionary, :req_options)`,
  which is empty in dev and prod and a `Req.Test` plug in the suite. That is how
  the tests exercise batching, redirects and absent markers without a network
  (scorecard O3).
  """

  require Logger

  @doc """
  A JSON GET with the project user agent, retries on 5xx, and a 429 surfaced as
  `{:error, {:rate_limited, seconds}}` so the caller can snooze rather than fail.
  """
  def get_json(url, params, opts \\ []) do
    rate_limit_ms = Keyword.get(opts, :rate_limit_ms, 200)
    if rate_limit_ms > 0, do: Process.sleep(rate_limit_ms)

    options =
      [
        url: url,
        params: params,
        headers: [{"user-agent", user_agent()}, {"accept", "application/json"}],
        retry: &retry?/2,
        max_retries: 3,
        receive_timeout: 30_000
      ] ++ Application.get_env(:devils_dictionary, :req_options, [])

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 429} = response} ->
        {:error, {:rate_limited, retry_after(response)}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # Req's `:transient` retries a 429 by sleeping in this process — which is the
  # one thing we must not do. A 429 is the API asking us to come back later, and
  # `EnrichWorker` has a queue that can honour that; blocking here would hold a
  # connection for minutes and swallow the `Retry-After` the server sent. So the
  # retry covers 5xx and transport failures only, and 429 falls through to the
  # caller as `{:rate_limited, seconds}`.
  defp retry?(_request, %Req.Response{status: status}), do: status >= 500
  defp retry?(_request, %{__exception__: true}), do: true
  defp retry?(_request, _other), do: false

  @doc "The line every Wikimedia endpoint sees. Set in `config/config.exs`."
  def user_agent do
    Application.get_env(
      :devils_dictionary,
      :user_agent,
      "wordhoard/0.1 (https://github.com/razrfly/dictionary)"
    )
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, _} -> max(seconds, 1)
          :error -> 60
        end

      [] ->
        60
    end
  end
end
