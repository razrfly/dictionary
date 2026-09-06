defmodule DevilsDictionary.WordFixtures do
  @moduledoc """
  Factories for building a word out of its parts — the lexeme, the senses one
  source hung off it, an author's entry, the relations between words.

  Promoted out of `scope_live_test.exs` (#71 §8a.4) because the word page needs
  the same words the browse page did, plus the three rows the browse page never
  had to build. They insert through `Repo` rather than through a context: these
  are fixtures for read-path tests, and going through the absorb path would
  make every one of them a test of the absorb path.
  """

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo

  @doc """
  A lexeme, optionally placed in a scope.

  `source_slugs` fills `source_ids`, which is what the coverage badges read.
  Pass `enriched_at: nil` for a bare index row — the case most of the 1.5
  million rows are in, and the one a page is most likely to break on.
  """
  def word!(ctx, lemma, source_slugs \\ [], opts \\ []) do
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: lemma,
        pos: Keyword.get(opts, :pos, "noun"),
        slug: Keyword.get(opts, :slug, Lexeme.slug(lemma)),
        forms: Keyword.get(opts, :forms, []),
        pronunciations: Keyword.get(opts, :pronunciations, []),
        etymology: Keyword.get(opts, :etymology),
        etymology_source_id: Keyword.get(opts, :etymology_source_id),
        canonical_lexeme_id: Keyword.get(opts, :canonical_lexeme_id),
        metadata: Keyword.get(opts, :metadata, %{}),
        source_ids: Enum.map(source_slugs, &ctx.sources[&1].id),
        enriched_at: Keyword.get(opts, :enriched_at, DateTime.utc_now())
      })

    if scope = opts[:scope] || ctx[:animals] do
      Repo.insert!(%ScopeLexeme{
        scope_id: scope.id,
        lexeme_id: lexeme.id,
        reasons: Keyword.get(opts, :reasons, ["wordnet_closure"])
      })
    end

    lexeme
  end

  @doc """
  One meaning as one source asserts it.

  `group_key` is WordNet's synset id and nil everywhere else — it is what makes
  a synset one block on the page, and what the chain walks.
  """
  def sense!(ctx, lexeme, source_slug, attrs \\ []) do
    source = ctx.sources[source_slug]

    Repo.insert!(%Sense{
      lexeme_id: lexeme.id,
      source_id: source.id,
      external_id:
        Keyword.get(
          attrs,
          :external_id,
          "#{source_slug}-#{lexeme.id}-#{System.unique_integer([:positive])}"
        ),
      group_key: Keyword.get(attrs, :group_key),
      gloss: Keyword.get(attrs, :gloss, "a meaning of #{lexeme.lemma}"),
      url: Keyword.get(attrs, :url, "https://example.test/#{lexeme.lemma}"),
      position: Keyword.get(attrs, :position, 0),
      tags: Keyword.get(attrs, :tags, [])
    })
  end

  @doc "A dead author's entry, or an encyclopedia's summary of a thing."
  def entry!(ctx, lexeme_or_concept, source_slug, attrs \\ []) do
    source = ctx.sources[source_slug]

    {lexeme_id, concept_id} =
      case lexeme_or_concept do
        %Lexeme{id: id} -> {id, nil}
        %Concept{id: id} -> {nil, id}
      end

    Repo.insert!(%Entry{
      lexeme_id: lexeme_id,
      concept_id: concept_id,
      source_id: source.id,
      headword: Keyword.get(attrs, :headword),
      pos: Keyword.get(attrs, :pos),
      body: Keyword.get(attrs, :body, "A definition."),
      body_format: Keyword.get(attrs, :body_format, :markdown),
      url: Keyword.get(attrs, :url, "https://example.test/entry"),
      thumbnail_url: Keyword.get(attrs, :thumbnail_url),
      year: Keyword.get(attrs, :year, source.era_year),
      position: Keyword.get(attrs, :position, 0)
    })
  end

  @doc """
  An edge between two words.

  Pass `from_sense:` to make it sense-scoped — that is the placement rule's
  whole input, and the difference between a chip inside a source card and a
  chip in the page-level *Related words* block.
  """
  def relation!(ctx, from, type, to, attrs \\ []) do
    source = ctx.sources[Keyword.get(attrs, :source, "wiktionary")]
    from_sense = Keyword.get(attrs, :from_sense)

    Repo.insert!(%LexicalRelation{
      source_id: source.id,
      from_lexeme_id: from.id,
      from_sense_id: from_sense && from_sense.id,
      to_lexeme_id: to && to.id,
      to_lemma: Keyword.get(attrs, :to_lemma, (to && to.lemma) || "unresolved"),
      to_pos: to && to.pos,
      to_group_key: Keyword.get(attrs, :to_group_key),
      type: type,
      weight: Keyword.get(attrs, :weight, 1.0)
    })
  end

  @doc "A thing, keyed by its Wikidata QID."
  def concept!(qid, label, attrs \\ []) do
    Repo.insert!(struct(%Concept{qid: qid, label: label, kind: :thing}, attrs))
  end

  @doc "The typed, scored bridge from a word to a thing."
  def link!(lexeme, concept, opts \\ []) do
    Repo.insert!(%ConceptLink{
      lexeme_id: lexeme.id,
      concept_id: concept.id,
      method: Keyword.get(opts, :method, :title_match),
      confidence: Keyword.get(opts, :confidence, 0.9),
      status: Keyword.get(opts, :status, :auto)
    })
  end
end
