defmodule DevilsDictionary.Discovery.Providers.Spotify.Token do
  @moduledoc """
  The Client Credentials bearer token, cached until it is nearly expired.

  Spotify is the first source here whose request needs a credential the API
  itself issues: `POST https://accounts.spotify.com/api/token` with the app's
  id and secret in HTTP Basic answers an `access_token` and an `expires_in`
  of 3,600 seconds, and one token serves every search until it expires.

  ## Why this is a process and not a `Req` call in `retrieve/4`

  Three properties the kit already guarantees for a search, and that a token
  fetched privately would quietly lose:

    * **It is a request, so it is in the ledger.** The refresh goes through
      `DevilsDictionary.Discovery.Transport` like everything else, under its
      own stage — `"token"` — so `discovery_request_attempts` records what was
      actually spent. A provider that spent a second request per run and
      reported one would make every ledger in `docs/` short.
    * **It counts against the budget**, and is paced and retried by the same
      code that paces and retries the search. `Transport` already reads `429`
      and `Retry-After`; nothing about that is re-implemented here.
    * **It is shared.** `:provider_concurrency` is 2 and a reader-driven site
      opens many word pages an hour; one token an hour is the difference
      between 1 extra request a day and 1 per page.

  ## The division of labour, and why the I/O is the caller's

  This process is the **store**; the caller does the I/O. `bearer/1` reads the
  cache, and only when the cached token is missing or inside
  `refresh_window_seconds` of expiry does it call the caller's own
  `request_fun` — the closure `DevilsDictionary.Discovery` builds around one
  run id — and hand the answer back here.

  The alternative, refreshing inside `handle_call/3`, would serialise two
  concurrent runs' refreshes but would also block this process for the length
  of an HTTP request that `Transport` may first sleep on for pacing or defer
  for budget, and it would have to invent a run to attribute the ledger row
  to. The cost of the choice made instead is bounded and visible: two runs
  that start within the same refresh both spend a token request, one extra
  row, and the second write wins. A run is one in every 86,400 seconds of
  cache, so that is a rounding error against a `429` on a blocked mailbox.

  ## The secret is never here

  The id and the secret are read from the application environment by
  `DevilsDictionary.Discovery.Providers.Spotify.request_options/1` at the
  moment the request is built, and the *token* is the only thing this process
  ever holds. Neither the credential nor the token is put in a log line, an
  assign, a URL or a `request_parameters` map.
  """

  use GenServer

  @refresh_window_seconds 60

  @typedoc "What `bearer/1` answers: the pipeline's own three-way result."
  @type result ::
          {:ok, String.t()}
          | {:error, String.t()}
          | {:deferred, String.t(), non_neg_integer()}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  How close to expiry a cached token may be and still be handed out.

  Sixty seconds, so a token is never used on a request that could outlive it.
  """
  def refresh_window_seconds, do: @refresh_window_seconds

  @doc """
  A usable bearer token, refreshing through `request_fun` when the cache is
  cold or nearly cold.

  `request_fun` is `retrieve/4`'s own, so the refresh is a ledger row against
  that run and against the source's budget. Its `{:error, _}` and
  `{:deferred, _, _}` are returned unchanged for `retrieve/4` to pass up.
  """
  @spec bearer((String.t(), map() -> term()), atom()) :: result()
  def bearer(request_fun, name \\ __MODULE__) when is_function(request_fun, 2) do
    case peek(name) do
      token when is_binary(token) ->
        {:ok, token}

      nil ->
        refresh(request_fun, name)
    end
  end

  @doc """
  The cached token when it is good for longer than the refresh window, else nil.

  `request_options/1` reads this to put the bearer header on the search, which
  is why it is a plain read with no I/O behind it: the transport builds a
  request from `request_options/1` and a provider that fetched a token there
  would be doing I/O outside `retrieve/4`.
  """
  @spec peek(atom()) :: String.t() | nil
  def peek(name \\ __MODULE__) do
    case GenServer.call(name, :peek) do
      {token, expires_at} when is_binary(token) ->
        if DateTime.diff(expires_at, DateTime.utc_now(), :second) > @refresh_window_seconds,
          do: token

      _ ->
        nil
    end
  end

  @doc """
  Forgets the cached token — or, given the token a caller found bad, forgets
  it only if it is still the one cached.

  Called when a search answers `401` — the one thing that says the token this
  process believes in is not one Spotify believes in — and by the conformance
  fixture, so each case starts from a cold cache and the token request it
  makes is visible in that case's own ledger.

  The compare matters under `:provider_concurrency` 2: two runs that both
  `401` on the same stale token would otherwise take turns — the first
  refreshes, the second clears the fresh token the first just stored, and
  the first's retry goes out with no bearer at all. A run passes the token
  it used; a stale one is cleared, a newer one is left for the retry.
  """
  @spec invalidate(String.t() | nil, atom()) :: :ok
  def invalidate(stale \\ nil, name \\ __MODULE__) when is_nil(stale) or is_binary(stale),
    do: GenServer.call(name, {:invalidate, stale})

  @doc "Stores a token and the second it expires at, computed from `expires_in`."
  @spec put(String.t(), integer(), atom()) :: :ok
  def put(token, expires_in, name \\ __MODULE__)
      when is_binary(token) and is_integer(expires_in) do
    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
    GenServer.call(name, {:put, token, expires_at})
  end

  # One token request, through the transport, and the answer stored before it
  # is handed back. A response that is a `200` but not the documented envelope
  # is `"malformed_response"`, the same code every other provider's bad body
  # gets, rather than a crash inside a GenServer call.
  defp refresh(request_fun, name) do
    case request_fun.("token", %{"grant" => "client_credentials"}) do
      {:ok, %{"access_token" => token, "expires_in" => expires_in}}
      when is_binary(token) and token != "" and is_integer(expires_in) and expires_in > 0 ->
        :ok = put(token, expires_in, name)
        {:ok, token}

      {:ok, _body} ->
        {:error, "malformed_response"}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds}
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{token: nil, expires_at: nil}}

  @impl true
  def handle_call(:peek, _from, %{token: token, expires_at: expires_at} = state),
    do: {:reply, {token, expires_at}, state}

  def handle_call({:invalidate, nil}, _from, _state),
    do: {:reply, :ok, %{token: nil, expires_at: nil}}

  def handle_call({:invalidate, stale}, _from, %{token: token} = state) do
    if token == stale,
      do: {:reply, :ok, %{token: nil, expires_at: nil}},
      else: {:reply, :ok, state}
  end

  def handle_call({:put, token, expires_at}, _from, _state),
    do: {:reply, :ok, %{token: token, expires_at: expires_at}}
end
