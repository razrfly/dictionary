defmodule DevilsDictionary.FakeWiktionaryQuoteProvider do
  @moduledoc """
  Wiktionary's quotations as a second source on the Quotes shelf, for #158
  build 4's multi-source case.

  Build 1 (Wiktionary's absorbed lines rendered on the word page) has not
  landed, so this stands in for it with the same entry shape every quote
  source uses (`FakeQuoteProviderBase`): its own id, the line's fingerprint,
  and a credit by QID. A line it and Wikiquote both hold folds to one card
  naming both.
  """

  use DevilsDictionary.FakeQuoteProviderBase,
    slug: "wiktionary-quotes-fixture",
    name: "Wiktionary",
    namespace: "wiktionary_quote",
    adapter_version: "wiktionary.quotes.fixture.v1",
    env: :wiktionary_quote_rows,
    content_types: [:quote]
end
