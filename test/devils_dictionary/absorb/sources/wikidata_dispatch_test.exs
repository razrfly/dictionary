defmodule DevilsDictionary.Absorb.Sources.WikidataDispatchTest do
  @moduledoc """
  What a record of the `wikidata` source is, told apart explicitly (#194,
  Stage 2 recovery):

    * a quotation-verifier lookup cache (`Sources.CacheRecord`) is pinned
      evidence, never an entity — reported as `verifier_cache`, and nothing is
      written for it;
    * an absent marker materializes to nothing;
    * an entity payload carries its `id`, a redirect's included;
    * anything else is refused, not skipped.

  And an item with no name in any language the source reads keeps the
  established entity exactly as it was, reported as `label_missing` rather
  than stopping the run or erasing the name another source gave it — or the
  output with which the creator-identity flow recorded minting it.
  """
  use DevilsDictionary.DataCase, async: true

  import Ecto.Query

  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.{Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.SourceIdentity.Creators
  alias DevilsDictionary.Sources.{CacheRecord, SourceRecord}

  defp record(raw, external_id),
    do: Fixtures.source_record(raw, source_id: 3, id: 99, external_id: external_id)

  defp statement(qid) do
    %{
      "rank" => "normal",
      "type" => "statement",
      "mainsnak" => %{"datavalue" => %{"value" => %{"id" => qid}, "type" => "wikibase-entityid"}}
    }
  end

  describe "materialize/1 dispatch" do
    test "a verifier cache record is reported, never projected" do
      for key <- [
            CacheRecord.key("wikidata", "enwikiquote-sitelink", "Q191050"),
            CacheRecord.key("wikidata", "gutenberg-works", "Q191050")
          ] do
        raw = %{"qid" => "Q191050", "title" => "Ambrose Bierce"}

        assert Wikidata.materialize(record(raw, key)) ==
                 {:ok, %{dispositions: [%{kind: :verifier_cache, key: key}]}}
      end
    end

    test "only registered namespaces are caches" do
      assert CacheRecord.cache?("wikidata", "enwikiquote-sitelink:Q1")
      refute CacheRecord.cache?("wikidata", "Q1")
      refute CacheRecord.cache?("wikidata", "someone-else:Q1")
      refute CacheRecord.cache?("wikipedia", "enwikiquote-sitelink:Q1")

      assert_raise ArgumentError, fn -> CacheRecord.key("wikidata", "someone-else", "Q1") end
    end

    test "an id-less payload that is not a registered cache is refused, not skipped" do
      raw = %{"qid" => "Q191050", "title" => "Ambrose Bierce"}

      assert Wikidata.materialize(record(raw, "someone-else:Q191050")) ==
               {:error, {:not_an_entity_payload, "someone-else:Q191050"}}

      assert Wikidata.materialize(record(%{"labels" => %{}}, "Q191050")) ==
               {:error, {:not_an_entity_payload, "Q191050"}}
    end

    test "an absent marker materializes to nothing" do
      assert Wikidata.materialize(record(%{}, "Q99999")) == {:ok, %{}}
    end

    test "a redirected item is projected under the id it now carries" do
      raw = %{"id" => "Q27179", "labels" => %{"en" => %{"value" => "Parrot"}}, "claims" => %{}}

      assert {:ok, %{concepts: [concept], dispositions: []}} =
               Wikidata.materialize(record(raw, "Q116910164"))

      assert concept.qid == "Q27179"
    end

    test "a nameless item is reported as label_missing and makes no eligible identity entry" do
      raw = %{"id" => "Q17386297", "labels" => %{}, "claims" => %{"P31" => [statement("Q5")]}}

      assert {:ok,
              %{concepts: [concept], dispositions: [%{kind: :label_missing, key: "Q17386297"}]}} =
               Wikidata.materialize(record(raw, "Q17386297"))

      assert concept.kind == :person
      assert is_nil(concept.label)

      assert {:ok, entry} = Wikidata.identity_record(concept)
      assert entry.eligibility == :insufficient_evidence
      assert entry.eligibility_reason == "label_missing"
    end
  end

  describe "a batch over a source holding caches and a nameless entity" do
    setup do
      ctx = Fixtures.seed_catalog!()
      source = Sources.get_source_by_slug!("wikidata")

      # An established person, named by another source, whose Wikidata item
      # carries no label at all.
      {:ok, person} = Registry.create_person(%{preferred_label: "Shani (singer)"})

      {:ok, _} = Registry.add_external_id(person.object_id, "wikidata", "Q17386297")

      Sources.insert_records(source, [
        %{
          external_id: "Q17386297",
          raw: %{"id" => "Q17386297", "labels" => %{}, "claims" => %{"P31" => [statement("Q5")]}}
        },
        %{
          external_id: CacheRecord.key("wikidata", "enwikiquote-sitelink", "Q191050"),
          raw: %{"qid" => "Q191050", "title" => "Ambrose Bierce"}
        },
        %{
          external_id: CacheRecord.key("wikidata", "gutenberg-works", "Q191050"),
          raw: %{"qid" => "Q191050", "works" => []}
        }
      ])

      # The creator-identity flow minted the person from this record and
      # recorded it as the record's output, unstamped, before any
      # materializer had seen the record.
      nameless = Repo.get_by!(SourceRecord, source_id: source.id, external_id: "Q17386297")
      now = DateTime.utc_now()
      %{role: role} = Creators.minted_output()

      Repo.insert_all("source_materialized_outputs", [
        %{
          source_record_id: nameless.id,
          output_role: role,
          output_key: "Q17386297",
          output_object_id: person.object_id,
          inserted_at: now,
          updated_at: now
        }
      ])

      Map.merge(ctx, %{wikidata: source, person: person, nameless: nameless})
    end

    test "completes, counts every disposition, and changes no identity", ctx do
      entities = Repo.aggregate(Entity, :count)
      before = Repo.get!(Entity, ctx.person.object_id)

      counts = Batch.run(Wikidata, ctx.wikidata, only_stale: false)

      assert counts.dispositions == %{"verifier_cache" => 2, "label_missing" => 1}
      assert Repo.aggregate(Entity, :count) == entities

      after_run = Repo.get!(Entity, ctx.person.object_id)
      assert after_run.preferred_label == "Shani (singer)"
      assert after_run.entity_kind == before.entity_kind

      assert Repo.aggregate(from(c in "reconciliation_cases"), :count) == 0

      # The mint's evidence is not the materializer's to retire.
      assert_mint_output_live(ctx)
    end

    test "a replay records what it materialized and what it did not project", ctx do
      dir = Path.join(System.tmp_dir!(), "dispatch-replay-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Dd.Export.Replay.run(["--source", "wikidata", "--out", dir, "--quiet"])
      end)

      # As a restored copy's records would be before their first projection.
      Repo.update_all(
        from(r in SourceRecord, where: r.source_id == ^ctx.wikidata.id),
        set: [materialized_at: nil]
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Dd.Replay.run(["--dir", dir, "--source", "wikidata"])
        end)

      assert output =~ ~r/materialized\s+3 record\(s\) in 1 pass\(es\)/
      assert output =~ "not projected"

      assert %{
               "records" => 3,
               "materialized" => %{
                 "records" => 3,
                 "passes" => 1,
                 "dispositions" => %{"verifier_cache" => 2, "label_missing" => 1}
               }
             } =
               Repo.one!(
                 from r in "import_runs",
                   where: r.task == "replay" and r.source_id == ^ctx.wikidata.id,
                   select: r.stats
               )

      assert_mint_output_live(ctx)
    end
  end

  # The mint's evidence is not the materializer's to retire.
  defp assert_mint_output_live(ctx) do
    assert [[nil]] =
             Repo.all(
               from o in "source_materialized_outputs",
                 where: o.source_record_id == ^ctx.nameless.id,
                 select: [o.retired_at]
             )
  end
end
