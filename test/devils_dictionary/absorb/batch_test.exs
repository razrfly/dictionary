defmodule DevilsDictionary.Absorb.BatchTest do
  @moduledoc """
  **D1, in the import path rather than beside it.**

  `Materializer.reconcile/2` was written for the audit's finding #1 — refresh
  was purely additive, so a meaning a source withdrew stayed for ever — and
  `durability_test.exs` proves the function. That is not the same as proving the
  import calls it: the first full re-import wrote 240,056 outputs with a null
  `last_seen_run_id`, because nothing on the path had ever opened a run. An
  unstamped output is worse than an unreconciled one — it is a reconciliation
  that cannot tell "no longer published" from "never seen".

  So these tests drive `Batch.run/3`, which is what every source's `absorb/2`
  actually calls, and assert on the stamping and the retirement it performs.
  """

  use DevilsDictionary.DataCase, async: false

  # Unboxed, because this file tests the **import path** and half of what the
  # import path can get wrong is a constraint deferred to COMMIT — which the
  # sandbox's enclosing transaction swallows. Two records naming one article
  # minted two objects and wrote one content row, and inside the sandbox that
  # passed.
  @moduletag :unboxed

  import Ecto.Query

  alias DevilsDictionary.Absorb.{Batch, Resolver}
  alias DevilsDictionary.Registry.Sense
  alias DevilsDictionary.{Claims, FakeSource, Repo, Sources}
  alias DevilsDictionary.Sources.{ImportRun, Source}

  setup do
    Claims.Catalog.seed!()
    %{source: source!()}
  end

  describe "run/3" do
    test "stamps every output it writes with the run it wrote them under", ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])

      counts = Batch.run(FakeSource, ctx.source)

      assert counts.senses == 2
      assert unstamped_outputs() == 0

      # One run, opened by `Batch.run` because no caller owned one, and finished
      # with what it wrote.
      assert [run] = Repo.all(from r in ImportRun, where: r.task == "materialize")
      assert run.finished_at
      assert stamped_with(run.id) == outputs()
    end

    test "honours a run id its caller already owns", ctx do
      run = Sources.start_run("absorb", source_id: ctx.source.id)
      publish(ctx.source, [{"a", "Money; profit."}])

      Batch.run(FakeSource, ctx.source, run_id: run.id)

      assert stamped_with(run.id) == outputs()
      assert Repo.all(from r in ImportRun, where: r.task == "materialize") == []
    end

    test "retires what the source stopped publishing, and nothing else", ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])
      Batch.run(FakeSource, ctx.source)

      # The next release drops one meaning. Nothing in the test touches
      # `reconcile/2`: the import path is what has to notice.
      publish(ctx.source, [{"a", "Money; profit."}])
      Batch.run(FakeSource, ctx.source)

      assert state("a") == :active
      assert state("b") == :retired

      # Retired, never deleted — the identity still resolves.
      assert Repo.get_by!(Sense, external_key: "b")
    end

    test "a second identical run retires nothing, which is what idempotence means", ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])
      Batch.run(FakeSource, ctx.source)

      Batch.run(FakeSource, ctx.source, only_stale: false)

      assert state("a") == :active
      assert state("b") == :active
    end

    test "writes one content item for the records that name it, and lets each of them own it",
         ctx do
      # Two records, one canonical article — `ON CONFLICT DO UPDATE command
      # cannot affect row a second time` if the batch tries to write it twice,
      # and a Wikipedia replay of 85,044 records hits it in the first batch.
      article(ctx.source, "eastern-grey-squirrel", "Sciurus carolinensis")
      article(ctx.source, "grey-squirrel", "Sciurus carolinensis")

      Batch.run(FakeSource, ctx.source)

      assert Repo.aggregate(from(c in "content_items"), :count) == 1

      assert Repo.aggregate(
               from(o in "source_materialized_outputs", where: o.output_role == "content"),
               :count
             ) == 2
    end

    test "an object two records attest survives one of them going quiet", ctx do
      article(ctx.source, "eastern-grey-squirrel", "Sciurus carolinensis")
      article(ctx.source, "grey-squirrel", "Sciurus carolinensis")
      Batch.run(FakeSource, ctx.source)

      # One probe stops redirecting there. The article is still attested by the
      # other, so withdrawing it would be the source losing an article it still
      # publishes.
      Sources.insert_records(ctx.source, [
        %{external_id: "grey-squirrel/noun", raw: %{"lemma" => "grey-squirrel"}}
      ])

      Batch.run(FakeSource, ctx.source)

      assert Repo.one!(
               from r in "content_revisions", where: r.is_current, select: r.lifecycle_state
             ) ==
               "active"
    end

    test "two records that assert the same edge both own the one claim it becomes", ctx do
      # Wiktionary keys a record by etymology, so `bear/noun/2`, `/3` and `/4` all
      # say *bear* is a kind of *mammal*. That is one claim and three attestations
      # — and if the pending row is keyed by the edge alone, two of the three
      # records never reach the resolver and the claim ends up with one owner.
      Sources.insert_records(ctx.source, [
        %{external_id: "bear/noun/2", raw: %{"lemma" => "bear", "to_lemma" => "mammal"}},
        %{external_id: "bear/noun/3", raw: %{"lemma" => "bear", "to_lemma" => "mammal"}}
      ])

      Sources.insert_records(ctx.source, [
        %{external_id: "mammal/noun", raw: %{"lemma" => "mammal"}}
      ])

      Batch.run(FakeSource, ctx.source)
      Resolver.run()

      key = ~s(rel|fake-bear|hypernym|mammal)

      assert Repo.aggregate(from(a in "assertions", where: a.origin_key == ^key), :count) == 1

      assert Repo.aggregate(
               from(o in "source_assertion_outputs", where: o.output_key == ^key),
               :count
             ) == 2
    end

    test "one article stays one content item when its records fall in different batches", ctx do
      # The canonical publication identity has to hold across the **source**, not
      # across the batch in hand. Scoped to the batch, the second record to name
      # `article:Q2703156` minted a second *San Jose scale*, both owned the same
      # `about` claim, and every re-materialize rewrote its subject to whichever
      # ran last — eight identical revisions of one assertion.
      article(ctx.source, "aspidiotus-perniciosus", "Q2703156")
      Batch.run(FakeSource, ctx.source, batch_size: 1)

      article(ctx.source, "san-jose-scale", "Q2703156")
      Batch.run(FakeSource, ctx.source, batch_size: 1)

      assert Repo.aggregate(from(c in "content_items"), :count) == 1
    end

    test "conflicting probes do not alternate a publication's text on replay", ctx do
      for {key, body} <- [
            {"a-probe", "first observed wording"},
            {"z-probe", "other observed wording"}
          ] do
        Sources.insert_records(ctx.source, [
          %{
            external_id: key,
            raw: %{"lemma" => "shared", "content_key" => "article:shared", "body" => body}
          }
        ])
      end

      Batch.run(FakeSource, ctx.source, batch_size: 1)

      before =
        Repo.all(
          from r in "content_revisions", select: {r.id, r.body, r.is_current}, order_by: r.id
        )

      Batch.run(FakeSource, ctx.source, batch_size: 1, only_stale: false)

      assert before ==
               Repo.all(
                 from r in "content_revisions",
                   select: {r.id, r.body, r.is_current},
                   order_by: r.id
               )

      assert Enum.any?(before, fn {_, body, current} ->
               current and body == "first observed wording"
             end)
    end

    test "withdrawing the selected probe selects surviving text in a stale-only run", ctx do
      Sources.insert_records(ctx.source, [
        %{
          external_id: "a",
          raw: %{"lemma" => "shared", "content_key" => "shared", "body" => "selected"}
        },
        %{
          external_id: "z",
          raw: %{"lemma" => "shared", "content_key" => "shared", "body" => "surviving"}
        }
      ])

      Batch.run(FakeSource, ctx.source, batch_size: 1)
      Sources.insert_records(ctx.source, [%{external_id: "a", raw: %{"lemma" => "shared"}}])
      Batch.run(FakeSource, ctx.source, batch_size: 1)

      assert Repo.one!(from r in "content_revisions", where: r.is_current, select: r.body) ==
               "surviving"
    end

    test "every lexical observation contributes forms and pronunciations within one batch", ctx do
      for key <- ["a", "b"] do
        Sources.insert_records(ctx.source, [
          %{
            external_id: key,
            raw: %{
              "lemma" => "shared",
              "senses" => [],
              "forms" => [%{"form" => "form-#{key}"}],
              "pronunciations" => [%{"ipa" => key}]
            }
          }
        ])
      end

      Batch.run(FakeSource, ctx.source, batch_size: 20)
      assert Repo.aggregate(from(f in "lexeme_forms"), :count) == 2

      assert Repo.one!(from(l in "lexemes", select: l.pronunciations)) == %{
               "items" => [%{"ipa" => "a"}, %{"ipa" => "b"}]
             }

      before = DevilsDictionary.Health.StateFingerprint.capture(["lexemes", "lexeme_forms"])
      Batch.run(FakeSource, ctx.source, batch_size: 1, only_stale: false)

      assert before ==
               DevilsDictionary.Health.StateFingerprint.capture(["lexemes", "lexeme_forms"])
    end

    test "etymology selects a stable observation across batches and accepts its corrections",
         ctx do
      for {key, etymology} <- [{"a-probe", "alternate"}, {"Z-probe", "selected"}] do
        Sources.insert_records(ctx.source, [
          %{
            external_id: key,
            raw: %{"lemma" => "shared", "senses" => [], "etymology" => etymology}
          }
        ])

        Batch.run(FakeSource, ctx.source, batch_size: 1)
      end

      assert Repo.one!(from l in "lexemes", select: l.etymology) == "selected"
      before = DevilsDictionary.Health.StateFingerprint.capture(["lexemes"])
      Batch.run(FakeSource, ctx.source, batch_size: 20, only_stale: false)
      assert before == DevilsDictionary.Health.StateFingerprint.capture(["lexemes"])

      Sources.insert_records(ctx.source, [
        %{
          external_id: "Z-probe",
          raw: %{"lemma" => "shared", "senses" => [], "etymology" => "corrected"}
        }
      ])

      Batch.run(FakeSource, ctx.source, batch_size: 1)
      assert Repo.one!(from l in "lexemes", select: l.etymology) == "corrected"
    end

    test "unchanged source snapshots do not manufacture ambiguity between identical glosses",
         ctx do
      Sources.insert_records(ctx.source, [
        %{
          external_id: "same",
          raw: %{
            "lemma" => "same",
            "senses" => [
              %{"key" => "a", "gloss" => "same gloss"},
              %{"key" => "b", "gloss" => "same gloss"}
            ]
          }
        }
      ])

      Batch.run(FakeSource, ctx.source)
      before = DevilsDictionary.Health.StateFingerprint.capture(["senses", "sense_revisions"])
      Batch.run(FakeSource, ctx.source, only_stale: false)

      assert before ==
               DevilsDictionary.Health.StateFingerprint.capture(["senses", "sense_revisions"])
    end

    test "a changed sense cannot claim an unchanged neighbour's identity", ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])
      Batch.run(FakeSource, ctx.source)

      publish(ctx.source, [{"a", "Money; profit."}, {"b", "Money; profit."}])

      # The full Wiktionary corpus produced this shape inside one batch. Before
      # the claimed-identity guard both rows were upserted with the same
      # object_id, so PostgreSQL aborted the entire transaction with 21000.
      Batch.run(FakeSource, ctx.source)

      current =
        Repo.all(
          from s in "senses",
            where: s.external_key in ["a", "b"] and s.identity_state != "retired",
            order_by: s.external_key,
            select: {s.external_key, s.object_id, s.identity_state}
        )

      assert [{"a", first_id, "active"}, {"b", second_id, "needs_review"}] = current
      refute first_id == second_id
    end

    test "an ambiguous row does not reuse an identity another changed row claimed", ctx do
      publish(ctx.source, [
        {"Hryhorivka/name/0#0", "target gloss"},
        {"Hryhorivka/name/0#5", "other gloss"}
      ])

      Batch.run(FakeSource, ctx.source)

      publish(ctx.source, [
        {"Hryhorivka/name/0#0", "new gloss"},
        {"Hryhorivka/name/0#5", "target gloss"}
      ])

      # This is the exact key/order shape found by the first full restart: #5
      # claimed #0 on content, then ambiguous #0 tried to reuse that same id.
      Batch.run(FakeSource, ctx.source)

      current_ids =
        Repo.all(
          from s in "senses",
            where: s.identity_state != "retired",
            select: s.object_id
        )

      assert length(current_ids) == 2
      assert Enum.uniq(current_ids) == current_ids
    end

    test "a source returning to an earlier payload cites that observation, not the largest revision ID",
         ctx do
      for body <- ["original", "changed", "original"] do
        Sources.insert_records(ctx.source, [
          %{
            external_id: "versioned",
            raw: %{
              "lemma" => "versioned",
              "senses" => [],
              "content_key" => "versioned",
              "body" => body
            }
          }
        ])

        Batch.run(FakeSource, ctx.source)
      end

      %{rows: [[selected, current]]} =
        Repo.query!("""
        SELECT rr.revision_key,sr.content_hash FROM content_revisions cr
        JOIN source_record_revisions rr ON rr.id=cr.source_record_revision_id
        JOIN source_records sr ON sr.id=rr.source_record_id WHERE cr.is_current
        """)

      assert selected == current
    end

    test "an ambiguous sense keeps the identity it was given, run after run", ctx do
      # Ambiguity means no *existing* meaning is claimed. It does not mean a
      # fresh identity every import: that grew the table by one row per
      # ambiguous sense per run, and M2 caught it as 16 new senses on a
      # byte-identical re-import.
      Sources.insert_records(ctx.source, [
        %{
          external_id: "bank/noun",
          raw: %{
            "lemma" => "bank",
            "senses" => [
              %{"key" => "a", "gloss" => "the edge of a river"},
              %{"key" => "b", "gloss" => "the edge of the river"}
            ]
          }
        }
      ])

      Batch.run(FakeSource, ctx.source)
      first = Repo.aggregate(from(s in "senses"), :count)

      Batch.run(FakeSource, ctx.source, only_stale: false)

      assert Repo.aggregate(from(s in "senses"), :count) == first
    end

    test "reconcile: false stamps without retiring, for a pass that writes a partial view",
         ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])
      Batch.run(FakeSource, ctx.source)

      publish(ctx.source, [{"a", "Money; profit."}])
      Batch.run(FakeSource, ctx.source, reconcile: false)

      assert state("b") == :active
    end

    test "a withdrawn pending edge cannot be resurrected by a later resolver run", ctx do
      # The target deliberately does not exist on the first pass, so the edge
      # waits. A later observation of the same record removes the edge before
      # the target arrives. Reconciliation must remove that pending output too;
      # otherwise Resolver turns history into a current assertion.
      Sources.insert_records(ctx.source, [
        %{
          external_id: "bank/noun",
          raw: %{"lemma" => "bank", "to_lemma" => "vanished-target"}
        }
      ])

      Batch.run(FakeSource, ctx.source)
      assert Repo.aggregate(from(p in "pending_relations"), :count) == 1

      Sources.insert_records(ctx.source, [
        %{
          external_id: "bank/noun",
          raw: %{"lemma" => "bank", "relations" => false}
        }
      ])

      Batch.run(FakeSource, ctx.source)
      assert Repo.aggregate(from(p in "pending_relations"), :count) == 0

      Sources.insert_records(ctx.source, [
        %{external_id: "target/noun", raw: %{"lemma" => "vanished-target", "relations" => false}}
      ])

      Batch.run(FakeSource, ctx.source)
      assert %{resolved: 0} = Resolver.run()

      refute Repo.exists?(
               from(a in "assertions",
                 where: a.origin_key == "rel|fake-bank|hypernym|vanished-target"
               )
             )
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp source!(slug \\ "fake") do
    Repo.insert!(%Source{
      slug: slug,
      name: "Fake #{slug}",
      tier: :middle,
      kind: :dictionary,
      access: :dump
    })
  end

  # One record, republished with a different list of meanings. `insert_records`
  # writes a new revision when the checksum differs and bumps `fetched_at`, so
  # the default `only_stale: true` brings it back round.
  defp publish(source, senses) do
    Sources.insert_records(source, [
      %{
        external_id: "bank/noun",
        raw: %{
          "lemma" => "bank",
          "senses" => Enum.map(senses, fn {key, gloss} -> %{"key" => key, "gloss" => gloss} end)
        }
      }
    ])
  end

  defp article(source, lemma, key) do
    Sources.insert_records(source, [
      %{
        external_id: "#{lemma}/noun",
        raw: %{"lemma" => lemma, "content_key" => key, "body" => "an article about #{key}"}
      }
    ])
  end

  defp state(external_key), do: Repo.get_by!(Sense, external_key: external_key).identity_state

  defp outputs, do: Repo.aggregate(from(o in "source_materialized_outputs"), :count)

  defp unstamped_outputs do
    Repo.aggregate(
      from(o in "source_materialized_outputs", where: is_nil(o.last_seen_run_id)),
      :count
    )
  end

  defp stamped_with(run_id) do
    Repo.aggregate(
      from(o in "source_materialized_outputs", where: o.last_seen_run_id == ^run_id),
      :count
    )
  end
end
