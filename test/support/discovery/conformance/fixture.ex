defmodule DevilsDictionary.Discovery.Conformance.Fixture do
  @moduledoc """
  What a provider has to supply so the shared conformance suite can drive it.

  The suite knows the pipeline and nothing about any provider: it cannot invent
  a target the Met covers, and it cannot invent the JSON CineGraph returns. A
  fixture supplies exactly those two things — the page evidence and the
  provider's own `Req.Test` stub — and the suite supplies everything else.

  A fixture is **not** a second implementation of the provider. `stub/2` returns
  the external ids the responses it just installed will yield, per page, and the
  suite asserts the pipeline delivered those and no others. Getting that list
  wrong makes the suite fail, which is the point.
  """

  alias DevilsDictionary.Discovery

  @typedoc """
  The four shapes every provider's API can answer in.

    * `:results` — one page that matches, and no page after it
    * `:empty` — a well-formed answer with nothing in it, which is a negative
      cache and never a failure
    * `:paged` — a first page that hands back a cursor, and a second page
    * `:throttled` — a `429` carrying `Retry-After` on the **first** request and
      the `:results` answer on the one after it

  A fixture supplies the first three. `:throttled` is the kit's, installed by
  `stub/3` on top of whatever the fixture's own `:results` returns: a 429 and a
  `Retry-After` header are HTTP and not a provider's dialect, and nine
  providers implement the `{:deferred, …}` path this exercises without one line
  of the suite ever having driven it (#144 Phase 0).
  """
  @type scenario :: :results | :empty | :paged | :throttled

  @doc "The provider module this fixture drives."
  @callback provider() :: module()

  @doc """
  A target this provider covers, with whatever evidence that took.

  CineGraph covers any word; the Met covers only a page whose senses already
  refer to a Wikidata QID, so its fixture writes the `refers_to` claim here.
  """
  @callback covered_target(context :: map()) :: Discovery.target()

  @doc """
  A target this provider declines, or `nil` when it declines nothing.

  `covers?/1` is optional in the contract and its default is `true`, so most
  providers answer `nil` and the suite skips the case rather than inventing one.
  """
  @callback uncovered_target(context :: map()) :: Discovery.target() | nil

  @doc """
  Installs this provider's `Req.Test` stub for one scenario.

  Returns `%{pages: [[external_id]]}` — what the installed responses will
  produce, in order, one list per page. The suite asserts against it.

  Called for `:results`, `:empty` and `:paged`. `:throttled` is built from
  `:results` by `stub/3` and never reaches a fixture.
  """
  @callback stub(scenario(), context :: map()) :: %{pages: [[String.t()]]}

  @doc """
  Anything this fixture needs in the test context, merged into it once per test.

  The default is an empty map. The seeded source catalog and the provider
  overrides are the suite's job, not a fixture's.
  """
  @callback setup(context :: map()) :: map()

  @doc """
  Installs the stubs for #164's creator case and says what to expect.

  One result whose creator the provider identifies (a QID it read, or an
  identifier the kit crosswalks to one) and one it cannot, from the same run.
  Returns `%{credited: external_id, qid: qid, text_only: external_id}`, and
  optionally `certainty:` (`:verified` when absent): the
  suite asserts the first is credited to the person holding `qid` and linked
  on the card, and the second writes nothing and stays text. Optional: a
  provider whose results name no creator has no case to supply.
  """
  @callback creator_case(context :: map()) :: %{
              required(:credited) => String.t(),
              required(:qid) => String.t(),
              required(:text_only) => String.t(),
              optional(:certainty) => :verified | :candidate
            }

  @optional_callbacks setup: 1, uncovered_target: 1, creator_case: 1

  @doc """
  Installs one scenario's responses, the shared ones included.

  The suite calls this rather than `fixture.stub/2` so `:throttled` can be the
  kit's and not eleven copies of the same 429. `Req.Test.expect/3`'s
  expectations are consumed **before** the stub, so one expectation in front of
  the fixture's own `:results` stub is exactly "429 first, 200 after".
  """
  def stub(fixture, :throttled, context) do
    pages = fixture.stub(:results, context)
    throttle_once(fixture.provider())
    pages
  end

  def stub(fixture, scenario, context), do: fixture.stub(scenario, context)

  @doc """
  Answers the next request to `provider` with `429` and a `Retry-After`.

  One request only. What the transport does with it is the thing under test:
  read the header, persist the provider-wide backoff on the source row, and
  hand the run back as `{:deferred, "provider_retry_after", seconds}` without
  retrying into the throttle that produced it.
  """
  def throttle_once(provider, retry_after_seconds \\ 60) do
    Req.Test.expect(provider, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
      |> Plug.Conn.send_resp(429, "")
    end)

    :ok
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour DevilsDictionary.Discovery.Conformance.Fixture

      import DevilsDictionary.WordFixtures

      @impl true
      def setup(_context), do: %{}

      @impl true
      def uncovered_target(_context), do: nil

      defoverridable setup: 1, uncovered_target: 1
    end
  end
end
