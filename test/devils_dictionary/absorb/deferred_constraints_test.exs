defmodule DevilsDictionary.Absorb.DeferredConstraintsTest do
  @moduledoc """
  The family of defect the SQL sandbox cannot see.

  Three of the registry's rules are **deferred constraint triggers**, checked at
  `COMMIT` rather than at statement end — an object must have its subtype row, an
  assertion must have exactly one current revision. That is the right design: a
  writer needs two statements to satisfy either, and deferring them is what lets
  it use two.

  The consequence is that a writer running in **autocommit** satisfies neither,
  because each of its statements is its own transaction. And the consequence of
  *that* is that an ordinary test cannot see the problem: the sandbox wraps a
  whole test in one transaction, so both statements land inside it and the
  trigger fires at a commit that never comes.

  So these run unboxed, and each one failed before its fix.
  """

  use DevilsDictionary.DataCase, async: false

  @moduletag :unboxed

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Absorb.{Materializer, Resolver}
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.{Fixtures, Repo, Sources}

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = %{sources: sources}
    %{ctx: ctx, wordnet: sources["wordnet"]}
  end

  describe "Materializer.write_assertions/3 outside a transaction" do
    test "mints the assertion and its first revision together", %{ctx: ctx, wordnet: wordnet} do
      cat = word!(ctx, "cat", ~w(wordnet))
      animal = word!(ctx, "animal", ~w(wordnet))

      # `Absorb.Linker` calls this with no enclosing transaction of its own, and
      # the ladder is the only caller that does.
      assert 1 =
               Materializer.write_assertions([
                 %{
                   subject: cat.object_id,
                   predicate: "hypernym",
                   object: animal.object_id,
                   source_id: wordnet.id,
                   origin_key: "rung|cat|hypernym|animal",
                   method: "linker",
                   confidence: 0.9,
                   metadata: %{}
                 }
               ])

      assert [revision] =
               Repo.all(from r in AssertionRevision, where: r.subject_object_id == ^cat.object_id)

      assert revision.is_current
      assert revision.revision_number == 1
    end
  end

  describe "Resolver.run/1 on a backlog bigger than the wire" do
    @rows 6_000

    test "resolves every pending edge rather than overflowing the bind parameters", %{
      ctx: ctx,
      wordnet: wordnet
    } do
      target = word!(ctx, "thing", ~w(wordnet))
      record = record!(ctx, "wordnet", external_id: "oewn-1-n", raw: %{})

      subjects =
        for n <- 1..@rows do
          word!(ctx, "subject#{n}", ~w(wordnet)).object_id
        end

      predicate = Repo.one!(from p in "predicates", where: p.key == "hypernym", select: p.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # Chunked here too, for the same reason the resolver has to chunk: this
      # fixture is eleven columns wide.
      for chunk <- Enum.chunk_every(subjects, 2_000) do
        Repo.insert_all(
          "pending_relations",
          Enum.map(chunk, fn subject ->
            %{
              source_id: wordnet.id,
              source_record_id: record.id,
              subject_object_id: subject,
              predicate_id: predicate,
              to_lemma: "thing",
              to_pos: "noun",
              origin_key: "rel|#{subject}|hypernym|thing",
              method: "source",
              metadata: %{},
              inserted_at: now,
              updated_at: now
            }
          end)
        )
      end

      # Twelve columns on a revision: 6,000 rows in one statement is 72,000 bind
      # parameters, and Postgres accepts 65,535.
      assert %{resolved: @rows} = Resolver.run()

      assert Repo.aggregate(from(p in "pending_relations"), :count) == 0

      assert Repo.aggregate(
               from(r in AssertionRevision,
                 where: r.object_object_id == ^target.object_id and r.is_current
               ),
               :count
             ) == @rows
    end

    test "resolving the same edge twice updates the claim rather than duplicating it", %{
      ctx: ctx,
      wordnet: wordnet
    } do
      # Re-materializing a record re-creates the pending row for an edge that was
      # already resolved — the second Wiktionary sweep does it 21,398 times — and
      # the resolver used to insert a second assertion with the same origin key.
      word!(ctx, "thing", ~w(wordnet))
      subject = word!(ctx, "cat", ~w(wordnet))
      record = record!(ctx, "wordnet", external_id: "oewn-1-n", raw: %{})

      pending = fn ->
        Repo.insert_all("pending_relations", [pending_row(wordnet, record, subject.object_id)])
      end

      pending.()
      assert %{resolved: 1} = Resolver.run()

      pending.()
      assert %{resolved: 1} = Resolver.run()

      key = "rel|cat|hypernym|thing"

      assert Repo.aggregate(from(a in "assertions", where: a.origin_key == ^key), :count) == 1

      assert Repo.aggregate(
               from(r in AssertionRevision,
                 join: a in "assertions",
                 on: a.id == r.assertion_id,
                 where: a.origin_key == ^key and r.is_current
               ),
               :count
             ) == 1
    end
  end

  describe "an edge the resolver already closed, re-emitted" do
    test "keeps its claim active rather than being retired and left withdrawn", %{
      ctx: ctx,
      wordnet: wordnet
    } do
      # The shape the second Wiktionary sweep produces 21,398 times. A record is
      # re-materialized; the edge it carries is not resolvable in-batch, so it
      # goes back to `pending_relations` — and the assertion the resolver made for
      # it on an earlier run is owned by *that* run. Read naively, "not stamped by
      # this run" means "no longer published", and 110,331 claims were withdrawn
      # and then left withdrawn, because re-resolving them changed no wording and
      # so wrote no revision.
      word!(ctx, "thing", ~w(wordnet))
      subject = word!(ctx, "cat", ~w(wordnet))

      record =
        record!(ctx, "wordnet",
          external_id: "oewn-1-n",
          raw: %{"lemma" => "cat", "to_lemma" => "thing"}
        )

      # The key the adapter will produce for this edge next time round.
      key = "rel|fake-cat|hypernym|thing"

      Repo.insert_all("pending_relations", [
        pending_row(wordnet, record, subject.object_id, key)
      ])

      assert %{resolved: 1} = Resolver.run()

      claim = Repo.one!(from a in "assertions", where: a.origin_key == ^key, select: a.id)

      assert current_state(claim) == "active"

      # The record comes round again under a new run, emitting the same edge.
      run = Sources.start_run("absorb", source_id: wordnet.id)

      Materializer.run_batch([Sources.with_raw(record)], DevilsDictionary.FakeSource,
        run_id: run.id
      )

      Materializer.reconcile(run.id, [record.id])

      assert current_state(claim) == "active"
    end
  end

  describe "ownership of a claim the resolver writes" do
    test "carries the run that wrote it", %{ctx: ctx, wordnet: wordnet} do
      # Wiktionary, Johnson and Bierce name their targets by *lemma*, so every
      # claim those three make is written by the resolver rather than by the
      # materializer's second pass. Both callers opened a run and then did not
      # hand it over, and 117,363 claim outputs carried a null
      # `last_seen_run_id` — which `reconcile/2` reads as "the source stopped
      # publishing this", exactly the state it cannot distinguish from "never
      # seen".
      word!(ctx, "thing", ~w(wordnet))
      subject = word!(ctx, "cat", ~w(wordnet))
      record = record!(ctx, "wordnet", external_id: "oewn-1-n", raw: %{})

      Repo.insert_all("pending_relations", [pending_row(wordnet, record, subject.object_id)])

      run = Sources.start_run("resolve")
      assert %{resolved: 1} = Resolver.run(run_id: run.id)

      assert Repo.one!(
               from o in "source_assertion_outputs",
                 where: o.source_record_id == ^record.id,
                 select: o.last_seen_run_id
             ) == run.id
    end
  end

  defp current_state(assertion_id) do
    Repo.one!(
      from r in AssertionRevision,
        where: r.assertion_id == ^assertion_id and r.is_current,
        select: r.lifecycle_state
    )
    |> to_string()
  end

  defp pending_row(source, record, subject, origin_key \\ "rel|cat|hypernym|thing") do
    predicate = Repo.one!(from p in "predicates", where: p.key == "hypernym", select: p.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      source_id: source.id,
      source_record_id: record.id,
      subject_object_id: subject,
      predicate_id: predicate,
      to_lemma: "thing",
      to_pos: "noun",
      origin_key: origin_key,
      method: "source",
      metadata: %{},
      inserted_at: now,
      updated_at: now
    }
  end
end
