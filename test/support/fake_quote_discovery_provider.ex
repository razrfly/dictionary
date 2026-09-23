defmodule DevilsDictionary.FakeQuoteDiscoveryProvider do
  @moduledoc """
  A quotation provider shaped like build 4's Wikiquote provider, for #164 and
  #158 build 3. It exists so creator identity and the quotation fingerprint are
  proved through the real pipeline — admission, the prepare phase, the budget,
  the publication transaction — before any real quotation provider is allowed
  to write one. See `DevilsDictionary.FakeQuoteProviderBase`.
  """

  use DevilsDictionary.FakeQuoteProviderBase,
    slug: "quote-fixture",
    name: "Quote fixture",
    namespace: "quote_fixture",
    adapter_version: "quote.fixture.v1",
    env: :quote_fixture_rows
end
