defmodule DevilsDictionary.Absorb.Source do
  @moduledoc """
  Behaviour every source implements: a dump (WordNet, Wiktionary), an API
  (Wikidata, Wikipedia), a static file (Bierce), and later a human channel,
  a bot or a media provider.

  Mirrors Cinegraph's `ApiProcessors.Behaviour`. Rules (issue #69 §0/§5):

    * `absorb/2` streams a dump or static file into `source_records`, scoped or full.
    * `enrich/2` performs one on-demand fetch for a target (a lexeme, a concept,
      later a URL to unfurl) and returns the stored record, an `{:absent, until}`
      marker, or an error. Never bulk.
    * `materialize/1` is pure and idempotent: raw record in, normalized rows out.
      The `Materializer` writes them together with `materialized_at` in one
      transaction, so an orphaned record can never exist.
    * `trim/1` drops the parts of a payload we never use before it is stored
      (for Wiktionary: translations, descendants, templates).
    * `rate_limit_ms/0` is honoured by the enrich worker; quota or 429 snoozes,
      never discards.
  """

  @type scope :: struct() | nil
  @type stats :: map()
  @type target :: term()
  @type record :: struct()

  @callback slug() :: String.t()
  @callback absorb(scope, keyword()) :: {:ok, stats} | {:error, term()}
  @callback enrich(target, keyword()) ::
              {:ok, record} | {:absent, DateTime.t()} | {:error, term()}
  @callback materialize(record) :: {:ok, map()} | {:error, term()}
  @callback trim(raw :: map()) :: map()
  @callback rate_limit_ms() :: non_neg_integer()

  @optional_callbacks absorb: 2, enrich: 2
end
