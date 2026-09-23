defmodule DevilsDictionary.FakeQuoteMirrorDiscoveryProvider do
  @moduledoc """
  A second quotation source over the same #158 fixture, with its own slug, its
  own id namespace and its own rows — so one line can reach the registry from
  two providers, which is what the fingerprint fold (#158 build 3) is proved
  with. Stands in for Wiktionary beside Wikiquote until builds 1 and 4 exist.
  """

  use DevilsDictionary.FakeQuoteProviderBase,
    slug: "quote-mirror",
    name: "Quote mirror",
    namespace: "quote_mirror",
    adapter_version: "quote.mirror.v1",
    env: :quote_mirror_rows
end
