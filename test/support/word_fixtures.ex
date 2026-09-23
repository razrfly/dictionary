defmodule DevilsDictionary.WordFixtures do
  @moduledoc """
  Factories for building a word out of its parts — the lexeme, the senses one
  source hung off it, an author's definition, the relations between words.

  Promoted out of `scope_live_test.exs` (#71 §8a.4) because the word page needs
  the same words the browse page did, plus the three rows the browse page never
  had to build.

  ## Why these go through the contexts now

  In MVP-0 they inserted through `Repo` directly, deliberately: they are
  fixtures for read-path tests, and going through the absorb path would make
  every one of them a test of the absorb path.

  That is no longer available. An identity is two rows and the database checks
  at COMMIT that both exist, so `Repo.insert!(%Lexeme{})` cannot succeed — and a
  fixture that reached around the registry would be building data the
  application cannot produce, which is the worst kind of green test. They now
  go through `Registry` and `Claims`, which are narrow enough that this is still
  a fixture and not an absorb.
  """

  import Ecto.Query

  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Claims.Catalog, as: Predicates
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Registry.{ContentItem, Entity, Lexeme}
  alias DevilsDictionary.Sources.SourceRecord

  @doc """
  A lexeme, optionally placed in a scope.

  `source_slugs` fills `source_ids`, which is what the coverage badges read.
  Pass `scope: nil` for a word outside every scope, and `enriched_at: nil` for
  a bare index row — the case most of the 1.5 million rows are in, and the one a
  page is most likely to break on.
  """
  def word!(ctx, lemma, source_slugs \\ [], opts \\ []) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: lemma,
        part_of_speech: Keyword.get(opts, :pos, "noun"),
        slug: Keyword.get(opts, :slug, Lexeme.slug(lemma)),
        pronunciations: wrap(Keyword.get(opts, :pronunciations, [])),
        etymology: Keyword.get(opts, :etymology),
        etymology_source_id: Keyword.get(opts, :etymology_source_id),
        origin_source_id: Keyword.get(opts, :origin_source_id),
        canonical_lexeme_id: Keyword.get(opts, :canonical_lexeme_id),
        metadata: Keyword.get(opts, :metadata, %{}),
        source_ids: Enum.map(source_slugs, &ctx.sources[&1].id),
        enriched_at: Keyword.get(opts, :enriched_at, DateTime.utc_now())
      })

    for form <- Keyword.get(opts, :forms, []) do
      Registry.add_form(lexeme.object_id, form["form"] || form[:form],
        tags: form["tags"] || form[:tags] || []
      )
    end

    # `scope: nil` is the deliberate way to build a word in no scope at all —
    # *quark*, real and enriched and in neither Animals nor Emotions.
    if scope = Keyword.get(opts, :scope, ctx[:animals]) do
      Repo.insert!(%ScopeMember{
        scope_id: scope.id,
        lexeme_id: lexeme.object_id,
        reasons: Keyword.get(opts, :reasons, ["wordnet_closure"])
      })
    end

    lexeme
  end

  defp wrap([]), do: %{}
  defp wrap(list) when is_list(list), do: %{"items" => list}

  @doc """
  The raw row a sense or a definition was materialized from — what the ⓘ drawer
  shows (#71 U2, row U3).

  Identity and payload are two tables now: this makes the `source_records` row
  and the `source_record_revisions` row that carries the payload, because a
  cited revision must never be overwritten. `raw` is a virtual field filled from
  the current revision, so callers reading `record.raw` still work.
  """
  def record!(ctx, source_slug, attrs \\ []) do
    source = ctx.sources[source_slug]
    now = DateTime.utc_now()
    raw = Keyword.get(attrs, :raw, %{"word" => "example", "senses" => []})
    hash = Keyword.get(attrs, :content_hash, "hash-#{System.unique_integer([:positive])}")

    record =
      Repo.insert!(%SourceRecord{
        source_id: source.id,
        external_id:
          Keyword.get(attrs, :external_id, "#{source_slug}-#{System.unique_integer([:positive])}"),
        url: Keyword.get(attrs, :url, "https://example.test/record"),
        content_hash: hash,
        fetched_at: Keyword.get(attrs, :fetched_at, now),
        changed_at: Keyword.get(attrs, :changed_at, now),
        materialized_at: Keyword.get(attrs, :materialized_at, now)
      })

    Repo.insert!(%SourceRecordRevision{
      source_record_id: record.id,
      revision_key: hash,
      payload: raw,
      checksum: hash,
      observed_at: now
    })

    %{record | raw: raw}
  end

  @doc """
  One meaning as one source asserts it, with its first revision.

  `group_key` is WordNet's synset id and nil everywhere else — it is what makes
  a synset one block on the page, and what the chain walks.
  """
  def sense!(ctx, lexeme, source_slug, attrs \\ []) do
    source = ctx.sources[source_slug]
    record = record_for(ctx, source_slug, attrs)

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: source.id,
        external_key:
          Keyword.get(
            attrs,
            :external_id,
            "#{source_slug}-#{lexeme.object_id}-#{System.unique_integer([:positive])}"
          ),
        group_key: Keyword.get(attrs, :group_key),
        gloss: Keyword.get(attrs, :gloss, "a meaning of #{lexeme.lemma}"),
        url: Keyword.get(attrs, :url, "https://example.test/#{lexeme.lemma}"),
        position: Keyword.get(attrs, :position, 0),
        tags: Keyword.get(attrs, :tags, []),
        source_record_revision_id: record && revision_id(record)
      })

    own(record, "sense", sense.object_id)

    sense
  end

  @doc """
  A dead author's definition, or an encyclopedia's summary of a thing.

  Two predicates rather than two nullable columns: a definition `defines` a
  word, an article is `about` a thing, and the endpoint rules refuse the pair
  that would have been a check constraint.
  """
  def entry!(ctx, lexeme_or_entity, source_slug, attrs \\ []) do
    source = ctx.sources[source_slug]
    record = record_for(ctx, source_slug, attrs)

    {:ok, content} =
      Registry.create_content(%{
        content_kind: Keyword.get(attrs, :kind, content_kind(lexeme_or_entity)),
        source_id: source.id,
        headword: Keyword.get(attrs, :headword),
        body: Keyword.get(attrs, :body, "A definition."),
        body_format: Keyword.get(attrs, :body_format, :markdown),
        canonical_url: Keyword.get(attrs, :url, "https://example.test/entry"),
        year: Keyword.get(attrs, :year, source.era_year),
        position: Keyword.get(attrs, :position, 0),
        source_record_revision_id: record && revision_id(record)
      })

    put_revision_metadata(content, attrs)

    {predicate, target} =
      case lexeme_or_entity do
        %Lexeme{object_id: id} -> {"defines", id}
        %Entity{object_id: id} -> {"about", id}
      end

    {:ok, assertion} =
      Claims.assert(content.object_id, predicate, target, %{source_id: source.id})

    own_assertion(record, assertion)

    if author = Keyword.get(attrs, :author) do
      {:ok, _} =
        Claims.assert(content.object_id, "authored_by", author.object_id, %{source_id: source.id})
    end

    own(record, "content", content.object_id)

    content
  end

  defp content_kind(%Lexeme{}), do: :definition
  defp content_kind(%Entity{}), do: :article

  # `pos` is the *printed* grammar marker ("n", "n. s."), never our vocabulary,
  # and the thumbnail is a fact about the article. Both are revision metadata.
  defp put_revision_metadata(content, attrs) do
    metadata =
      %{}
      |> put_some("pos_marker", Keyword.get(attrs, :pos))
      |> put_some("thumbnail_url", Keyword.get(attrs, :thumbnail_url))

    if metadata != %{} do
      revision = Registry.current_content_revision(content.object_id)

      Repo.update_all(
        from(r in "content_revisions", where: r.id == ^revision.id),
        set: [metadata: metadata]
      )
    end
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # `record: nil` is the deliberate way to build the broken case — a card with
  # no provenance, which is the failure U3 exists to catch and never the default.
  defp record_for(ctx, source_slug, attrs) do
    case Keyword.fetch(attrs, :record) do
      {:ok, nil} -> nil
      {:ok, %SourceRecord{} = record} -> record
      :error -> record!(ctx, source_slug)
    end
  end

  defp revision_id(record) do
    Repo.one(
      from r in SourceRecordRevision,
        where: r.source_record_id == ^record.id,
        order_by: [desc: r.id],
        limit: 1,
        select: r.id
    )
  end

  # Ownership, so the fixtures exercise the same reconciliation path the
  # importer does — a fixture graph that no run could have produced would make
  # M1 and D1 pass on data the application cannot make.
  defp own(nil, _role, _object_id), do: :ok

  defp own(record, role, object_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "source_materialized_outputs",
      [
        %{
          source_record_id: record.id,
          output_role: role,
          output_key: "fixture:#{object_id}",
          output_object_id: object_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  defp own_assertion(nil, _assertion), do: :ok

  defp own_assertion(record, assertion) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "source_assertion_outputs",
      [
        %{
          source_record_id: record.id,
          output_key: "fixture:#{assertion.id}",
          assertion_id: assertion.id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  @doc """
  An edge between two words, or between two meanings.

  Pass `from_sense:` to make it sense-scoped — that is the placement rule's
  whole input, and the difference between a chip inside a source card and a
  chip in the page-level *Related words* block. Pass `to_sense:` for the
  sense→sense shape WordNet's graph is made of.
  """
  def relation!(ctx, from, type, to, attrs \\ []) do
    source = ctx.sources[Keyword.get(attrs, :source, "wiktionary")]
    from_sense = Keyword.get(attrs, :from_sense)
    to_sense = Keyword.get(attrs, :to_sense)

    subject = if from_sense, do: from_sense.object_id, else: from.object_id
    object = if to_sense, do: to_sense.object_id, else: to && to.object_id

    if object do
      {:ok, assertion} =
        Claims.assert(subject, to_string(type), object, %{
          source_id: source.id,
          confidence: Keyword.get(attrs, :weight, 1.0),
          method: "source"
        })

      assertion
    else
      # An edge whose target word does not exist is not an assertion at all: it
      # waits in `pending_relations`, which is where R2 counts it.
      pending!(source, subject, type, Keyword.get(attrs, :to_lemma, "unresolved"))
    end
  end

  defp pending!(source, subject, type, to_lemma) do
    now = DateTime.utc_now()
    predicate = Claims.predicate!(to_string(type))

    Repo.insert!(%DevilsDictionary.Claims.PendingRelation{
      source_id: source.id,
      subject_object_id: subject,
      predicate_id: predicate.id,
      to_lemma: to_lemma,
      inserted_at: now,
      updated_at: now
    })
  end

  @doc """
  A thing, keyed by its Wikidata QID.

  The QID is an `external_identifiers` row, not a column — a local artwork or
  event exists without one, and adding one later leaves the identity and every
  attachment unchanged.
  """
  def concept!(qid, label, attrs \\ []) do
    attrs = Map.new(attrs)

    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: Map.get(attrs, :kind, :concept),
        preferred_label: label,
        description: Map.get(attrs, :description),
        metadata: entity_metadata(attrs)
      })

    if qid, do: Registry.add_external_id(entity.object_id, "wikidata", qid)

    entity
  end

  defp entity_metadata(attrs) do
    %{}
    |> put_some("wikipedia_title", Map.get(attrs, :wikipedia_title))
    |> put_some("image_url", Map.get(attrs, :image_url))
    |> put_some("image_attribution", Map.get(attrs, :image_attribution))
    |> put_some("taxon", Map.get(attrs, :taxon))
    |> Map.merge(Map.get(attrs, :metadata, %{}))
  end

  @doc """
  The typed, scored bridge from a word to a thing.

  Which claim it is follows the ladder's own split, so a call site reads the
  same way the linker does. `title_match` and `disambiguation` match a
  *spelling* against an article title and write `lexeme_entity_candidate`;
  every other method reads a source's own mapping from one *meaning* to one
  thing and writes `refers_to`, whose subject is a sense.

  A sense-backed link by definition has a sense, so one is made when the caller
  does not pass `sense:` — a fixture that wrote `refers_to` from a word would be
  building data the model forbids.
  """
  @word_level_methods [:title_match, :disambiguation]

  def link!(ctx_or_lexeme, entity, opts \\ [])

  def link!(lexeme, entity, opts) do
    # The default is a source's own sense mapping, because "this word names that
    # thing" is a claim about a meaning. A spelling-level guess has to say so.
    method = Keyword.get(opts, :method, :wiktionary_qid)

    {subject, predicate} =
      cond do
        method in @word_level_methods -> {lexeme.object_id, "lexeme_entity_candidate"}
        sense = Keyword.get(opts, :sense) -> {sense.object_id, "refers_to"}
        true -> {naming_sense!(lexeme, opts).object_id, "refers_to"}
      end

    {:ok, assertion} =
      Claims.assert(subject, predicate, entity.object_id, %{
        method: to_string(method),
        confidence: Keyword.get(opts, :confidence, 0.9)
      })

    # `status` was a column an importer could overwrite; it is a review now, and
    # `:auto` means nobody has reviewed it, so nothing is written for it.
    case Keyword.get(opts, :status, :auto) do
      :auto -> :ok
      decision -> Claims.review(Claims.current_revision(assertion.id).id, decision)
    end

    assertion
  end

  # The meaning a sense-backed link is *of*. A source that maps a meaning to a
  # thing has a meaning; a fixture that skipped it would be asserting
  # `refers_to` from a word, which the endpoint rules refuse.
  defp naming_sense!(lexeme, opts) do
    source_id = Keyword.get(opts, :source_id) || any_source_id()

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: source_id,
        external_key: "link-#{lexeme.object_id}-#{System.unique_integer([:positive])}",
        gloss: "a meaning of #{lexeme.lemma}"
      })

    sense
  end

  # The first source the catalog seeded — WordNet — and always that one. A bare
  # `limit: 1` returns whichever row comes first in the heap, which is the
  # first seeded only on a table nobody else is writing to. Under the async
  # suite, rows from concurrent sandboxes and the holes their rollbacks leave
  # reorder it: 9 of 68 calls in one full run came back `bierce`, `poetrydb`
  # or `wikipedia`, and the naming sense became a card of its own
  # (`["wordnet", "poetrydb"]` on `/define/quoll`).
  defp any_source_id do
    Repo.one!(from s in DevilsDictionary.Sources.Source, order_by: s.id, limit: 1, select: s.id)
  end

  @doc """
  One edge between two things — `:parent_taxon`, `:subclass_of`, `:instance_of`.
  The three the absorb actually writes, and the three the thing panel walks.
  """
  def concept_relation!(ctx, from, type, to, opts \\ []) do
    source = ctx.sources[Keyword.get(opts, :source, "wikidata")]

    {:ok, assertion} =
      Claims.assert(from.object_id, to_string(type), to.object_id, %{source_id: source.id})

    assertion
  end

  @doc """
  Registers the predicates the fixtures use. Idempotent.

  `Fixtures.seed_catalog!/0` calls it, so a test that seeds the catalog can
  assert a relation without knowing that a predicate is a row.
  """
  def seed_predicates!, do: Predicates.seed!()

  @doc "A content item's current body, for tests that assert on what was written."
  def body(%ContentItem{object_id: id}), do: Registry.current_content_revision(id).body
end
