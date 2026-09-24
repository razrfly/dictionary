defmodule DevilsDictionary.Corpus.SeederQuotesTest do
  @moduledoc """
  The seeder's second kind of content (#174): the public-domain Wikiquote
  corpus, seeded from a manifest the real build produced over captured answers
  (`QuotesCorpusFixtures`). The artworks corpora keep their own suites,
  unchanged and still calling the seeder by its old name.
  """

  use DevilsDictionary.DataCase, async: false

  import Ecto.Query

  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionRevision, Predicate}
  alias DevilsDictionary.Corpus.Seeder
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.Quotations
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.QuotesCorpusFixtures
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.ContentItem
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Creators
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  @manifest QuotesCorpusFixtures.manifest()

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    :ok
  end

  defp credits(content_id) do
    Repo.all(
      from r in AssertionRevision,
        join: p in Predicate,
        on: p.id == r.predicate_id and p.key == "authored_by",
        join: a in Assertion,
        on: a.id == r.assertion_id,
        join: s in Source,
        on: s.id == a.source_id,
        where: r.subject_object_id == ^content_id and r.is_current,
        order_by: s.slug,
        select: %{source: s.slug, revision_id: r.id, person: r.object_object_id}
    )
  end

  test "the source row is the issue's: 👑, a dump, CC BY-SA 4.0" do
    source = Sources.get_source_by_slug!("wikiquote-pd-v1")

    assert %{tier: :aristocracy, access: :dump, kind: :corpus, license: "CC BY-SA 4.0"} = source
    assert source.config["dump_url"] =~ "dumps.wikimedia.org/enwikiquote/"
    assert source.config["retention"] =~ "never swept"
  end

  test "each line is a quotation, credited to its author by QID, with its evidence and badge" do
    assert @manifest["row_count"] > 0
    assert {:ok, summary} = Seeder.run(@manifest)
    assert summary.newly_created == @manifest["row_count"]
    assert summary.invalid == 0

    for row <- @manifest["rows"] do
      content_id = Registry.by_external_id("quotation_fingerprint", row["fingerprint"])
      item = Repo.get!(ContentItem, content_id)

      assert item.content_kind == :quotation
      assert item.metadata["provenance"]["badge"] == "verified"
      assert item.metadata["provenance"]["computed_by"] == "wikiquote-pd-v1"

      # Minted from the manifest's own Wikidata facts: no request was made.
      assert [%{source: "wikiquote-pd-v1", revision_id: revision_id, person: person}] =
               credits(content_id)

      assert Registry.by_external_id("wikidata", "Q9068") == person

      evidence =
        Repo.all(from e in AssertionEvidence, where: e.assertion_revision_id == ^revision_id)

      assert Enum.any?(evidence, &(&1.locator =~ "Candide (Gutenberg #19942), line"))
      assert Enum.all?(evidence, &(&1.evidence_role == :supports))
      assert Enum.all?(evidence, &is_integer(&1.source_record_revision_id))
    end
  end

  test "a second seed matches every line and writes nothing new" do
    {:ok, _} = Seeder.run(@manifest)
    evidence = Repo.aggregate(AssertionEvidence, :count)
    items = Repo.aggregate(ContentItem, :count)

    assert {:ok, again} = Seeder.run(@manifest)
    assert again.matched == @manifest["row_count"]
    assert again.newly_created == 0
    assert Repo.aggregate(AssertionEvidence, :count) == evidence
    assert Repo.aggregate(ContentItem, :count) == items
  end

  test "a corpus line and a live line with one wording are one subject" do
    row = hd(@manifest["rows"])
    # The live provider's copy of the same words, one character different in
    # transcription: a curly apostrophe and no final full stop.
    live_text = row["text"] |> String.replace("'", "’") |> String.trim_trailing(".")
    assert Fingerprint.fingerprint(live_text) == row["fingerprint"]

    item = %{
      external_namespace: "wikiquote_item",
      external_id: "livelineid",
      identifiers: [
        %{namespace: "wikiquote_item", external_id: "livelineid", metadata: %{}},
        Fingerprint.identifier(live_text)
      ],
      preview_metadata: %{
        "title" => live_text,
        "author_qid" => "Q9068",
        "certainty" => "candidate",
        "source_url" => "https://en.wikiquote.org/wiki/Voltaire"
      }
    }

    wikiquote = Sources.get_source_by_slug!("wikiquote")
    {:ok, record} = Sources.upsert_record(wikiquote, %{external_id: "livelineid", raw: %{}})
    {:ok, entry} = Wikiquote.identity_record(item)
    prepared = Quotations.Corpus.seed_context(@manifest).prepared

    live =
      entry
      |> Map.merge(%{
        source_id: wikiquote.id,
        source_record_id: record.id,
        source_record_revision_id: record.current_revision.id
      })
      |> SourceIdentity.resolve(prepared: prepared)

    assert live.state == :newly_created

    {:ok, _} = Seeder.run(@manifest)

    assert Registry.by_external_id("quotation_fingerprint", row["fingerprint"]) ==
             live.object_id

    assert [%{source: "wikiquote"}, %{source: "wikiquote-pd-v1"}] = credits(live.object_id)
  end

  test "a corpus record is never swept" do
    {:ok, _} = Seeder.run(@manifest)
    source = Sources.get_source_by_slug!("wikiquote-pd-v1")
    held = Repo.aggregate(from(r in SourceRecord, where: r.source_id == ^source.id), :count)
    assert held == @manifest["row_count"]

    DevilsDictionary.Discovery.cleanup()

    assert Repo.aggregate(from(r in SourceRecord, where: r.source_id == ^source.id), :count) ==
             held
  end

  test "a row whose fingerprint is not its text's is refused, and nothing is written" do
    [row | _] = @manifest["rows"]
    tampered = %{@manifest | "rows" => [Map.put(row, "text", row["text"] <> " And more.")]}

    assert {:ok, summary} = Seeder.run(tampered)
    assert summary.invalid == 1
    assert summary.invalid_reasons == %{"fingerprint_mismatch" => 1}
    assert Registry.by_external_id("quotation_fingerprint", row["fingerprint"]) == nil
  end

  test "the author is prepared from the manifest, never fetched" do
    prepared = Quotations.Corpus.seed_context(@manifest).prepared

    assert {:ok, %{kind: :person, label: "Voltaire", birth_year: 1694}} = prepared["Q9068"]

    assert prepared["Q9068"] ==
             Creators.classify("Q9068", %{"Q9068" => @manifest["selection"]["authors"]["Q9068"]})
  end
end
