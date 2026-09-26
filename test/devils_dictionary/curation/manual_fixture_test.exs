defmodule DevilsDictionary.Curation.ManualFixtureTest do
  @moduledoc """
  The Phase 1 opening reader (#156): the committed fixture resolves to durable
  registry objects at their exact revisions, withholds what is no longer
  eligible without substituting anything, keeps Bierce first, and reads the
  database only.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures
  import Ecto.Query

  alias DevilsDictionary.{Fixtures, Lexicon, Registry, Repo}
  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Curation.{LeadPolicy, ManualFixture, Opening}
  alias DevilsDictionary.Curation.Opening.{Highlight, Lead, Reference}
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Sources.SourceRecord

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    Map.merge(ctx, love!(ctx))
  end

  defp page(word), do: word |> Lexicon.lookup() |> WordPage.build()

  # The committed `love` composition, edited — so a test changes one thing
  # about a real selection rather than writing a second one.
  defp love_with(fun) do
    file = ManualFixture.read()

    compositions =
      Enum.map(file["compositions"], fn
        %{"key" => "love"} = love -> fun.(love)
        other -> other
      end)

    %{"compositions" => compositions}
  end

  # A content item's source identity, the way the fixture names one.
  defp source_ref(content_id) do
    Repo.one(
      from cr in "content_revisions",
        join: srr in "source_record_revisions",
        on: srr.id == cr.source_record_revision_id,
        join: rec in "source_records",
        on: rec.id == srr.source_record_id,
        join: s in "sources",
        on: s.id == rec.source_id,
        where: cr.content_id == ^content_id and cr.is_current,
        select: %{
          "source" => s.slug,
          "record" => rec.external_id,
          "revision_key" => srr.revision_key
        }
    )
  end

  describe "the committed love composition" do
    test "Bierce leads, quoted from his entry's exact current revision", ctx do
      assert %Opening{origin: :fixture, composition: %{id: "fixture:love", version: 1}} =
               opening = ManualFixture.opening(page("love"))

      assert opening.withheld == []

      assert %Lead{policy: :priority_source, reference: %Reference{} = ref} = opening.lead
      assert ref.object_kind == :content
      assert ref.object_id == ctx.bierce.object_id
      assert ref.content_revision_id == Registry.current_content_revision(ctx.bierce.object_id).id
      assert ref.locator == %{kind: :sentences, count: 1}

      assert opening.lead.excerpt.text ==
               "A temporary insanity curable by marriage or by removal of the patient from the influences under which he incurred the disorder."

      assert opening.lead.excerpt.clipped?
      assert String.starts_with?(bierce_love(), opening.lead.excerpt.text)
      assert opening.lead.links.card_id == "card-bierce"
      assert opening.lead.meaning.kind == :lexeme
      assert opening.lead.meaning.object_id == ctx.love.object_id

      # The source's own credit line, not one composed here.
      assert Enum.any?(
               opening.lead.credits,
               &(&1.label == "Source" and &1.text =~ "public domain")
             )
    end

    test "three highlights of two kinds, each for a meaning and at an exact revision", ctx do
      opening = ManualFixture.opening(page("love"))

      assert [
               %Highlight{position: 1, kind: :artwork} = artwork,
               %Highlight{position: 2, kind: :quotation} = milton,
               %Highlight{position: 3, kind: :quotation} = congreve
             ] = opening.highlights

      assert artwork.reference.object_id == ctx.artwork_id

      assert artwork.reference.catalog == %{
               manifest: "wikidata-famous-v1",
               checksum: Manifest.checksum_of("wikidata-famous-v1")
             }

      assert artwork.meaning.object_id == ctx.benevolent.object_id
      assert Enum.any?(artwork.credits, &(&1.label == "Image" and &1.text =~ "Wikimedia Commons"))

      # The registry's reason, worded as the catalog shelf words it: a QID the
      # meaning refers to is among the work's committed depictions.
      assert Enum.any?(artwork.reasons, &(&1.kind == :source_match and &1.text =~ "Q316"))

      assert milton.quotation.text =~ "cordial love"
      assert milton.quotation.citation == "1674, John Milton, Paradise Lost"
      assert milton.reference.object_id == ctx.profound.object_id

      assert milton.reference.sense_revision_id ==
               Registry.current_sense_revision(ctx.profound.object_id).id

      assert milton.reference.locator.kind == :quotation
      assert milton.meaning.object_id == ctx.profound.object_id
      assert milton.meaning.anchor =~ "#card-wiktionary"

      # Verbatim, long s and all.
      assert congreve.quotation.text =~ "Woman ſcorn'd."
      assert congreve.meaning.label == glosses().intense
    end

    test "every editorial note says who wrote it and that nobody has reviewed it" do
      opening = ManualFixture.opening(page("love"))

      notes =
        Enum.flat_map(opening.highlights, & &1.reasons) |> Enum.filter(&(&1.kind == :editorial))

      assert length(notes) == 3

      for note <- notes do
        assert note.author.kind == :model
        assert note.author.label =~ "Claude Code"
        assert is_nil(note.reviewed_by)
      end

      assert opening.review.state == :unreviewed
      assert opening.review.selected_by.kind == :model
      assert is_nil(opening.review.panel)
      assert opening.review.support == [] and opening.review.dissent == []
    end

    test "reads the database only: no discovery run, no job, no row written" do
      counts = fn ->
        for table <- ~w(discovery_runs discovery_results oban_jobs assertions content_revisions),
            into: %{},
            do: {table, Repo.one(from t in table, select: count())}
      end

      before = counts.()
      assert %Opening{} = ManualFixture.opening(page("love"))
      assert counts.() == before
    end
  end

  describe "read-time eligibility" do
    test "a superseded revision is withheld and nothing is put in its place", ctx do
      {:ok, _new} =
        Registry.add_content_revision(ctx.bierce.object_id, %{
          body: "A temporary insanity, revised.",
          body_format: :markdown
        })

      opening = ManualFixture.opening(page("love"))

      assert is_nil(opening.lead)
      assert opening.withheld == [%{role: :lead, position: nil, reason: :revision_not_current}]
      assert length(opening.highlights) == 3
    end

    test "a source record that may no longer be displayed takes its item off the page", ctx do
      Repo.update_all(
        from(r in SourceRecord,
          where: r.source_id == ^ctx.sources["bierce"].id and r.external_id == "LOVE/n"
        ),
        set: [display_allowed: false]
      )

      opening = ManualFixture.opening(page("love"))

      assert is_nil(opening.lead)
      assert [%{role: :lead, reason: :display_not_allowed}] = opening.withheld
    end

    test "a catalog that has changed since the selection withholds the work" do
      fixtures =
        love_with(fn love ->
          update_in(love, ["highlights", Access.at(0), "item", "work", "checksum"], fn _ ->
            String.duplicate("0", 64)
          end)
        end)

      opening = ManualFixture.opening(page("love"), fixtures: fixtures)

      assert Enum.map(opening.highlights, & &1.position) == [2, 3]
      assert opening.withheld == [%{role: :highlight, position: 1, reason: :catalog_changed}]
    end

    test "a line no longer filed under its sense is withheld" do
      fixtures =
        love_with(fn love ->
          put_in(
            love,
            ["highlights", Access.at(1), "item", "quotation", "fingerprint"],
            String.duplicate("f", 64)
          )
        end)

      opening = ManualFixture.opening(page("love"), fixtures: fixtures)

      assert [%{role: :highlight, position: 2, reason: :quotation_not_found}] = opening.withheld
    end

    test "never more than three highlights, never the same one twice" do
      fixtures =
        love_with(fn love ->
          [first | _] = highlights = love["highlights"]
          Map.put(love, "highlights", [first, first] ++ tl(highlights))
        end)

      opening = ManualFixture.opening(page("love"), fixtures: fixtures)

      assert Enum.map(opening.highlights, & &1.position) == [1, 3]
      assert length(opening.highlights) <= Opening.max_highlights()

      assert opening.withheld == [
               %{role: :highlight, position: 2, reason: :duplicate},
               %{role: :highlight, position: 4, reason: :over_limit}
             ]
    end
  end

  describe "Bierce first" do
    test "a selection that names another lead while Bierce applies is refused", ctx do
      fixtures =
        love_with(fn love ->
          put_in(love, ["lead", "item", "content"], source_ref(ctx.johnson.object_id))
        end)

      opening = ManualFixture.opening(page("love"), fixtures: fixtures)

      assert is_nil(opening.lead)
      assert [%{role: :lead, reason: :priority_source_available}] = opening.withheld
    end

    test "a selection with no lead on a Bierce page says so rather than going quiet" do
      fixtures = love_with(&Map.put(&1, "lead", nil))
      opening = ManualFixture.opening(page("love"), fixtures: fixtures)

      assert is_nil(opening.lead)
      assert [%{role: :lead, reason: :priority_source_missing}] = opening.withheld
    end

    test "without Bierce, the committed oats selection leads with Johnson as a manual fallback",
         ctx do
      oats = word!(ctx, "oats", ~w(johnson wiktionary), scope: nil)

      record =
        record!(ctx, "johnson",
          external_id: "OATS/n. s./0",
          content_hash: "e7ddcd8e1248913f23a69e5df491a0f3c69d397f86ea97d71de6a5e3aa29957d"
        )

      entry!(ctx, oats, "johnson",
        record: record,
        headword: "OATS",
        pos: "n. s.",
        body:
          "A grain, which in England is generally given to horses, but in Scotland supports the people.\n\n> The oats have eaten the horses. Shakespeare."
      )

      page = page("oats")
      opening = ManualFixture.opening(page)

      assert %Lead{policy: :manual_fallback} = opening.lead

      # "Read the whole entry · N characters" is the Definitions row's own N.
      {_card, entry} = LeadPolicy.page_entry(page, opening.lead.reference.object_id)
      assert opening.lead.excerpt.chars == entry.chars
      assert opening.lead.excerpt.text =~ "in Scotland supports the people."
      assert opening.highlights == []
      assert Enum.any?(opening.lead.reasons, &(&1.kind == :policy and &1.text =~ "no entry"))
      assert Enum.any?(opening.lead.credits, &(&1.text =~ "CC BY 4.0"))
    end
  end

  describe "scope" do
    test "an explicitly empty composition is an opening with nothing, which the page does not draw",
         ctx do
      word!(ctx, "topographagnosia", ~w(wiktionary), scope: nil)

      assert %Opening{lead: nil, highlights: [], withheld: []} =
               ManualFixture.opening(page("topographagnosia"))

      assert is_nil(Opening.for_page(page("topographagnosia"), ManualFixture))
    end

    test "a word no composition names has no opening", ctx do
      word!(ctx, "rizz", ~w(wiktionary), scope: nil)

      assert is_nil(ManualFixture.opening(page("rizz")))
    end

    test "scope is the lexeme's identity, not the slug: the verb's own page is out of scope",
         ctx do
      verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)
      page = WordPage.build(%{lexemes: [verb], via: :lemma, matched: "love"})

      assert is_nil(ManualFixture.opening(page))
      assert %Opening{} = ManualFixture.opening(page("love"))
    end
  end

  describe "the committed file" do
    test "names durable identities and exact revisions, never a discovery result" do
      file = ManualFixture.read()

      body =
        File.read!(
          Path.join(:code.priv_dir(:devils_dictionary), "curation/opening-fixtures.json")
        )

      refute body =~ ~r/result_id|discovery_result|mapping_id/

      for composition <- file["compositions"] do
        assert is_binary(composition["key"]) and is_integer(composition["version"])

        for key <- composition["scope"]["lexemes"],
            do: assert(key =~ ~r"\A[a-z]{2,3}/[^/]+/[a-z]+\z")

        assert length(composition["highlights"]) <= Opening.max_highlights()
        assert composition["selected_by"]["kind"] in ~w(human model)

        if lead = composition["lead"] do
          assert %{"source" => _, "record" => _, "revision_key" => key} = lead["item"]["content"]
          assert byte_size(key) == 64
        end

        for highlight <- composition["highlights"] do
          assert Map.has_key?(highlight, "meaning")

          case highlight["item"] do
            %{"work" => work} -> assert work["checksum"] == Manifest.checksum_of(work["catalog"])
            %{"quotation" => q} -> assert byte_size(q["fingerprint"]) == 64
          end
        end
      end
    end
  end
end
