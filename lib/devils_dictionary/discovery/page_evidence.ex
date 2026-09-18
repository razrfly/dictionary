defmodule DevilsDictionary.Discovery.PageEvidence do
  @moduledoc """
  The Wikidata QIDs a page's senses already refer to — the encyclopedia's half
  of an identity match.

  This is the whole of the association evidence for a provider that matches by
  identity (the README's *one rule*): a result is kept when an identifier the
  provider publishes equals one of these. It is read from the encyclopedia and
  never from the provider — a sense's active `refers_to` entity is a claim
  someone can inspect and withdraw — and it is read for the page's whole lexeme
  set, which is what a target *is* since K4 of #109. `/define/war` is seven
  lexemes and the QID for Q198 hangs off a sense of the noun; reading one lexeme
  would put nothing on that page while the encyclopedia plainly says what *war*
  means. Narrowing a match to one sense belongs to the assessor (#101).

  The Met read this privately until #109 Phase 3a, when Wikimedia Commons
  became the second provider to need exactly the same read. Two copies of one
  query would be two places for the rule to drift, so it lives here and both
  providers call it.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.{AssertionRevision, Predicate}
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, Sense}
  alias DevilsDictionary.Repo

  # A page can be seven lexemes with fifteen senses between them. The QID set is
  # a match key, not a summary, and the highest-confidence handful is what a
  # search and an identifier comparison can actually use.
  @default_limit 8

  @doc """
  Whether any sense on these lexemes refers to a verified Wikidata identity.

  Coverage is an existence question and is asked as one. Every word page asks
  it before any run exists, and the answer is no for about 99% of them — so it
  must not pay for the ordering, the dedup and the labels that only a mapping
  about to be built has any use for.
  """
  def any?(lexeme_ids), do: Repo.exists?(query(lexeme_ids))

  @doc """
  The QIDs the page's senses refer to, with their labels, highest confidence
  first, at most `limit` of them, as string-keyed maps ready to be frozen into
  a mapping recipe: `"qid"`, `"label"`, `"object_id"`, `"confidence"`.
  """
  def entities(lexeme_ids, limit \\ @default_limit) do
    lexeme_ids
    |> query()
    |> select([revision: r, entity: e, identifier: ei], %{
      qid: ei.external_id,
      label: e.preferred_label,
      object_id: e.object_id,
      confidence: r.confidence
    })
    |> order_by([revision: r, entity: e], desc: r.confidence, asc: e.object_id)
    |> Repo.all()
    |> Enum.uniq_by(& &1.qid)
    |> Enum.take(limit)
    |> Enum.map(&Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
  end

  @doc """
  Every verified Wikidata identity an active `refers_to` on any of these
  lexemes' senses points at, with named bindings `:sense`, `:revision`,
  `:predicate`, `:entity` and `:identifier`. One round trip whether it is asked
  for existence or for the labels.
  """
  def query(lexeme_ids) do
    from s in Sense,
      as: :sense,
      join: r in AssertionRevision,
      as: :revision,
      on: r.subject_object_id == s.object_id and r.is_current,
      join: p in Predicate,
      as: :predicate,
      on: p.id == r.predicate_id and p.key == "refers_to",
      join: e in Entity,
      as: :entity,
      on: e.object_id == r.object_object_id,
      join: ei in ExternalIdentifier,
      as: :identifier,
      on: ei.object_id == e.object_id and ei.namespace == "wikidata",
      where: s.lexeme_id in ^lexeme_ids,
      where: r.lifecycle_state == :active and ei.status == :verified
  end

  @doc """
  A short digest of the QIDs a recipe was built from, for `mapping_identity/1`.

  A provider that freezes these QIDs into its mapping parameters would
  otherwise keep querying a concept the encyclopedia has stopped asserting:
  swapping QID A for QID B leaves the set non-empty and `covers?/1` still says
  yes. The digest covers the QIDs **in order** and not the labels, because a
  relabelled entity is the same evidence — the match key is the QID.
  """
  def digest(entities) when is_list(entities) do
    case Enum.map(entities, &entity_qid/1) do
      [] ->
        "no-entities"

      qids ->
        qids
        |> Enum.join(",")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  def digest(_entities), do: "no-entities"

  @doc "True when every entity in a frozen recipe is a well-formed QID."
  def valid_entities?(entities) when is_list(entities), do: Enum.all?(entities, &valid_entity?/1)
  def valid_entities?(_entities), do: false

  defp valid_entity?(%{"qid" => qid}) when is_binary(qid), do: Regex.match?(~r/\AQ\d+\z/, qid)
  defp valid_entity?(_entity), do: false

  defp entity_qid(%{"qid" => qid}) when is_binary(qid), do: qid
  defp entity_qid(_entity), do: ""
end
