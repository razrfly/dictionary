defmodule DevilsDictionary.Curation.CandidatesTest do
  @moduledoc """
  What a page's curated opening may be made of (#257 §6, tests 1–5): the
  page's entries under the lead rule, its current senses' quotations,
  exactly its Saved catalog shelf, its accepted exemplars, all for the
  page's own words and nothing else.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures, only: [account: 1]
  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Artworks, ExemplarFixtures, Fixtures, Lexicon, Registry}
  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Curation.{Candidates, Digest}
  alias DevilsDictionary.Lexicon.WordPage

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)

    Map.merge(ctx, %{
      verb: verb,
      contributor: account([:contributor]),
      reviewer: account([:reviewer])
    })
  end

  defp page(slug), do: slug |> Lexicon.lookup() |> WordPage.build()

  defp of_kind(candidates, kind), do: Enum.filter(candidates.highlights, &(&1.kind == kind))

  # A word with two dictionaries' entries and no Bierce entry.
  defp greed!(ctx) do
    greed = word!(ctx, "greed", ~w(wiktionary johnson), scope: nil)

    wiktionary =
      entry!(ctx, greed, "wiktionary", body: "A selfish desire for more than is needed.")

    johnson =
      entry!(ctx, greed, "johnson", headword: "GREEDINESS", pos: "n. s.", body: "Ravenousness.")

    %{greed: greed, wiktionary: wiktionary, johnson_greed: johnson}
  end

  describe "test 1: the lead" do
    test "a page with a Bierce entry lists it first as the only admissible lead", ctx do
      candidates = Candidates.for_page(page("love"))

      assert candidates.bierce?
      assert [first | others] = candidates.leads
      assert first.spec.object_id == ctx.bierce.object_id
      assert first.lead == {:ok, :priority_source}
      assert first.spec.meaning == {:lexeme, ctx.love.object_id}

      assert others != []
      assert Enum.all?(others, &(&1.lead == {:error, :priority_source_available}))
      assert Enum.any?(others, &(&1.spec.object_id == ctx.johnson.object_id))
      assert candidates.no_lead == {:error, :priority_source_missing}
    end

    test "a Bierce entry that may not be shown neither leads nor blocks another lead", ctx do
      DevilsDictionary.CurationFixtures.disallow_record!(ctx.bierce)
      candidates = Candidates.for_page(page("love"))

      refute candidates.bierce?
      bierce = Enum.find(candidates.leads, &(&1.spec.object_id == ctx.bierce.object_id))
      johnson = Enum.find(candidates.leads, &(&1.spec.object_id == ctx.johnson.object_id))

      assert bierce.lead == {:error, :display_restricted}
      assert johnson.lead == {:ok, :manual_fallback}
      assert candidates.no_lead == :ok
    end

    test "without one, every definition is admissible and no lead is allowed", ctx do
      %{wiktionary: wiktionary, johnson_greed: johnson} = greed!(ctx)
      candidates = Candidates.for_page(page("greed"))

      refute candidates.bierce?

      assert candidates.leads |> Enum.map(& &1.spec.object_id) |> Enum.sort() ==
               Enum.sort([wiktionary.object_id, johnson.object_id])

      assert Enum.all?(candidates.leads, &(&1.lead == {:ok, :manual_fallback}))
      assert candidates.no_lead == :ok
    end
  end

  describe "test 2: sense quotations" do
    test "come only from the scope's current senses, pinned by locator and words", ctx do
      # A quotation on another word's sense is not this page's.
      oats = word!(ctx, "oats", ~w(wiktionary), scope: nil)

      sense!(ctx, oats, "wiktionary",
        examples: [%{"type" => "quotation", "text" => "Oats for horses.", "ref" => "Johnson"}]
      )

      # A sense of this page whose quotation the sense row would not show
      # (no citation) offers nothing.
      sense!(ctx, ctx.verb, "wiktionary",
        examples: [%{"type" => "quotation", "text" => "Uncited words."}]
      )

      quotations = of_kind(Candidates.for_page(page("love")), :sense_quotation)

      assert quotations |> Enum.map(& &1.text) |> Enum.sort() ==
               Enum.sort([
                 "He on his side / Leaning half-raised, with looks of cordial love / Hung over her enamoured.",
                 "Heav'n has no Rage, like Love to Hatred turn'd, / Nor Hell a Fury, like a Woman ſcorn'd."
               ])

      for q <- quotations do
        revision = Registry.current_sense_revision(q.spec.object_id)
        assert q.spec.sense_revision_id == revision.id
        assert revision.is_current
        assert q.spec.meaning == {:sense_revision, revision.id}
        "quotation:" <> index = q.spec.locator
        %{"text" => text} = Enum.at(revision.examples, String.to_integer(index))
        assert q.spec.words_sha256 == Digest.sha256(text)
        assert q.status == :ok
      end

      milton = Enum.find(quotations, &String.starts_with?(&1.text, "He on his side"))
      assert milton.spec.object_id == ctx.profound.object_id
      assert milton.spec.locator == "quotation:1"

      # A newer revision of the sense without the quotation: the superseded
      # revision's line is not offered.
      current = Registry.current_sense_revision(ctx.profound.object_id)

      {:ok, _newer} =
        Registry.add_sense_revision(ctx.profound.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples: Enum.take(current.examples, 1),
          url: current.url,
          source_record_revision_id: current.source_record_revision_id
        })

      texts =
        Candidates.for_page(page("love")) |> of_kind(:sense_quotation) |> Enum.map(& &1.text)

      refute Enum.any?(texts, &String.starts_with?(&1, "He on his side"))
      assert Enum.any?(texts, &String.starts_with?(&1, "Heav'n has no Rage"))
    end
  end

  describe "test 3: catalog works" do
    test "are exactly the Saved catalog shelf's rows, each with manifest, checksum and identity",
         ctx do
      ids = Enum.map(page("love").headword.lexemes, & &1.id)
      shelf = Artworks.shelf_items(ids)
      works = of_kind(Candidates.for_page(page("love")), :work)

      assert shelf != []
      assert Enum.map(works, & &1.spec.object_id) == Enum.map(shelf, & &1.object_id)

      assert [work] = works

      assert work.spec.catalog == %{
               manifest: "wikidata-famous-v1",
               checksum: Manifest.checksum_of("wikidata-famous-v1"),
               identity: "Q8777422"
             }

      assert work.work_kind == "artwork"
      assert work.status == :ok
      assert {:sense_revision, _} = work.spec.meaning
      assert ctx.love.object_id in ids
    end
  end

  describe "test 4: exemplars" do
    test "are only accepted illustrates claims whose meaning is on the scope", ctx do
      accepted = ExemplarFixtures.person!("Accepted Person")
      pending = ExemplarFixtures.person!("Pending Person")
      elsewhere = ExemplarFixtures.person!("Elsewhere Person")

      claim = ExemplarFixtures.nominate!(ctx.contributor, accepted, ctx.benevolent)
      ExemplarFixtures.decide!(ctx.reviewer, claim)
      ExemplarFixtures.nominate!(ctx.contributor, pending, ctx.benevolent)

      # An accepted claim under another word's sense is not this page's.
      oats = word!(ctx, "oats", ~w(wiktionary), scope: nil)
      oats_sense = sense!(ctx, oats, "wiktionary", gloss: "a grain")
      other = ExemplarFixtures.nominate!(ctx.contributor, elsewhere, oats_sense)
      ExemplarFixtures.decide!(ctx.reviewer, other)

      candidates = Candidates.for_page(page("love"))
      assert [exemplar] = of_kind(candidates, :exemplar)

      assert exemplar.spec == %{
               kind: :exemplar,
               assertion_revision_id: claim.id,
               meaning:
                 {:sense_revision, Registry.current_sense_revision(ctx.benevolent.object_id).id}
             }

      assert exemplar.title == "Accepted Person"
      assert exemplar.status == :ok
      assert candidates.nominations == 1
    end
  end

  describe "test 5: the scope" do
    test "is the page's headword lexeme ids, in order, and nothing from the address", ctx do
      page = page("love")
      candidates = Candidates.for_page(page)

      assert candidates.scope.ids == Enum.map(page.headword.lexemes, & &1.id)

      assert Enum.sort(candidates.scope.ids) ==
               Enum.sort([ctx.love.object_id, ctx.verb.object_id])

      assert candidates.scope.language == "en"

      # What the page was reached by changes nothing: only its words count.
      readdressed =
        put_in(page.headword, %{page.headword | lemma: "LOVE", slug: "other", matched: "x"})

      assert Candidates.for_page(readdressed).scope == candidates.scope

      # The exact word's page is its own words, and only them.
      lexeme = Lexicon.by_object_id(ctx.verb.object_id)
      exact = WordPage.build(%{lexemes: [lexeme], via: :lemma, matched: lexeme.lemma})
      assert Candidates.for_page(exact).scope.ids == [ctx.verb.object_id]
    end
  end
end
