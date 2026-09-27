defmodule DevilsDictionary.Routing.BackfillTest do
  @moduledoc """
  The Stage 2 backfill (#194) on committed data, as a real run would see it:

    * without reviews it writes decisions, draft pages and dispositions, and
      no address; with them, only what a named reviewer approved;
    * a second run over the same inputs writes nothing: every page, path and
      decision id is the same set;
    * a new review file carries every identity over;
    * a run interrupted mid-batch and resumed ends where an uninterrupted run
      ends, object by object;
    * an entity whose evaluator input or pinned evidence moved since the
      export is deferred with its reason, never classified from stale
      evidence;
    * inputs that do not belong together, an unknown reviewer, and an
      account without the reviewer role are refused before anything is
      written;
    * the checkpoint is append-only.

  The export is produced by the statements of
  `docs/audits/2026-09-26-issue194/policy-export.sql` themselves, run
  against this database.
  """
  use DevilsDictionary.DataCase, async: false

  import Ecto.Query

  alias DevilsDictionary.{AccountsFixtures, Fixtures, Registry, Sources}

  alias DevilsDictionary.Routing.{
    AuditSnapshot,
    Backfill,
    BackfillItem,
    BackfillRun,
    ClassificationDecision,
    Classifications,
    Page,
    Policy,
    PublicPath,
    RouteChange
  }

  alias DevilsDictionary.Sources.Actor

  @moduletag :unboxed
  @moduletag :capture_log

  @export Path.expand("../../../docs/audits/2026-09-26-issue194/policy-export.sql", __DIR__)

  # One policy anchor per family, from the policy's approved examples.
  @anchors %{"people" => "Q5", "places" => "Q6256", "works" => "Q482994"}

  setup do
    Fixtures.seed_catalog!()
    dir = Path.join(System.tmp_dir!(), "backfill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    world = %{
      # An uncontested allocation candidate.
      bierce: person!("Ambrose Bierce", "Q9200001"),
      # A two-member collision group, each proposed a readable qualifier.
      daman_af: place!("Daman", "Q9200002", "human settlement in Afghanistan"),
      daman_in: place!("Daman", "Q9200003", "town in India"),
      # A classification review: no type the policy maps.
      polish: entity!(:concept, "Polish", "Q9200004", "Q1"),
      # Deferred in the population.
      cat: entity!(:concept, "cat", "Q9200005", "Q1")
    }

    snapshot = export!(dir)
    population = population!(dir, snapshot, world)
    reviewer = reviewer!()
    importer = Repo.insert!(%Actor{actor_kind: :import, label: "backfill test"})

    %{
      dir: dir,
      world: world,
      snapshot: snapshot,
      population: population,
      reviewer: reviewer,
      importer: importer
    }
  end

  # ── the world ────────────────────────────────────────────────────────────

  defp person!(label, qid) do
    {:ok, entity} = Registry.create_person(%{preferred_label: label})
    evidence!(entity, qid, @anchors["people"])
  end

  defp place!(label, qid, description) do
    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: :place,
        preferred_label: label,
        description: description
      })

    evidence!(entity, qid, @anchors["places"])
  end

  defp entity!(kind, label, qid, type) do
    {:ok, entity} = Registry.create_entity(%{entity_kind: kind, preferred_label: label})
    evidence!(entity, qid, type)
  end

  # A verified Wikidata identifier, and the item's stored record with its type.
  defp evidence!(entity, qid, type) do
    {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", qid)
    record!(qid, type)
    entity
  end

  defp record!(qid, type) do
    Sources.insert_records(Sources.get_source_by_slug!("wikidata"), [
      %{
        external_id: qid,
        raw: %{
          "id" => qid,
          "claims" => %{
            "P31" => [
              %{
                "rank" => "normal",
                "mainsnak" => %{"datavalue" => %{"value" => %{"id" => type}}}
              }
            ]
          }
        }
      }
    ])
  end

  # The export's own statements, one JSON document per row.
  defp export!(dir) do
    statements =
      @export
      |> File.read!()
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "SELECT"))

    rows =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

        for sql <- statements, [row] <- Repo.query!(sql).rows, do: Jason.encode!(row)
      end)
      |> then(fn {:ok, rows} -> rows end)

    path = Path.join(dir, "export.jsonl")
    File.write!(path, Enum.map(rows, &[&1, "\n"]))
    {:ok, snapshot} = AuditSnapshot.read(path)
    Map.put(snapshot, :path, path)
  end

  defp population!(dir, snapshot, world, overrides \\ %{}) do
    record = fn entity, fields ->
      Map.merge(%{"object_id" => entity.object_id, "label" => entity.preferred_label}, fields)
    end

    records = [
      record.(world.bierce, %{
        "disposition" => "allocation candidate after classification review confirms the mapping",
        "address_status" => "candidate",
        "candidate_path" => "/people/ambrose-bierce",
        "status" => "mapped",
        "family" => "people"
      }),
      record.(world.daman_af, %{
        "disposition" => "collision review: proposed readable qualifier, needs human approval",
        "address_status" => "collision_review",
        "candidate_path" => "/places/daman",
        "proposed_path" => "/places/daman-afghanistan",
        "status" => "mapped",
        "family" => "places"
      }),
      record.(world.daman_in, %{
        "disposition" => "collision review: proposed readable qualifier, needs human approval",
        "address_status" => "collision_review",
        "candidate_path" => "/places/daman",
        "proposed_path" => "/places/daman-india",
        "status" => "mapped",
        "family" => "places"
      }),
      record.(world.polish, %{
        "disposition" => "classification review: sole candidate family needs a human decision",
        "address_status" => "classification_review",
        "candidate_path" => "/concepts/polish",
        "status" => "needs_review"
      }),
      record.(world.cat, %{
        "disposition" => "deferred: no family evidence; stays unaddressed and visible",
        "address_status" => "not_proposed",
        "status" => "needs_review"
      })
    ]

    write_population!(dir, snapshot, records, overrides)
  end

  # A candidates file for `records`, bound to the export and the policy.
  defp write_population!(dir, snapshot, records, overrides \\ %{}) do
    inputs =
      Map.merge(
        %{"input_sha256" => snapshot.sha256, "policy_sha256" => AuditSnapshot.policy_digest()},
        overrides
      )

    path = Path.join(dir, "candidates-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{"records" => records, "summary" => %{"inputs" => inputs}}))
    path
  end

  defp reviewer!(roles \\ [reviewer: true]) do
    AccountsFixtures.unconfirmed_user_fixture()
    |> Ecto.Changeset.change(roles)
    |> Repo.update!()
  end

  # A review file as a reviewer would write it from a run's manifest: bound
  # to the population, each confirmation naming the fingerprint of the
  # decision reviewed (computed here as the evaluator computes it) unless the
  # test gives its own.
  defp reviews!(ctx, entries, file \\ %{}) do
    path = Path.join(ctx.dir, "reviews-#{System.unique_integer([:positive])}.json")

    entries =
      Enum.map(entries, fn {entity, fields} ->
        entry =
          Map.merge(
            %{
              "object_id" => entity.object_id,
              "reviewer" => ctx.reviewer.email,
              "reason" => "reviewed"
            },
            fields
          )

        if entry["action"] == "confirm" and not Map.has_key?(entry, "evidence_fingerprint"),
          do: Map.put(entry, "evidence_fingerprint", fingerprint(ctx, entity)),
          else: entry
      end)

    body =
      Map.merge(
        %{
          "population_sha256" => AuditSnapshot.digest(File.read!(ctx.population)),
          "reviews" => entries
        },
        file
      )

    File.write!(path, Jason.encode!(body))
    path
  end

  defp fingerprint(ctx, entity) do
    case Enum.find(ctx.snapshot.entities, &(&1["object_id"] == entity.object_id)) do
      nil -> String.duplicate("0", 64)
      row -> Classifications.fingerprint(Policy.classify(row, ctx.snapshot.graph, Policy.load()))
    end
  end

  defp approvals(ctx) do
    reviews!(ctx, [
      {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
      {ctx.world.daman_af,
       %{"action" => "confirm", "family" => "places", "path" => "/places/daman-afghanistan"}},
      {ctx.world.daman_in, %{"action" => "defer", "reason" => "qualifier needs a better source"}}
    ])
  end

  defp run!(ctx, reviews \\ nil, opts \\ []) do
    {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, reviews)
    {:ok, summary} = Backfill.run(plan, ctx.importer.id, Keyword.merge([batch_size: 2], opts))
    {plan, summary}
  end

  defp ids(schema), do: Repo.all(from r in schema, select: r.id) |> MapSet.new()

  defp item(plan, entity) do
    run = Repo.get_by!(BackfillRun, run_key: plan.run_key)
    Repo.get_by!(BackfillItem, run_id: run.id, object_id: entity.object_id)
  end

  # ── tests ────────────────────────────────────────────────────────────────

  test "without reviews: decisions, draft pages and dispositions, and no address", ctx do
    {plan, summary} = run!(ctx)

    assert summary.dispositions == %{"awaiting_review" => 4, "not_addressed" => 1}

    # Pages only for the records heading for an address, and all draft.
    pages = Repo.all(from p in Page, select: {p.target_object_id, p.publication_state})
    heading = [ctx.world.bierce, ctx.world.daman_af, ctx.world.daman_in]
    assert Enum.sort(pages) == Enum.sort(Enum.map(heading, &{&1.object_id, :draft}))

    assert Repo.aggregate(PublicPath, :count) == 0
    assert Repo.aggregate(RouteChange, :count) == 0

    # Every record has its evaluator decision.
    assert Repo.aggregate(from(d in ClassificationDecision, where: d.is_current), :count) == 5
    assert item(plan, ctx.world.cat).disposition == "not_addressed"

    manifest = Backfill.manifest(plan.run_key)
    assert manifest["publication_approved"] == 0
    assert length(manifest["records"]) == 5
  end

  test "with reviews: only what a named reviewer approved gets an address", ctx do
    {plan, summary} = run!(ctx, approvals(ctx))

    assert summary.dispositions == %{
             "allocated" => 2,
             "deferred_by_review" => 1,
             "awaiting_review" => 1,
             "not_addressed" => 1
           }

    paths = Repo.all(from p in PublicPath, select: {p.path, p.kind}) |> Enum.sort()

    assert paths == [
             {"/people/ambrose-bierce", :canonical},
             {"/places/daman-afghanistan", :canonical}
           ]

    # The reviewer's own decision stands behind each address.
    bierce = item(plan, ctx.world.bierce)
    decision = Repo.get!(ClassificationDecision, bierce.decision_id)
    assert decision.origin == :override
    assert decision.is_current
    assert Repo.get!(Actor, decision.reviewer_actor_id).user_id == ctx.reviewer.id

    # The collision is never qualified by import order: no path for India.
    assert item(plan, ctx.world.daman_in).disposition == "deferred_by_review"
    assert Repo.all(from p in Page, where: p.publication_state != :draft) == []
  end

  test "an edition gets its own page, and its address in /works", ctx do
    {:ok, work} =
      Registry.create_work(%{preferred_label: "The Devil's Dictionary", work_kind: "book"})

    {:ok, edition} =
      Registry.create_edition(%{
        preferred_label: "Project Gutenberg #972",
        work_id: work.object_id,
        edition_label: "1911 text"
      })

    snapshot = export!(ctx.dir)

    population =
      write_population!(ctx.dir, snapshot, [
        %{
          "object_id" => edition.object_id,
          "label" => edition.preferred_label,
          "disposition" =>
            "allocation candidate after classification review confirms the mapping",
          "address_status" => "candidate",
          "candidate_path" => "/works/project-gutenberg-sharp-972",
          "status" => "mapped",
          "family" => "works"
        }
      ])

    reviews =
      reviews!(%{ctx | population: population, snapshot: snapshot}, [
        {edition, %{"action" => "confirm", "family" => "works"}}
      ])

    {:ok, plan} = Backfill.load(snapshot.path, population, reviews)
    {:ok, summary} = Backfill.run(plan, ctx.importer.id)

    assert summary.dispositions == %{"allocated" => 1}
    page = Repo.get_by!(Page, target_object_id: edition.object_id)
    assert page.role == :edition

    assert Repo.get!(PublicPath, page.canonical_path_id).path ==
             "/works/project-gutenberg-sharp-972"
  end

  test "a confirmation refused for a reason found before writing leaves no override", ctx do
    # A collision confirmed without a path: import order may not choose.
    reviews =
      reviews!(ctx, [{ctx.world.daman_af, %{"action" => "confirm", "family" => "places"}}])

    {plan, summary} = run!(ctx, reviews)

    assert summary.dispositions["refused"] == 1
    assert item(plan, ctx.world.daman_af).reason =~ "qualified by its reviewer"

    # A path another record already holds.
    taken =
      reviews!(ctx, [
        {ctx.world.daman_af,
         %{"action" => "confirm", "family" => "places", "path" => "/places/daman"}},
        {ctx.world.daman_in, %{"action" => "defer"}}
      ])

    run!(ctx, taken)

    clash =
      reviews!(ctx, [
        {ctx.world.daman_in,
         %{"action" => "confirm", "family" => "places", "path" => "/places/daman"}}
      ])

    {plan, _} = run!(ctx, clash)

    assert item(plan, ctx.world.daman_in).disposition == "refused"

    assert item(plan, ctx.world.daman_in).reason =~
             "belongs to object #{ctx.world.daman_af.object_id}"

    refute override?(ctx.world.daman_in)
    assert Repo.aggregate(PublicPath, :count) == 1
  end

  test "a stale review is refused and writes no override", ctx do
    reviews =
      reviews!(ctx, [
        {ctx.world.bierce,
         %{
           "action" => "confirm",
           "family" => "people",
           "evidence_fingerprint" => String.duplicate("a", 64)
         }}
      ])

    {plan, _} = run!(ctx, reviews)

    assert item(plan, ctx.world.bierce).disposition == "refused"
    assert item(plan, ctx.world.bierce).reason =~ "stale review"
    refute override?(ctx.world.bierce)
    assert Repo.aggregate(PublicPath, :count) == 0
  end

  test "a second run over the same inputs writes nothing", ctx do
    reviews = approvals(ctx)
    run!(ctx, reviews)
    before = identities()

    {_plan, summary} = run!(ctx, reviews)

    assert identities() == before
    assert summary.items == 5
    assert Repo.aggregate(BackfillRun, :count) == 1
  end

  test "a new run over the same state writes nothing but its checkpoint", ctx do
    reviews = approvals(ctx)
    run!(ctx, reviews)
    before = identities()

    # The same reviews, other bytes: a new run key, so every record is
    # processed again, and every write it makes must already be there.
    again = Path.join(ctx.dir, "reviews-again.json")
    File.write!(again, reviews |> File.read!() |> Jason.decode!() |> Jason.encode!(pretty: true))

    {plan, summary} = run!(ctx, again)

    assert Repo.aggregate(BackfillRun, :count) == 2
    assert summary.items == 5
    assert summary.dispositions["allocated"] == 2
    assert Map.delete(identities(), BackfillItem) == Map.delete(before, BackfillItem)
    assert item(plan, ctx.world.bierce).path_id
  end

  test "a new review file carries every identity over", ctx do
    {_plan, _} = run!(ctx)
    pages = Repo.all(from p in Page, select: {p.target_object_id, p.id}) |> Map.new()
    evaluator = evaluator_decisions()

    {plan, _} = run!(ctx, approvals(ctx))

    assert Repo.all(from p in Page, select: {p.target_object_id, p.id}) |> Map.new() == pages
    # The evaluator's decisions are the same set; the reviewer's overrides
    # are added beside them.
    assert evaluator_decisions() == evaluator
    assert item(plan, ctx.world.bierce).page_id == pages[ctx.world.bierce.object_id]
    assert Repo.aggregate(BackfillRun, :count) == 2
  end

  test "a run interrupted mid-batch and resumed ends where an uninterrupted run ends", ctx do
    reviews = approvals(ctx)
    {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, reviews)

    # Uninterrupted, then undone: the state it reaches, by identity.
    {:error, expected} =
      Repo.transaction(fn ->
        {:ok, _} = Backfill.run(plan, ctx.importer.id, batch_size: 2)
        Repo.rollback(Backfill.state(plan.run_key))
      end)

    assert Repo.aggregate(BackfillRun, :count) == 0
    assert Enum.any?(expected, fn {_id, s} -> s.ledger != [] end)

    # Interrupted inside its second batch: the first batch stays committed.
    assert_raise RuntimeError, ~r/crash injected/, fn ->
      Backfill.run(plan, ctx.importer.id, batch_size: 2, crash_after: 3)
    end

    run = Repo.get_by!(BackfillRun, run_key: plan.run_key)
    assert Repo.aggregate(from(i in BackfillItem, where: i.run_id == ^run.id), :count) == 2
    assert is_nil(run.finished_at)

    # Resumed from its checkpoint.
    {:ok, summary} = Backfill.run(plan, ctx.importer.id, batch_size: 2)
    assert summary.items == 5

    assert Backfill.state(plan.run_key) == expected
    assert Repo.reload!(run).finished_at
  end

  test "moved input or evidence is a deferral with its reason, not a classification", ctx do
    # After the export: a renamed entity, and a new revision of a pinned item.
    {1, _} =
      Repo.update_all(from(e in "entities", where: e.object_id == ^ctx.world.bierce.object_id),
        set: [preferred_label: "Ambrose Gwinnett Bierce"]
      )

    Sources.insert_records(Sources.get_source_by_slug!("wikidata"), [
      %{
        external_id: "Q9200002",
        raw: %{"id" => "Q9200002", "claims" => %{"P31" => []}, "moved" => true}
      }
    ])

    {plan, _} = run!(ctx, approvals(ctx))

    assert item(plan, ctx.world.bierce).disposition == "input_changed"
    assert item(plan, ctx.world.daman_af).disposition == "evidence_changed"
    assert item(plan, ctx.world.daman_af).reason =~ "Q9200002"
    assert Repo.aggregate(PublicPath, :count) == 0

    refute Repo.exists?(
             from d in ClassificationDecision,
               where: d.object_id in ^[ctx.world.bierce.object_id, ctx.world.daman_af.object_id]
           )
  end

  test "evidence that returned to an earlier payload is not the revision the export pinned",
       ctx do
    # The export pins revision B; the item then returns to payload A. No
    # revision is added, so the newest revision is still B — but the current
    # one is A.
    moved = %{"id" => "Q9200001", "claims" => %{"P31" => [anchor("Q5")]}, "note" => "b"}

    Sources.insert_records(Sources.get_source_by_slug!("wikidata"), [
      %{external_id: "Q9200001", raw: moved}
    ])

    snapshot = export!(ctx.dir)
    population = population!(ctx.dir, snapshot, ctx.world)

    record!("Q9200001", "Q5")

    {:ok, plan} = Backfill.load(snapshot.path, population, nil)
    {:ok, _} = Backfill.run(plan, ctx.importer.id)

    assert item(plan, ctx.world.bierce).disposition == "evidence_changed"
    assert item(plan, ctx.world.bierce).reason =~ "Q9200001"
  end

  test "inputs that do not belong together are refused before anything is written", ctx do
    other =
      population!(ctx.dir, ctx.snapshot, ctx.world, %{"input_sha256" => String.duplicate("a", 64)})

    assert {:error, message} = Backfill.load(ctx.snapshot.path, other, nil)
    assert message =~ "derived from export"

    stale =
      population!(ctx.dir, ctx.snapshot, ctx.world, %{
        "policy_sha256" => String.duplicate("b", 64)
      })

    assert {:error, message} = Backfill.load(ctx.snapshot.path, stale, nil)
    assert message =~ "policy"

    bierce = %{"action" => "confirm", "family" => "people"}

    for {entries, file, pattern} <- [
          {[{%{object_id: 999_999_999}, %{"action" => "defer"}}], %{}, "not in the population"},
          {[{ctx.world.bierce, %{"action" => "confirm", "family" => "wizards"}}], %{},
           "a family"},
          {[{ctx.world.bierce, %{"action" => "publish"}}], %{}, "unknown action"},
          {[
             {ctx.world.bierce, %{"action" => "defer"}},
             {ctx.world.bierce, %{"action" => "defer"}}
           ], %{}, "two reviews for"},
          {[{ctx.world.bierce, Map.put(bierce, "evidence_fingerprint", nil)}], %{},
           "evidence_fingerprint"},
          {[{ctx.world.bierce, Map.put(bierce, "path", "/works/ambrose-bierce")}], %{},
           "not in /people"},
          {[{ctx.world.bierce, Map.put(bierce, "reason", "nul\u0000")}], %{}, "plain text"},
          {[{ctx.world.cat, %{"action" => "defer"}}], %{}, "does not address it"},
          {[
             {ctx.world.daman_in,
              %{
                "action" => "confirm",
                "family" => "places",
                "path" => "/places/daman-afghanistan"
              }}
           ], %{}, "proposed qualifier"},
          {[
             {ctx.world.daman_af,
              %{"action" => "confirm", "family" => "places", "path" => "/places/daman"}},
             {ctx.world.daman_in,
              %{"action" => "confirm", "family" => "places", "path" => "/places/daman"}}
           ], %{}, "two reviews approve"},
          {[{ctx.world.bierce, bierce}], %{"population_sha256" => String.duplicate("c", 64)},
           "made on population"},
          {[{ctx.world.bierce, bierce}], %{"rehearsal" => true}, "rehearsal reviews"}
        ] do
      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, reviews!(ctx, entries, file))

      assert message =~ pattern
    end

    # Rehearsal reviews load only where they are allowed.
    rehearsal = reviews!(ctx, [{ctx.world.bierce, bierce}], %{"rehearsal" => true})

    assert {:ok, _} =
             Backfill.load(ctx.snapshot.path, ctx.population, rehearsal, allow_rehearsal: true)

    # A population whose disposition says nothing the backfill knows.
    odd =
      write_population!(ctx.dir, ctx.snapshot, [
        %{"object_id" => ctx.world.bierce.object_id, "disposition" => "ship it"}
      ])

    assert {:error, message} = Backfill.load(ctx.snapshot.path, odd, nil)
    assert message =~ "unknown disposition"

    # A reviewer the database does not know, or one without the role.
    for account <- ["nobody@example.invalid", reviewer!(reviewer: false).email] do
      reviews = reviews!(%{ctx | reviewer: %{email: account}}, [{ctx.world.bierce, bierce}])
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, reviews)
      assert {:error, _} = Backfill.run(plan, ctx.importer.id)
    end

    assert Repo.aggregate(BackfillRun, :count) == 0
    assert Repo.aggregate(ClassificationDecision, :count) == 0
    refute Repo.exists?(from a in Actor, where: a.actor_kind == :user)
  end

  test "the manifest counts published pages rather than asserting none", ctx do
    {plan, _} = run!(ctx, approvals(ctx))
    assert Backfill.manifest(plan.run_key)["publication_approved"] == 0

    page = Repo.get_by!(Page, target_object_id: ctx.world.bierce.object_id)

    {1, _} =
      Repo.update_all(from(p in Page, where: p.id == ^page.id),
        set: [publication_state: :published]
      )

    assert Backfill.manifest(plan.run_key)["publication_approved"] == 1
  end

  test "the checkpoint is append-only", ctx do
    {plan, _} = run!(ctx)
    item = item(plan, ctx.world.cat)

    for sql <- [
          {"UPDATE routing_backfill_items SET reason = 'x' WHERE id = $1", [item.id]},
          {"DELETE FROM routing_backfill_items WHERE id = $1", [item.id]},
          {"UPDATE routing_backfill_runs SET records = 0", []},
          {"UPDATE routing_backfill_runs SET finished_at = now()", []},
          {"DELETE FROM routing_backfill_runs", []}
        ] do
      {statement, params} = sql

      assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.query!(statement, params) end
    end

    for table <- ~w(routing_backfill_items routing_backfill_runs) do
      assert_raise Postgrex.Error, ~r/cannot be truncated/, fn ->
        Repo.query!("TRUNCATE #{table} CASCADE")
      end
    end
  end

  # ── helpers used by the tests ────────────────────────────────────────────

  defp identities do
    for schema <- [Page, PublicPath, ClassificationDecision, RouteChange, BackfillItem],
        into: %{},
        do: {schema, ids(schema)}
  end

  defp evaluator_decisions,
    do:
      Repo.all(from d in ClassificationDecision, where: d.origin == :evaluator, select: d.id)
      |> MapSet.new()

  defp override?(entity) do
    Repo.exists?(
      from d in ClassificationDecision,
        where: d.object_id == ^entity.object_id and d.origin == :override
    )
  end

  defp anchor(type),
    do: %{"rank" => "normal", "mainsnak" => %{"datavalue" => %{"value" => %{"id" => type}}}}
end
