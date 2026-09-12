defmodule DevilsDictionary.Absorb.ConceptsTest do
  @moduledoc """
  The encyclopedia half of the `Materializer`: concept merging, the taxon
  bridge, and taxonomy edges whose target is in another batch.

  Uses the two real sources rather than a fake one, because the thing under
  test is exactly that Wikipedia and Wikidata describe one concept from
  different sides and neither may blank the other.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.{Wikidata, Wikipedia}
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{ExternalIdentifier, Lexeme, ObjectName}
  alias DevilsDictionary.{Claims, Encyclopedia, Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  setup do
    Claims.Catalog.seed!()
    :ok
  end

  # Deliberately *not* the real slugs. `Catalog.seed!/0` upserts `wikipedia` and
  # `wikidata` from other async tests, and two transactions touching those rows
  # in different orders deadlock. Neither module reads the slug — they work off
  # `record.source_id` — so a throwaway name is free.
  defp source!(slug, kind) do
    Repo.insert!(%Source{
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      name: slug,
      tier: :middle,
      kind: kind,
      access: :api
    })
  end

  defp record!(source, external_id, raw) do
    Sources.insert_records(source, [%{external_id: external_id, raw: raw}])

    Repo.one!(
      from r in SourceRecord,
        where: r.source_id == ^source.id and r.external_id == ^external_id
    )
    |> Sources.with_raw()
  end

  defp wikipedia_record!(lemma) do
    source = source!("wikipedia", :encyclopedia)
    raw = Wikipedia.trim(Fixtures.one_raw("wikipedia", lemma))
    {record!(source, lemma, raw), source}
  end

  defp wikidata_record!(lemma, qid) do
    source = source!("wikidata", :knowledge_graph)
    raw = Fixtures.raw("wikidata", lemma) |> Enum.find(&(&1["id"] == qid)) |> Wikidata.trim()
    {record!(source, qid, raw), source}
  end

  # The display shape, so a test reads `wikipedia_title` and `kind` the way a
  # page does rather than reaching into `metadata` by hand.
  defp concept(qid), do: qid |> Encyclopedia.by_qid!() |> Encyclopedia.view()

  defp taxon_edges do
    Repo.aggregate(
      from(r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: r.is_current and p.key == "parent_taxon"
      ),
      :count
    )
  end

  describe "two sources on one concept" do
    test "Wikipedia then Wikidata composes, and neither blanks the other" do
      {wp, _} = wikipedia_record!("cat")
      {wd, _} = wikidata_record!("cat", "Q146")

      assert {:ok, _} = Materializer.run(wp, Wikipedia)
      assert {:ok, _} = Materializer.run(wd, Wikidata)

      cat = Encyclopedia.by_qid!("Q146")
      assert cat.metadata["wikipedia_title"] == "Cat"
      assert cat.metadata["wikipedia_pageid"] == 6678
      assert cat.metadata["wordnet_ili"] == "i46593"
      # The article thumbnail has declared display precedence in either order;
      # Wikidata's observation remains in its immutable source record.
      assert cat.metadata["image_url"] =~ "Siam_lilacpoint.jpg"
      before = cat.metadata
      assert {:ok, _} = Materializer.run(wp, Wikipedia)
      assert {:ok, _} = Materializer.run(wd, Wikidata)
      assert Encyclopedia.by_qid!("Q146").metadata == before
    end

    test "and in the other order, which is the one that used to clobber" do
      {wd, _} = wikidata_record!("cat", "Q146")
      {wp, _} = wikipedia_record!("cat")

      assert {:ok, _} = Materializer.run(wd, Wikidata)
      assert {:ok, _} = Materializer.run(wp, Wikipedia)

      cat = Encyclopedia.by_qid!("Q146")
      assert cat.metadata["wikipedia_pageid"] == 6678
      assert cat.metadata["image_url"] =~ "Siam_lilacpoint.jpg"
      # Wikipedia knows nothing about the ILI and must not erase it.
      assert cat.metadata["wordnet_ili"] == "i46593"
    end

    test "all probes contribute metadata even when the preferred probe omits a field" do
      source = source!("wikipedia", :encyclopedia)
      raw = Wikipedia.trim(Fixtures.one_raw("wikipedia", "cat"))
      preferred = record!(source, "a", Map.delete(raw, "thumbnail"))
      alternate = record!(source, "z", raw)
      assert {:ok, _} = Materializer.run_batch([preferred, alternate], Wikipedia)
      before = Encyclopedia.by_qid!("Q146").metadata
      assert before["image_url"] =~ "Siam_lilacpoint.jpg"
      assert {:ok, _} = Materializer.run(alternate, Wikipedia)
      assert {:ok, _} = Materializer.run(preferred, Wikipedia)
      assert Encyclopedia.by_qid!("Q146").metadata == before
    end

    test "a taxon's kind survives a later Wikipedia write" do
      {wd, _} = wikidata_record!("cat", "Q20980826")
      assert {:ok, _} = Materializer.run(wd, Wikidata)
      assert concept("Q20980826").kind == :taxon

      # `concept` is the no-opinion entity kind, so a source that does not know
      # about taxa can never demote one. Written through the materializer, which
      # is the only writer whose merge rule this is.
      felis = Encyclopedia.by_qid!("Q20980826")

      Repo.insert_all(
        "entities",
        [
          %{
            object_id: felis.object_id,
            entity_kind: "concept",
            metadata: %{},
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        on_conflict:
          from(e in "entities",
            update: [
              set: [
                entity_kind:
                  fragment(
                    "CASE WHEN EXCLUDED.entity_kind = 'concept' THEN ? ELSE EXCLUDED.entity_kind END",
                    e.entity_kind
                  )
              ]
            ]
          ),
        conflict_target: [:object_id]
      )

      assert concept("Q20980826").kind == :taxon
    end

    test "a sharper kind preserves an existing identity and its attachments" do
      {:ok, local} =
        Registry.create_entity(%{
          entity_kind: :concept,
          preferred_label: "Local Warsaw",
          metadata: %{"curator_note" => "keep me"}
        })

      {:ok, _} = Registry.add_name(local.object_id, "Warszawa", name_kind: "alias")
      {:ok, _} = Registry.add_external_id(local.object_id, "wikidata", "Q270")

      raw =
        Fixtures.raw("wikidata", "general_entities")
        |> Enum.find(&(&1["id"] == "Q270"))
        |> Wikidata.trim()

      source = source!("wikidata-general", :knowledge_graph)
      record = record!(source, "Q270", raw)

      assert {:ok, _} = Materializer.run(record, Wikidata)

      place = Encyclopedia.by_qid!("Q270")
      assert place.object_id == local.object_id
      assert place.entity_kind == :place
      assert place.metadata["curator_note"] == "keep me"
      assert Repo.get_by!(ObjectName, object_id: local.object_id, name: "Warszawa")
    end

    test "a local entity remains valid without an external identifier" do
      {:ok, local} =
        Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Uncatalogued mask"})

      refute Repo.get_by(ExternalIdentifier, object_id: local.object_id)
      assert Repo.get!(DevilsDictionary.Registry.Entity, local.object_id).entity_kind == :artifact
    end
  end

  describe "concept-to-concept references across batches" do
    test "a parent named before it exists is picked up on the second pass" do
      {wd, source} = wikidata_record!("cat", "Q20980826")

      assert {:ok, %{concept_relations: 0, concept_relations_offered: offered}} =
               Materializer.run(wd, Wikidata)

      assert offered > 0
      assert taxon_edges() == 0

      # The parents arrive in a later tier; re-materializing then closes the
      # edges. This is why `Wikidata.absorb/2` runs `Batch.run` twice.
      parent = record!(source, "Q228283", %{"id" => "Q228283", "claims" => %{}})
      assert {:ok, _} = Materializer.run(parent, Wikidata)
      assert {:ok, %{concept_relations: written}} = Materializer.run(wd, Wikidata)

      assert written > 0
      assert taxon_edges() > 0
    end

    test "the taxon_item bridge links the everyday concept to its taxon" do
      {wd, source} = wikidata_record!("cat", "Q146")
      taxon = Fixtures.raw("wikidata", "cat") |> Enum.find(&(&1["id"] == "Q20980826"))
      taxon_record = record!(source, "Q20980826", Wikidata.trim(taxon))

      assert {:ok, _} = Materializer.run(taxon_record, Wikidata)
      assert {:ok, _} = Materializer.run(wd, Wikidata)

      assert Encyclopedia.taxon_item(concept("Q146").object_id) ==
               concept("Q20980826").object_id
    end
  end

  describe "Wikipedia's lexeme annotation" do
    test "the probed lexemes get the title and are not marked enriched" do
      {:ok, lexeme} =
        Registry.create_lexeme(%{language_tag: "en", lemma: "cat", part_of_speech: "noun"})

      {wp, _} = wikipedia_record!("cat")
      assert {:ok, _} = Materializer.run(wp, Wikipedia)

      lexeme = Repo.get!(Lexeme, lexeme.object_id)
      assert lexeme.metadata["wikipedia_title"] == "Cat"

      # Wikipedia's entry hangs off the concept, not the word, so it must not
      # make a bare index row look enriched (the S1 bug, in a new place).
      assert is_nil(lexeme.enriched_at)
    end
  end
end
