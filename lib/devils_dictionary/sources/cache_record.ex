defmodule DevilsDictionary.Sources.CacheRecord do
  @moduledoc """
  Source records that are lookup caches, not the source's own records.

  The quotation verifier (`Quotations.Verifier.Checks`) keeps each provider
  lookup it relies on as a pinned, revisioned record of that provider's
  source: a verification cites the exact revision it saw. Some of those
  lookups go to Wikidata, so the `wikidata` source holds records that are not
  entity payloads — a sitelink title, a list of Gutenberg works. They belong in
  a snapshot and a replay archive like any other record, but no materializer
  may treat them as entities.

  Each is keyed `NAMESPACE:ID`, and the namespaces are registered here, per
  source, so the verifier that writes them and the absorb module that must
  recognise them read one list.
  """

  @namespaces %{"wikidata" => ~w(enwikiquote-sitelink gutenberg-works)}

  @doc "The cache namespaces registered for a source slug."
  def namespaces(source_slug), do: Map.get(@namespaces, source_slug, [])

  @doc "The external id of a cache record; raises for an unregistered namespace."
  def key(source_slug, namespace, id) do
    if namespace in namespaces(source_slug),
      do: "#{namespace}:#{id}",
      else:
        raise(ArgumentError, "#{namespace} is not a registered #{source_slug} cache namespace")
  end

  @doc "Whether `external_id` names a cache record of `source_slug`."
  def cache?(source_slug, external_id) when is_binary(external_id) do
    case String.split(external_id, ":", parts: 2) do
      [namespace, _id] -> namespace in namespaces(source_slug)
      _ -> false
    end
  end

  def cache?(_source_slug, _external_id), do: false
end
