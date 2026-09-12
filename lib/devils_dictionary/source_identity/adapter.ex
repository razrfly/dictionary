defmodule DevilsDictionary.SourceIdentity.Adapter do
  @moduledoc """
  Contract for turning a provider record into a durable identity proposal.

  Adapters keep provider parsing at the edge and return a validated
  `DevilsDictionary.SourceIdentity.Entry`. The entry names the registry kind
  and subtype, a stable source identifier, any exact cross-source identifiers,
  source-supported display facts, creator/author references, eligibility and
  retention policy. The resolver owns matching and creation; adapters never
  merge by title.

  Film adapters are supported first. Artwork and quotation adapters use this
  same shape, but provider ingestion for those media is deliberately outside
  issue #93.
  """

  alias DevilsDictionary.SourceIdentity.Entry

  @callback identity_record(map()) :: {:ok, Entry.t()} | :ignore | {:error, term()}
end
