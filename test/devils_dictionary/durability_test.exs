defmodule DevilsDictionary.DurabilityTest do
  @moduledoc """
  **D1–D4**, #74's milestone 4: evidence that ordinary source evolution does not
  corrupt meaning or relationships.

  Current data is disposable. These attachments are not: they are made in the
  new schema, through the real application paths, and then the source is made to
  change underneath them. That is the whole of what #74 asks — "re-import and
  later source changes cannot silently change what an existing attachment
  means" — and every one of these is a defect the 7 September audit reproduced
  on MVP-0.

  D5 (integrity on bulk writes) lives in `schema_test.exs`, where the rejections
  are; D6 (inputs are pinned) in `sources/manifest_test.exs`.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Absorb.{Linker, Materializer}
  alias DevilsDictionary.Claims.{AssertionRevision, PendingRelation}
  alias DevilsDictionary.Registry.{Sense, SenseRevision}
  alias DevilsDictionary.{Claims, Encyclopedia, Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  # ── D1 · refresh reconciles ───────────────────────────────────────────────

  describe "D1 — a source that stops publishing something" do
    test "retires its own output and leaves another source's support alone", ctx do
      cat = word!(ctx, "cat", ~w(wiktionary wordnet))

      # Two sources say something about the same word. Wiktionary will withdraw
      # one of its two meanings; WordNet must not notice.
      wiktionary = ctx.sources["wiktionary"]
      wordnet = ctx.sources["wordnet"]

      record = record!(ctx, "wiktionary", external_id: "cat/noun/0", raw: %{})
      kept = owned_sense!(ctx, cat, wiktionary, record, "cat/noun/0#0", "A small feline.")
      dropped = owned_sense!(ctx, cat, wiktionary, record, "cat/noun/0#1", "A tracked vehicle.")

      wordnet_record = record!(ctx, "wordnet", external_id: "oewn-1-n", raw: %{})
      other = owned_sense!(ctx, cat, wordnet, wordnet_record, "oewn-1-n#cat", "A feline.")

      # A curator attaches something to the sense that is about to be withdrawn.
      artifact = concept!(nil, "an illustrative meme", kind: :artifact)
      {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", dropped.object_id)

      # The next run emits only the first meaning.
      run = start_run(wiktionary)
      restamp(record, kept, run)
      Materializer.reconcile(run.id, [record.id])

      # Withdrawn, not deleted: the identity still resolves and the curator's
      # claim still points at the meaning it was made about.
      assert Repo.get!(Sense, dropped.object_id).identity_state == :retired
      assert current_sense_revision(dropped).lifecycle_state == :withdrawn
      assert Claims.current_revision(claim.id).object_object_id == dropped.object_id

      # The one still published is untouched, and so is the other source's.
      assert Repo.get!(Sense, kept.object_id).identity_state == :active
      assert Repo.get!(Sense, other.object_id).identity_state == :active
      assert current_sense_revision(other).lifecycle_state == :active
    end

    test "and a run that visits 200 records does not retire the other 340,000", ctx do
      cat = word!(ctx, "cat", ~w(wiktionary))
      wiktionary = ctx.sources["wiktionary"]

      visited = record!(ctx, "wiktionary", external_id: "cat/noun/0", raw: %{})
      elsewhere = record!(ctx, "wiktionary", external_id: "dog/noun/0", raw: %{})

      owned_sense!(ctx, cat, wiktionary, visited, "cat#0", "A feline.")
      untouched = owned_sense!(ctx, cat, wiktionary, elsewhere, "dog#0", "A canine.")

      # A scoped run that emitted nothing for the record it visited.
      run = start_run(wiktionary)
      Materializer.reconcile(run.id, [visited.id])

      assert Repo.get!(Sense, untouched.object_id).identity_state == :active
    end
  end

  # ── D2 · meaning identity is durable ──────────────────────────────────────

  describe "D2 — the source reorders its senses" do
    setup ctx do
      bank = word!(ctx, "bank", ~w(wiktionary))
      %{bank: bank, wiktionary: ctx.sources["wiktionary"]}
    end

    test "a meaning that moves position keeps its identity and its attachments",
         %{bank: bank, wiktionary: wiktionary} = ctx do
      # The audit's reproduction, in the application rather than in spike SQL.
      first =
        materialize_senses(ctx, bank, wiktionary, [
          {"bank/noun/1#0", "A branch office of such an institution."},
          {"bank/noun/1#1", "Money; profit."}
        ])

      money = Map.fetch!(first, "bank/noun/1#1")

      artifact = concept!(nil, "a curator's note", kind: :artifact)
      {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", money.object_id)

      # The branch-office sense is deleted; everything after it shifts down, so
      # "Money; profit." now arrives under the key the deleted one had.
      second =
        materialize_senses(ctx, bank, wiktionary, [
          {"bank/noun/1#0", "Money; profit."}
        ])

      # Same identity, because identity is the content and not the position.
      assert Map.fetch!(second, "bank/noun/1#0").object_id == money.object_id

      # And the attachment made before the edit still means what it meant.
      assert Claims.current_revision(claim.id).object_object_id == money.object_id
      assert current_sense_revision(money).gloss == "Money; profit."
    end

    test "a genuinely new meaning gets a new identity, and disturbs nothing",
         %{bank: bank, wiktionary: wiktionary} = ctx do
      first =
        materialize_senses(ctx, bank, wiktionary, [{"bank/noun/1#0", "Money; profit."}])

      second =
        materialize_senses(ctx, bank, wiktionary, [
          {"bank/noun/1#0", "Money; profit."},
          {"bank/noun/1#1", "A place where blood is stored for transfusion."}
        ])

      assert Map.fetch!(second, "bank/noun/1#0").object_id ==
               Map.fetch!(first, "bank/noun/1#0").object_id

      refute Map.fetch!(second, "bank/noun/1#1").object_id ==
               Map.fetch!(first, "bank/noun/1#0").object_id
    end

    test "identical input writes no new revision at all",
         %{bank: bank, wiktionary: wiktionary} = ctx do
      senses = [{"bank/noun/1#0", "Money; profit."}, {"bank/noun/1#1", "A river bank."}]

      materialize_senses(ctx, bank, wiktionary, senses)
      before = Repo.aggregate(SenseRevision, :count)

      materialize_senses(ctx, bank, wiktionary, senses)

      # M2's core property: a re-import of byte-identical input is a no-op, not
      # a second history.
      assert Repo.aggregate(SenseRevision, :count) == before
    end

    test "two meanings too close to tell apart open a case rather than a guess",
         %{bank: bank, wiktionary: wiktionary} = ctx do
      materialize_senses(ctx, bank, wiktionary, [
        {"bank/noun/1#0", "An edge of a river."},
        {"bank/noun/1#1", "An edge of a river."}
      ])

      # One incoming sense, two indistinguishable candidates: picking the higher
      # would have been decided by the row id.
      materialize_senses(ctx, bank, wiktionary, [{"bank/noun/1#0", "An edge of a river."}])

      cases = Repo.all(from c in "reconciliation_cases", select: c.kind)
      assert "sense_identity" in cases
    end
  end

  # ── D3 · editorial decisions survive ──────────────────────────────────────

  describe "D3 — a curator rejects a link" do
    test "a rerun of the rung that made it does not put it back", ctx do
      cat = word!(ctx, "cat", ~w(wordnet), metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", "cat", wikipedia_title: "Cat")

      assert %{rungs: %{title_match: 1}} = Linker.run(ctx.animals)

      [link] = links_of(cat)
      Claims.review(link.id, :rejected, reason: "the article is about the taxon")

      # The audit's finding: MVP-0 wrote `status` as a column and every rung's
      # `ON CONFLICT DO UPDATE` overwrote it, so this returned to `auto`.
      Linker.run(ctx.animals)

      assert Claims.review_state(current_link(cat).id) == :rejected
    end

    test "and a rejected link is invisible from both endpoints", ctx do
      cat = word!(ctx, "cat", ~w(wordnet))
      entity = concept!("Q146", "cat")
      link = link!(cat, entity, confidence: 0.95)

      revision = Claims.current_revision(link.id)
      subject = revision.subject_object_id

      assert Claims.outgoing(subject) != []
      assert Claims.incoming(entity.object_id) != []

      Claims.review(revision.id, :rejected)

      # Both directions, and the counts too — #74 asks for the filter to be
      # applied before counts and pagination, not only to the first page.
      assert Claims.outgoing(subject) == []
      assert Claims.incoming(entity.object_id) == []
      assert Claims.count_outgoing(subject) == 0
      assert Claims.count_incoming(entity.object_id) == 0

      # A review queue still sees it, which is the point of the split.
      assert Claims.incoming(entity.object_id, visibility: :internal) != []
    end
  end

  # ── D4 · review context is pinned ─────────────────────────────────────────

  describe "D4 — the endpoint's text changes after a review" do
    test "the review still records what was displayed, and the vote does not transfer",
         ctx do
      cat = word!(ctx, "cat", ~w(wiktionary))
      sense = sense!(ctx, cat, "wiktionary", gloss: "A small feline.")
      artifact = concept!(nil, "an illustrative meme", kind: :artifact)

      {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", sense.object_id)
      revision = Claims.current_revision(claim.id)

      # The reviewer pins what they are looking at.
      shown = Registry.current_sense_revision(sense.object_id)

      {:ok, context} =
        Claims.open_review_context(revision.id, [{:object, [sense_revision_id: shown.id]}])

      Claims.review(revision.id, :accepted, review_context_id: context.id)
      {:ok, actor} = actor()
      Claims.vote(revision.id, actor.id, 1, review_context_id: context.id)

      assert Claims.score(revision.id) == 1

      # The source rewords the meaning, and then the claim itself is revised.
      {:ok, _} = Registry.add_sense_revision(sense.object_id, %{gloss: "A tracked vehicle."})
      {:ok, second} = Claims.revise(claim.id, %{rationale: "the meaning moved"})

      # The old review's manifest still names the revision that was displayed —
      # not the current one — so "what did the reviewer see" survives the edit.
      pinned =
        Repo.one!(
          from i in "review_context_items",
            where: i.context_id == ^context.id,
            select: i.sense_revision_id
        )

      assert pinned == shown.id
      refute pinned == Registry.current_sense_revision(sense.object_id).id

      # And the vote does not carry onto a revision that says something else.
      assert Claims.score(second.id) == 0
      assert Claims.review_state(second.id) == :needs_review
      assert Claims.review_state(revision.id) == :accepted
    end

    test "a review context cannot cite a revision of some other object", ctx do
      cat = word!(ctx, "cat", ~w(wiktionary))
      dog = word!(ctx, "dog", ~w(wiktionary))
      sense = sense!(ctx, cat, "wiktionary", gloss: "A small feline.")
      unrelated = sense!(ctx, dog, "wiktionary", gloss: "A canine.")
      artifact = concept!(nil, "a meme", kind: :artifact)

      {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", sense.object_id)
      revision = Claims.current_revision(claim.id)
      other = Registry.current_sense_revision(unrelated.object_id)

      # The migration's `one_target` check proves a row cites exactly one
      # revision; it does not prove that revision has anything to do with the
      # claim. This does, and it is a trigger so it holds for raw SQL too.
      {:ok, context} = Claims.open_review_context(revision.id, [])

      assert_raise Postgrex.Error, ~r/endpoint/, fn ->
        Repo.query!(
          """
          INSERT INTO review_context_items (context_id, endpoint_role, sense_revision_id)
          VALUES ($1, 'object', $2)
          """,
          [context.id, other.id]
        )
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp current_sense_revision(sense), do: Registry.current_sense_revision(sense.object_id)

  # An `import` actor: exactly one typed principal per kind, and an import has
  # neither a user nor a bot behind it. An accountable submission, without
  # inventing a person.
  defp actor do
    Repo.insert(%DevilsDictionary.Sources.Actor{actor_kind: :import, label: "a test run"})
  end

  # A sense the importer owns, so `reconcile/2` can see it as this record's
  # output — which is the whole mechanism D1 is about.
  defp owned_sense!(ctx, lexeme, source, record, key, gloss) do
    sense = sense!(ctx, lexeme, source.slug, record: record, external_id: key, gloss: gloss)

    Repo.insert_all(
      "source_materialized_outputs",
      [
        %{
          source_record_id: record.id,
          output_role: "sense",
          output_key: key,
          output_object_id: sense.object_id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:output_object_id, :updated_at]},
      conflict_target: [:source_record_id, :output_role, :output_key]
    )

    sense
  end

  defp start_run(source), do: Sources.start_run("absorb", source_id: source.id)

  # Re-stamp one output as still emitted by this run; everything else the record
  # owns is what `reconcile/2` retires.
  defp restamp(record, sense, run) do
    Repo.update_all(
      from(o in "source_materialized_outputs",
        where: o.source_record_id == ^record.id and o.output_object_id == ^sense.object_id
      ),
      set: [last_seen_run_id: run.id]
    )
  end

  # One record, one materialize, through the real path — the senses a source
  # publishes right now, keyed the way Wiktionary keys them.
  defp materialize_senses(ctx, lexeme, source, senses) do
    raw = %{
      "lexeme" => lexeme.lemma,
      "pos" => lexeme.part_of_speech,
      "senses" => Enum.map(senses, fn {key, gloss} -> %{"key" => key, "gloss" => gloss} end)
    }

    Sources.insert_records(source, [%{external_id: "#{lexeme.lemma}/noun/1", raw: raw}])

    record =
      Repo.one!(
        from r in SourceRecord,
          where: r.source_id == ^source.id and r.external_id == ^"#{lexeme.lemma}/noun/1"
      )
      |> Sources.with_raw()

    {:ok, _} = Materializer.run(record, __MODULE__.SenseSource)

    _ = ctx

    Repo.all(
      from s in Sense,
        where: s.source_id == ^source.id and s.lexeme_id == ^lexeme.object_id,
        select: {s.external_key, s}
    )
    |> Map.new()
  end

  defp links_of(lexeme) do
    Repo.all(
      from r in AssertionRevision,
        where: r.subject_object_id == ^lexeme.object_id and r.is_current
    )
  end

  defp current_link(lexeme), do: lexeme |> links_of() |> hd()

  defmodule SenseSource do
    @moduledoc """
    A source whose whole job is to publish exactly the senses a test names.

    Pure, like every other adapter, so the reordering D2 asks about is done by
    changing the record's payload rather than by reaching into the database —
    which is the difference between testing the model and testing a fixture.
    """
    @behaviour DevilsDictionary.Absorb.Source

    @impl true
    def slug, do: "wiktionary"

    @impl true
    def rate_limit_ms, do: 0

    @impl true
    def trim(raw), do: raw

    @impl true
    def materialize(%{raw: raw, source_id: source_id}) do
      key = {"en", raw["lexeme"], raw["pos"] || "noun"}

      {:ok,
       %{
         lexemes: [%{key: key, origin_source_id: source_id}],
         senses:
           raw["senses"]
           |> Enum.with_index()
           |> Enum.map(fn {sense, position} ->
             %{
               key: sense["key"],
               lexeme: key,
               source_id: source_id,
               gloss: sense["gloss"],
               position: position
             }
           end)
       }}
    end
  end
end
