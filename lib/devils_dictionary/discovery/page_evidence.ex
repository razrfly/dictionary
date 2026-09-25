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

  ## Two tiers (#172 build B)

  Tier 1 is the above: a sense's `refers_to`, a claim about one meaning. It
  covers about 1 % of English words. Tier 2 is what the ladder
  (`DevilsDictionary.Absorb.Linker`) already wrote for the *word*: a
  `lexeme_entity_candidate` that a second, independent signal corroborated,
  at confidence 0.85 or more. It is read **only when tier 1 has nothing**
  (C2): a page that has a sense-backed identity never mixes in a spelling's,
  and a shelf is never half one level and half the other.

  Every entry says which tier it came from, `"level"`: `"sense"` or
  `"word"`. A word-level identity is still an identifier reached by a stated
  ladder rung and never a lemma search at read time (C1), but it is not a
  claim about a meaning, so every result built from one carries
  `level_details/2` and the page says so (C4). When `Linker.corroborate/1`
  promotes a candidate to a sense's `refers_to`, the page moves to tier 1,
  its recipe's `digest/1` changes, and the label goes.
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
  Whether any sense on these lexemes refers to a verified Wikidata identity,
  or, failing that, a corroborated candidate names one for the word.

  Coverage is an existence question and is asked as one. Every word page asks
  it before any run exists, and the answer is no for about 99% of them — so it
  must not pay for the ordering, the dedup and the labels that only a mapping
  about to be built has any use for.
  """
  def any?(lexeme_ids),
    do: Repo.exists?(query(lexeme_ids)) or Repo.exists?(word_query(lexeme_ids))

  # The ladder's asserted floor for a word-level identity: `corroborate/1`
  # raises a title match to 0.85 (a gloss agrees) or 0.90 (a taxon name, or a
  # QID rung naming the same entity). An uncorroborated title match (0.70) or
  # a disambiguation candidate (≤ 0.60) is a possibility, not an identity.
  @word_floor 0.85

  @doc "The least confidence a word-level candidate is read at."
  def word_floor, do: @word_floor

  @doc """
  The QIDs the page refers to, with their labels, highest confidence first, at
  most `limit` of them, as string-keyed maps ready to be frozen into a mapping
  recipe: `"qid"`, `"label"`, `"object_id"`, `"confidence"` and `"level"`.

  The sense-backed tier when it has anything, every entry `"level" =>
  "sense"`; the word-level tier only when it does not, every entry `"level"
  => "word"`. Never both (C2).
  """
  def entities(lexeme_ids, limit \\ @default_limit) do
    case tier(query(lexeme_ids), limit, "sense") do
      [] -> tier(word_query(lexeme_ids), limit, "word")
      sense -> sense
    end
  end

  defp tier(query, limit, level) do
    query
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
    |> Enum.map(
      &(&1
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
        |> Map.put("level", level))
    )
  end

  @doc """
  The level a frozen recipe's entities were read at: `"word"` when they came
  from the word-level tier, `"sense"` otherwise — including a recipe frozen
  before the level existed, which could only have been sense-backed.
  """
  def level([%{"level" => "word"} | _]), do: "word"
  def level(_entities), do: "sense"

  @doc """
  What a result built from these entities adds to its `match_details`.

  Nothing but the level for a sense-backed recipe. For a word-level one, the
  level, the evidence class the content-type table admits it under
  (`:word_identity`, not `:identity`) and the page's word, which the reason's
  sentence names: *For the word “grief”, not a particular sense.* One map,
  so the three providers that read this module label a word-level result in
  one way and cannot forget half of it.
  """
  def level_details(entities, term) when is_list(entities),
    do: level_details(level(entities), term)

  def level_details("word", term) when is_binary(term),
    do: %{"level" => "word", "evidence" => "word_identity", "query" => term}

  def level_details("word", _term), do: %{"level" => "word", "evidence" => "word_identity"}
  def level_details(_level, _term), do: %{"level" => "sense"}

  @doc """
  A provider's `retrieve/4` answer with `level_details/2` merged into every
  item's `match_details`, read off the recipe it was retrieved for.

  Applied once, to the answer, rather than in each item builder: a provider
  has one retrieve and several builders (Wikiquote's quotations and its
  register rows), and a builder that forgot the label would put a word-level
  result on the shelf as a sense-level one — the thing C4 forbids.
  """
  def labelled({:ok, %{items: items} = page}, mapping) when is_list(items) and is_map(mapping) do
    details = level_details(mapping["entities"], mapping["term"])

    {:ok,
     %{
       page
       | items:
           Enum.map(
             items,
             &Map.update(&1, :match_details, details, fn d -> Map.merge(d || %{}, details) end)
           )
     }}
  end

  def labelled(other, _mapping), do: other

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
  Every verified Wikidata identity a corroborated, active
  `lexeme_entity_candidate` on these lexemes points at — the word-level tier.
  The same named bindings as `query/1` but `:sense`, which a word-level claim
  has none of: its subject is the lexeme.
  """
  def word_query(lexeme_ids) do
    from r in AssertionRevision,
      as: :revision,
      join: p in Predicate,
      as: :predicate,
      on: p.id == r.predicate_id and p.key == "lexeme_entity_candidate",
      join: e in Entity,
      as: :entity,
      on: e.object_id == r.object_object_id,
      join: ei in ExternalIdentifier,
      as: :identifier,
      on: ei.object_id == e.object_id and ei.namespace == "wikidata",
      where: r.subject_object_id in ^lexeme_ids and r.is_current,
      where: r.lifecycle_state == :active and ei.status == :verified,
      where: r.confidence >= @word_floor
  end

  @doc """
  A short digest of the QIDs a recipe was built from, for `mapping_identity/1`.

  A provider that freezes these QIDs into its mapping parameters would
  otherwise keep querying a concept the encyclopedia has stopped asserting:
  swapping QID A for QID B leaves the set non-empty and `covers?/1` still says
  yes. The digest covers the QIDs **in order** and not the labels, because a
  relabelled entity is the same evidence — the match key is the QID.

  And the level, when it is `"word"`: promoting *grief*'s candidate to a
  sense's `refers_to` leaves the QID where it was, and the recipe still has
  to change, because the reason it gives does. A sense-backed recipe digests
  exactly as it did before the level existed, so no existing mapping is
  re-versioned by this.
  """
  def digest(entities) when is_list(entities) do
    case Enum.map(entities, &entity_qid/1) do
      [] ->
        "no-entities"

      qids ->
        if(level(entities) == "word", do: ["word" | qids], else: qids)
        |> Enum.join(",")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  def digest(_entities), do: "no-entities"

  @doc """
  True when every entity in a frozen recipe is a well-formed QID, at a known
  level, and all at the same one (C2).
  """
  def valid_entities?(entities) when is_list(entities) do
    Enum.all?(entities, &valid_entity?/1) and
      entities |> Enum.map(&Map.get(&1, "level", "sense")) |> Enum.uniq() |> length() <= 1
  end

  def valid_entities?(_entities), do: false

  defp valid_entity?(%{"qid" => qid} = entity) when is_binary(qid),
    do: Regex.match?(~r/\AQ\d+\z/, qid) and Map.get(entity, "level", "sense") in ~w(sense word)

  defp valid_entity?(_entity), do: false

  defp entity_qid(%{"qid" => qid}) when is_binary(qid), do: qid
  defp entity_qid(_entity), do: ""
end
