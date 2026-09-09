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

  alias DevilsDictionary.Absorb.Batch
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

    test "reconcile: false stamps without retiring, for a pass that writes a partial view",
         ctx do
      publish(ctx.source, [{"a", "Money; profit."}, {"b", "The edge of a river."}])
      Batch.run(FakeSource, ctx.source)

      publish(ctx.source, [{"a", "Money; profit."}])
      Batch.run(FakeSource, ctx.source, reconcile: false)

      assert state("b") == :active
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
