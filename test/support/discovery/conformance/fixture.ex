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
  The three shapes every provider's API can answer in.

    * `:results` — one page that matches, and no page after it
    * `:empty` — a well-formed answer with nothing in it, which is a negative
      cache and never a failure
    * `:paged` — a first page that hands back a cursor, and a second page
  """
  @type scenario :: :results | :empty | :paged

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
  """
  @callback stub(scenario(), context :: map()) :: %{pages: [[String.t()]]}

  @doc """
  Anything this fixture needs in the test context, merged into it once per test.

  The default is an empty map. The seeded source catalog and the provider
  overrides are the suite's job, not a fixture's.
  """
  @callback setup(context :: map()) :: map()

  @optional_callbacks setup: 1, uncovered_target: 1

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
