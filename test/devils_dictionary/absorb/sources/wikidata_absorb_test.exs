defmodule DevilsDictionary.Absorb.Sources.WikidataAbsorbTest do
  @moduledoc """
  `absorb/2` end to end: where the seed QIDs come from, the parent walk, and the
  second materialize pass that closes the taxonomy edges the first cannot.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.{Fixtures, Repo}
  alias DevilsDictionary.Lexicon.{Lexeme, ScopeLexeme, Sense}
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp scoped_sense!(ctx, lemma, source_slug, metadata) do
    lexeme =
      Repo.insert!(%Lexeme{lang: "en", lemma: lemma, pos: "noun", slug: Lexeme.slug(lemma)})

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: ["wordnet_closure"]
    })

    source = ctx.sources[source_slug]

    record =
      Repo.insert!(%SourceRecord{
        source_id: source.id,
        external_id: "#{lemma}/1",
        raw: %{},
        fetched_at: DateTime.utc_now()
      })

    Repo.insert!(%Sense{
      lexeme_id: lexeme.id,
      source_id: source.id,
      source_record_id: record.id,
      external_id: "#{lemma}#1",
      metadata: metadata
    })

    lexeme
  end

  # A three-tier taxonomy: species -> genus -> family, so the walk has more than
  # one tier to do and the second materialize pass has something to close.
  defp entity(id, attrs) do
    Map.merge(%{"id" => id, "labels" => %{}, "descriptions" => %{}, "claims" => %{}}, attrs)
  end

  defp taxon(id, name, parent) do
    claims = %{
      "P225" => [%{"mainsnak" => %{"datavalue" => %{"value" => name, "type" => "string"}}}]
    }

    claims =
      if parent do
        Map.put(claims, "P171", [
          %{
            "mainsnak" => %{
              "datavalue" => %{"value" => %{"id" => parent}, "type" => "wikibase-entityid"}
            }
          }
        ])
      else
        claims
      end

    entity(id, %{"claims" => claims, "labels" => %{"mul" => %{"value" => name}}})
  end

  defp stub(entities) do
    counter = :counters.new(1, [])

    Req.Test.stub(Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      :counters.add(counter, 1, 1)
      ids = String.split(conn.query_params["ids"] || "", "|", trim: true)
      found = for id <- ids, e = entities[id], into: %{}, do: {id, e}
      Req.Test.json(conn, %{"entities" => found})
    end)

    counter
  end

  test "seeds from WordNet and Wiktionary sense metadata, then walks the parents", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q20980826"})
    scoped_sense!(ctx, "lion", "wiktionary", %{"wikidata" => ["Q140"]})

    stub(%{
      "Q20980826" => taxon("Q20980826", "Felis catus", "Q41960"),
      "Q140" => taxon("Q140", "Panthera leo", "Q41960"),
      "Q41960" => taxon("Q41960", "Felidae", "Q729"),
      "Q729" => taxon("Q729", "Animalia", nil)
    })

    assert {:ok, stats} = Wikidata.absorb(ctx.animals, rate_limit_ms: 0)

    assert stats.seed_qids == 3
    assert stats.fetched == 4
    assert stats.truncated == false
    assert Repo.aggregate(Concept, :count) == 4
  end

  test "the concept seed is this scope's concepts, not the whole table", ctx do
    # #70 S5c. `concept_qids/0` read every row of `concepts`, so scope N walked
    # every concept scopes 1..N-1 had introduced: an 809-lexeme `emotions`
    # scope seeded 72,108 QIDs and fetched 28,084 records in sixteen minutes.
    # With one scope the bug is invisible, because the whole table is that
    # scope.
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q20980826"})

    mine = Repo.insert!(%Concept{qid: "Q9001", label: "mine", kind: :thing})
    Repo.insert!(%Concept{qid: "Q9002", label: "elsewhere", kind: :thing})

    Repo.insert!(%ConceptLink{
      lexeme_id: Repo.one!(from l in Lexeme, where: l.lemma == "cat", select: l.id),
      concept_id: mine.id,
      method: :title_match,
      confidence: 0.7
    })

    seeds = Wikidata.seed_qids(ctx.animals)

    assert "Q9001" in seeds
    refute "Q9002" in seeds

    # A run with no scope is a full refresh and still walks everything.
    assert "Q9002" in Wikidata.seed_qids(nil)
  end

  test "a candidate below the promotion line is not chased", ctx do
    scoped_sense!(ctx, "seal", "wordnet", %{"wikidata" => "Q20980826"})

    maybe = Repo.insert!(%Concept{qid: "Q9003", label: "BYD Seal", kind: :thing})

    Repo.insert!(%ConceptLink{
      lexeme_id: Repo.one!(from l in Lexeme, where: l.lemma == "seal", select: l.id),
      concept_id: maybe.id,
      method: :disambiguation,
      confidence: 0.4,
      status: :candidate
    })

    refute "Q9003" in Wikidata.seed_qids(ctx.animals)
  end

  test "the second materialize pass closes edges the first could not resolve", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q20980826"})

    stub(%{
      "Q20980826" => taxon("Q20980826", "Felis catus", "Q41960"),
      "Q41960" => taxon("Q41960", "Felidae", "Q729"),
      "Q729" => taxon("Q729", "Animalia", nil)
    })

    assert {:ok, %{concept_relations: closed, parent_taxon_unresolved: 0}} =
             Wikidata.absorb(ctx.animals, rate_limit_ms: 0)

    # Felis catus -> Felidae -> Animalia. A parent named by a child in an
    # earlier tier only exists once the later tier is fetched, which is why the
    # absorb keeps re-materializing until nothing is left unresolved.
    assert closed == 2
    assert Repo.aggregate(ConceptRelation, :count) == 2
  end

  test "a synset carrying an array of QIDs seeds every one of them", ctx do
    # `panther` maps onto two Wikidata items, so WordNet stores an array where it
    # usually stores a bare string. Reading only the string shape skipped 1,887
    # senses — 265 of them in the Animals scope — and neither the concept nor the
    # `wordnet_wikidata` link was ever seeded for them.
    scoped_sense!(ctx, "panther", "wordnet", %{"wikidata" => ["Q35255", "Q109647288"]})

    stub(%{
      "Q35255" => taxon("Q35255", "Panthera pardus", nil),
      "Q109647288" => taxon("Q109647288", "Puma concolor", nil)
    })

    # Three seeds: both of the synset's QIDs plus the scope's Wikidata root,
    # which the stub does not answer for.
    assert {:ok, %{seed_qids: 3, fetched: 2}} = Wikidata.absorb(ctx.animals, rate_limit_ms: 0)

    assert Repo.all(from c in Concept, select: c.qid, order_by: c.qid) ==
             ["Q109647288", "Q35255"]
  end

  test "an edge naming a parent nobody fetched is reported, not looped on", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q20980826"})

    # Felidae is named as the parent but the walk is stopped before it, so the
    # edge can never close. It must show up as a number rather than spin the
    # re-materialize loop or read as a clean run.
    stub(%{"Q20980826" => taxon("Q20980826", "Felis catus", "Q41960")})

    assert {:ok, %{concept_relations: 0, parent_taxon_unresolved: 1, unchased_edges: 0}} =
             Wikidata.absorb(ctx.animals, rate_limit_ms: 0)
  end

  test "says so when the walk is cut off rather than letting L3 read soft", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q1"})

    stub(Map.new(1..10, fn n -> {"Q#{n}", taxon("Q#{n}", "T#{n}", "Q#{n + 1}")} end))

    assert {:ok, %{truncated: true, tiers: 2}} =
             Wikidata.absorb(ctx.animals, rate_limit_ms: 0, max_depth: 2)
  end

  test "a QID Wikidata does not know becomes an absent marker", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q99999"})
    stub(%{})

    # Two: the unknown QID, plus the scope's own root, which is always seeded so
    # the `wikidata_taxon` rule has somewhere to start its walk.
    assert {:ok, %{absent: 2, fetched: 0}} = Wikidata.absorb(ctx.animals, rate_limit_ms: 0)
    assert Repo.aggregate(Concept, :count) == 0
  end

  test "a second run costs nothing, and --refresh is how a snapshot moves", ctx do
    scoped_sense!(ctx, "cat", "wordnet", %{"wikidata" => "Q729"})
    counter = stub(%{"Q729" => taxon("Q729", "Animalia", nil)})

    Wikidata.absorb(ctx.animals, rate_limit_ms: 0)
    first = :counters.get(counter, 1)
    assert first > 0

    assert {:ok, %{requests: 0, fetched: 0}} = Wikidata.absorb(ctx.animals, rate_limit_ms: 0)
    assert :counters.get(counter, 1) == first

    assert {:ok, %{fetched: 1}} =
             Wikidata.absorb(ctx.animals, rate_limit_ms: 0, refresh: true)
  end

  test "refuses to run before anything has seeded a QID", ctx do
    _ = ctx
    # A scope with no `wikidata_root` and no QID-bearing senses has nothing to
    # ask about; the Animals scope always has at least its root.
    rootless =
      Repo.insert!(%DevilsDictionary.Lexicon.Scope{slug: "empty", name: "Empty", rules: %{}})

    assert_raise RuntimeError, ~r/mix dd.absorb wikipedia/, fn ->
      Wikidata.absorb(rootless, rate_limit_ms: 0)
    end
  end
end
