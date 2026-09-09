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
    * `sense_key_stability/0` says whether this source's sense keys are stable by
      construction. The default is `:positional` — the assumption that costs
      nothing if wrong — and only a source whose key is derived from something
      the source itself keeps stable may answer `:stable`.
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

  @doc """
  Whether this source's sense keys identify a meaning by construction.

  `:positional` — the default, and what every source gets unless it says
  otherwise — means the key encodes a *place* in a payload. Wiktionary's
  `word/pos/etym#position` is the case #74 exists for: delete one meaning from
  the middle and everything after it renumbers, so the key survives while the
  meaning under it changes. Those senses are matched on content.

  `:stable` means the key is derived from an identifier the source itself keeps
  stable across releases. WordNet's `oewn-84481488-n#sequoia` is a synset id and
  a member name; the synset id is the thing WordNet promises. For such a source
  the key **is** the identity, and content matching is not merely unnecessary
  but wrong: *sequoia* the tree (`oewn-89665091-n`) and *sequoia* the wood
  (`oewn-84481488-n`) share a lemma and 0.79 of their gloss, and matching them
  on content collapsed 194 synsets into their neighbours before this callback
  existed.
  """
  @callback sense_key_stability() :: :stable | :positional

  @optional_callbacks absorb: 2, enrich: 2, sense_key_stability: 0
end
