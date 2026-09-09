defmodule DevilsDictionary.HealthCoverageTest do
  @moduledoc """
  The absorb rows S3 added — A1, A2, A3, A4, A8 — plus R1 and X3, each against a
  small hand-built graph so the expected number is obvious by inspection rather
  than re-derived from the query under test.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Claims, Health, Registry, Repo}
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Sources.{ImportRun, SourceRecord}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp lexeme!(lemma, attrs \\ []) do
    attrs = Map.new(attrs)
    {forms, attrs} = Map.pop(attrs, :forms, [])
    {lang, attrs} = Map.pop(attrs, :lang, "en")

    {:ok, lexeme} =
      Registry.create_lexeme(
        Map.merge(%{language_tag: lang, lemma: lemma, part_of_speech: "noun"}, attrs)
      )

    for form <- forms do
      Registry.add_form(lexeme.object_id, form["form"], tags: form["tags"] || [])
    end

    lexeme
  end

  defp sense!(lexeme, source, record, attrs) do
    {:ok, sense} =
      Registry.create_sense(
        Map.merge(
          %{
            lexeme_id: lexeme.object_id,
            source_id: source.id,
            source_record_revision_id: revision_id(record)
          },
          Map.new(attrs)
        )
      )

    sense
  end

  defp revision_id(record) do
    Repo.one(
      from r in DevilsDictionary.Corpus.SourceRecordRevision,
        where: r.source_record_id == ^record.id,
        order_by: [desc: r.id],
        limit: 1,
        select: r.id
    )
  end

  defp run!(source, status, attrs \\ []) do
    Repo.insert!(
      struct(
        %ImportRun{
          source_id: source.id,
          task: "absorb",
          status: status,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          stats: %{}
        },
        Map.new(attrs)
      )
    )
  end

  defp record!(source, external_id) do
    Repo.insert!(%SourceRecord{
      source_id: source.id,
      external_id: external_id,
      raw: %{},
      fetched_at: DateTime.utc_now()
    })
  end

  describe "sources/0 (A1)" do
    test "counts done runs only, never failed or running ones", ctx do
      # `import_runs` carries dev history: two failed link runs and one absorb
      # stopped on purpose. A row that counted those would report a source as
      # absorbed when it had not been.
      run!(ctx.sources["wordnet"], :done)
      run!(ctx.sources["wordnet"], :failed)
      run!(ctx.sources["wiktionary"], :running)

      result = Health.source_runs()
      by_slug = Map.new(result.sources, &{&1.slug, &1})

      expected = length(DevilsDictionary.Sources.Catalog.sources())
      assert result.expected == expected
      assert result.present == expected
      assert by_slug["wordnet"].runs == 1
      assert by_slug["wiktionary"].runs == 0
      assert result.absorbed == 1
    end

    test "a dump pins its file date, an API the day we asked", ctx do
      run!(ctx.sources["wikipedia"], :done)

      by_slug = Map.new(Health.source_runs().sources, &{&1.slug, &1})

      assert by_slug["wiktionary"].snapshot == "dump_date=2026-08-28"
      assert by_slug["bierce"].snapshot == "gutenberg_id=972"
      # Wikipedia has no file to pin, so what pins it is when it was fetched.
      assert by_slug["wikipedia"].snapshot =~ "fetched="
      # …and a source never absorbed has no pin at all.
      assert by_slug["wikidata"].snapshot == nil
    end
  end

  describe "wordnet/0 (A2)" do
    test "counts synset groups and the lexemes carrying their senses", ctx do
      wordnet = ctx.sources["wordnet"]
      record = record!(wordnet, "oewn-02124272-n")
      cat = lexeme!("cat")
      feline = lexeme!("feline")

      for {lexeme, group} <- [
            {cat, "oewn-02124272-n"},
            {feline, "oewn-02124272-n"},
            {cat, "oewn-02121620-n"}
          ] do
        sense!(lexeme, wordnet, record,
          external_key: "#{group}##{lexeme.lemma}",
          group_key: group
        )
      end

      # Two synsets, two distinct lexemes — `cat` is in both and counts once.
      assert %{synsets: 2, lexemes: 2} = Health.wordnet()
    end
  end

  describe "index/0 (A3)" do
    test "counts the index, the rows with forms and the enriched ones" do
      lexeme!("cat",
        forms: [%{"form" => "cats", "tags" => ["plural"]}],
        enriched_at: DateTime.utc_now()
      )

      lexeme!("cats")
      lexeme!("chien", lang: "fr")

      assert %{total: 2, with_forms: 1, enriched: 1} = Health.index()
    end
  end

  describe "scope/1 (A4)" do
    test "counts members per reason and insists every row has one", ctx do
      for {lemma, reasons} <- [
            {"cat", ["wordnet_closure", "wiktionary_category"]},
            {"aardvark", ["wordnet_closure"]},
            {"Felis catus", ["wikidata_taxon"]}
          ] do
        Repo.insert!(%ScopeMember{
          scope_id: ctx.animals.id,
          lexeme_id: lexeme!(lemma).object_id,
          reasons: reasons
        })
      end

      result = Health.scope("animals")

      assert result.total == 3
      assert result.without_reason == 0
      # Reasons union rather than exclude: `cat` is counted under both.
      assert result.by_reason == %{
               "wordnet_closure" => 2,
               "wiktionary_category" => 1,
               "wikidata_taxon" => 1
             }
    end
  end

  describe "bierce/0 (A8)" do
    setup ctx do
      bierce = ctx.sources["bierce"]
      record = record!(bierce, "CAT/n")

      # `cat` the index already had; `whangdepootenawah` Bierce invented, so his
      # is the origin source.
      known = lexeme!("cat", origin_source_id: ctx.sources["wiktionary"].id)
      invented = lexeme!("whangdepootenawah", origin_source_id: bierce.id)

      Repo.insert!(%ScopeMember{
        scope_id: ctx.animals.id,
        lexeme_id: known.object_id,
        reasons: ["wordnet_closure"]
      })

      # A definition is a content item and a `defines` claim, not a row with a
      # nullable `lexeme_id`.
      for {lexeme, position} <- [{known, 0}, {invented, 1}] do
        {:ok, content} =
          Registry.create_content(%{
            content_kind: :definition,
            source_id: bierce.id,
            source_record_revision_id: revision_id(record),
            headword: String.upcase(lexeme.lemma),
            body: "A definition.",
            position: position,
            year: 1911
          })

        {:ok, _} =
          Claims.assert(content.object_id, "defines", lexeme.object_id, %{source_id: bierce.id})
      end

      :ok
    end

    test "attachment is 100% by construction, so the index hit rate is the number" do
      result = Health.bierce("animals")

      assert result.entries == 2
      # `materialize/1` creates the lexeme when the index lacks it, so an entry
      # without one cannot exist. This row can only ever read 100%.
      assert result.attached == 2
      assert result.attached_pct == 100.0

      # What actually varies: how many of his headwords were words somebody else
      # had already attested.
      assert result.known_to_the_index == 1
      assert result.index_hit_pct == 50.0
      assert result.introduced_by_bierce == 1
    end

    test "counts the entries whose word is in the scope" do
      assert Health.bierce("animals").in_scope == 1
    end
  end

  describe "wordnet_edges/0 (R1)" do
    test "WordNet resolves its own edges at absorb, so this must be 100%", ctx do
      wordnet = ctx.sources["wordnet"]
      record = record!(wordnet, "oewn-02124272-n")
      cat = lexeme!("cat")

      feline = lexeme!("feline")

      # WordNet's graph is sense to sense: a synset's members each get a sense,
      # and the hypernym edge runs between the meanings, not between the words.
      # Gate 0 measured the three endpoint pairs the corpus actually holds —
      # sense→sense, lexeme→lexeme and sense→lexeme — and `lexeme → sense` is
      # not one of them, so the database refuses it.
      cat_sense =
        sense!(cat, wordnet, record,
          external_key: "oewn-02124272-n#cat",
          group_key: "oewn-02124272-n"
        )

      sense =
        sense!(feline, wordnet, record,
          external_key: "oewn-02121620-n#feline",
          group_key: "oewn-02121620-n"
        )

      {:ok, _} =
        Claims.assert(cat_sense.object_id, "hypernym", sense.object_id, %{source_id: wordnet.id})

      assert %{total: 1, resolved: 1, pending: 0, pct: 100.0} = Health.wordnet_edges()

      # An unresolved edge is not an assertion with a missing end: it waits in
      # `pending_relations` with its evidence, and that is the population R1
      # reports as unresolved.
      Repo.insert!(%DevilsDictionary.Claims.PendingRelation{
        source_id: wordnet.id,
        subject_object_id: cat_sense.object_id,
        predicate_id: Claims.predicate!("hyponym").id,
        to_lemma: "unfetched",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      assert %{total: 2, resolved: 1, pending: 1, pct: 50.0} = Health.wordnet_edges()
    end
  end

  describe "variants/0 (X3)" do
    test "reports which probe landed where, so a regression names itself" do
      lexeme!("monkey", forms: [%{"form" => "monkeys", "tags" => ["plural"]}])

      result = Health.variants()
      by_input = Map.new(result.probes, &{&1.input, &1})

      assert by_input["monkeys"].landed == "monkey"
      assert by_input["monkeys"].ok
      # Nothing seeded for `cats`, and the row says so rather than raising.
      assert by_input["cats"].landed == nil
      refute by_input["cats"].ok
      assert result.total == 4
    end
  end
end
