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
  alias DevilsDictionary.{Fixtures, Repo}

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
  end
end
