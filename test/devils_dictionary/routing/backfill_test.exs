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

  import DevilsDictionary.RoutingFixtures,
    only: [subject_page!: 2, subject_page!: 3, allocated!: 3]

  alias DevilsDictionary.{AccountsFixtures, Fixtures, Registry, Sources}
  alias Ecto.Adapters.SQL.Sandbox

  alias DevilsDictionary.Routing.{
    AuditSnapshot,
    Backfill,
    BackfillItem,
    BackfillRun,
    ClassificationDecision,
    Classifications,
    Ledger,
    Page,
    Pages,
    Policy,
    PublicPath,
    ReviewRule,
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

    DevilsDictionary.RoutingFixtures.published!(page)

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

  # ── evidence the evaluation depended on without matching it (#219 A1) ────
  #
  # The independent audit's probe, and its two siblings: the run classifies
  # from the exported graph, so every record that graph lent the evaluation —
  # matched or not, present or absent — must still be what the export saw.

  test "an unmatched ancestor that changed defers the record and needs a fresh review", ctx do
    # Polish's one type, Q1, is held but maps nowhere when the export is taken.
    class!("Q1", [])
    snapshot = export!(ctx.dir)
    ctx = %{ctx | snapshot: snapshot, population: population!(ctx.dir, snapshot, ctx.world)}
    reviews = reviews!(ctx, [{ctx.world.polish, confirm("concepts", "/concepts/polish")}])

    # Then Q1 becomes a kind of human, without the entity or its own record
    # changing.
    class!("Q1", ["Q5"])

    {plan, _} = run!(ctx, reviews)

    assert %{disposition: "evidence_changed", reason: "not current: Q1"} =
             item(plan, ctx.world.polish)

    refute override?(ctx.world.polish)
    assert Repo.aggregate(PublicPath, :count) == 0

    # A fresh export reaches another result, under another fingerprint, so
    # the review made on the old one cannot be carried over.
    fresh = export!(Path.join(ctx.dir, "fresh") |> tap(&File.mkdir_p!/1))
    row = Enum.find(fresh.entities, &(&1["object_id"] == ctx.world.polish.object_id))
    assert Policy.classify(row, fresh.graph, Policy.load()).candidate_families == ["people"]

    refute fingerprint(%{ctx | snapshot: fresh}, ctx.world.polish) ==
             fingerprint(ctx, ctx.world.polish)
  end

  test "an ancestor the export did not hold, arriving later, defers the record", ctx do
    # Q1 is not held at all when the setup's export is taken...
    row = Enum.find(ctx.snapshot.entities, &(&1["object_id"] == ctx.world.polish.object_id))
    result = Policy.classify(row, ctx.snapshot.graph, Policy.load())
    assert %{"qid" => "Q1", "absent" => true} in result.dependencies

    reviews = reviews!(ctx, [{ctx.world.polish, confirm("concepts", "/concepts/polish")}])

    # ...and arrives, mapped, before the run.
    class!("Q1", ["Q5"])

    {plan, _} = run!(ctx, reviews)

    assert %{disposition: "evidence_changed", reason: "not current: Q1"} =
             item(plan, ctx.world.polish)

    refute override?(ctx.world.polish)
  end

  test "an unmatched branch that gains a contradicting family defers a reviewed mapping", ctx do
    # Bierce is also typed Q2 at export time, a class that maps nowhere, and a
    # reviewer confirms People over that warning.
    typed!("Q9200001", ["Q5", "Q2"])
    class!("Q2", [])
    snapshot = export!(ctx.dir)
    ctx = %{ctx | snapshot: snapshot, population: population!(ctx.dir, snapshot, ctx.world)}
    reviews = reviews!(ctx, [{ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}])

    # Then Q2 turns out to be a kind of country.
    class!("Q2", ["Q6256"])

    {plan, _} = run!(ctx, reviews)

    assert %{disposition: "evidence_changed", reason: "not current: Q2"} =
             item(plan, ctx.world.bierce)

    refute override?(ctx.world.bierce)
    assert Repo.aggregate(PublicPath, :count) == 0

    fresh = export!(Path.join(ctx.dir, "fresh") |> tap(&File.mkdir_p!/1))
    row = Enum.find(fresh.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    fresh_result = Policy.classify(row, fresh.graph, Policy.load())

    assert {fresh_result.status, fresh_result.candidate_families} ==
             {"needs_review", ["people", "places"]}
  end

  # ── a refused confirmation writes nothing (#219 A2) ──────────────────────
  #
  # Each test runs once without reviews first, so the evaluator's decisions
  # and the draft pages exist, then takes the record's routing state by value
  # and runs the confirmation. Whatever refuses it — a check made before
  # writing, or a step after the override, or a concurrent writer — the
  # record's decision, page, path and ledger state must be what they were,
  # its checkpoint must say `refused` with the reason, and the batch must go
  # on to the records after it.

  test "a retired page: refused, nothing written, the batch goes on", ctx do
    {:ok, page} = Pages.ensure(:subject, ctx.world.bierce.object_id)
    human = human_actor!(ctx)
    {:ok, _} = Ledger.retire(page.id, actor_id: human.id, reason: "retired before review")
    run!(ctx)
    before = state_of(ctx.world.bierce)

    reviews =
      reviews!(ctx, [
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
        {ctx.world.daman_af, confirm("places", "/places/daman-afghanistan")}
      ])

    {plan, _} = run!(ctx, reviews, batch_size: 5)

    assert %{disposition: "refused", reason: reason, page_id: page_id} =
             item(plan, ctx.world.bierce)

    assert reason =~ "retired"
    assert page_id == page.id
    assert state_of(ctx.world.bierce) == before
    assert item(plan, ctx.world.daman_af).disposition == "allocated"
  end

  test "a page of another role, refused after the override was written: rolled back", ctx do
    # A concept with a subject page, whose stored kind then becomes an
    # edition's: its page is now the wrong role, and only the page step can
    # find that out — after the override has been written.
    concept = entity!(:concept, "Stray edition", "Q9200006", "Q1")
    {:ok, _page} = Pages.ensure(:subject, concept.object_id)

    Repo.query!("UPDATE entities SET entity_kind = 'edition' WHERE object_id = $1", [
      concept.object_id
    ])

    {ctx, reviews} =
      with_record(ctx, concept, "/works/stray-edition", [
        {concept, confirm("works", "/works/stray-edition")},
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}
      ])

    run!(ctx)
    before = state_of(concept)

    {plan, _} = run!(ctx, reviews, batch_size: 10)

    assert %{disposition: "refused", reason: "page: :target_has_other_role"} =
             item(plan, concept)

    assert state_of(concept) == before
    refute override?(concept)
    assert item(plan, ctx.world.bierce).disposition == "allocated"
  end

  test "a path another writer takes after the checks: rolled back, the batch goes on", ctx do
    run!(ctx)
    before = state_of(ctx.world.polish)
    rival = subject_page!("concepts", "Polish (language)")

    reviews =
      reviews!(ctx, [
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
        {ctx.world.polish, confirm("concepts", "/concepts/polish")},
        {ctx.world.daman_in, confirm("places", "/places/daman-india")}
      ])

    # The rival holds /concepts/polish, allocated and uncommitted, until the
    # backfill has passed its checks and is waiting on the address's lock.
    holder = hold(fn -> allocated!(rival, "/concepts/polish", ctx.importer) end)
    backfill = backfill(ctx, reviews, batch_size: 10)
    blocked!(backfill.backend, "advisory")
    release(holder)

    assert {:ok, plan} = await(backfill)

    assert %{disposition: "refused", reason: reason} = item(plan, ctx.world.polish)
    assert reason =~ ":path_taken"
    assert state_of(ctx.world.polish) == before
    refute override?(ctx.world.polish)

    assert [%{destination_page_id: owner}] =
             Repo.all(from p in PublicPath, where: p.path == "/concepts/polish")

    assert owner == rival.id
    # Before and after the refusal, in the same batch.
    assert item(plan, ctx.world.bierce).disposition == "allocated"
    assert item(plan, ctx.world.daman_in).disposition == "allocated"
  end

  test "a canonical another writer gives the page after the checks: rolled back", ctx do
    # Bierce mapped by the evaluator itself, so another writer may address
    # his page: his projection agrees with his record.
    ctx = mapped_bierce!(ctx)
    run!(ctx)
    before = state_of(ctx.world.bierce)
    page = Repo.get_by!(Page, target_object_id: ctx.world.bierce.object_id)
    reviews = reviews!(ctx, [{ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}])

    # Another writer gives the page a different address and holds the page
    # row until the backfill is waiting for it.
    holder = hold(fn -> allocated!(page, "/people/ambrose-gwinnett-bierce", ctx.importer) end)
    backfill = backfill(ctx, reviews, batch_size: 10)
    blocked!(backfill.backend, "transactionid")
    release(holder)

    assert {:ok, plan} = await(backfill)

    assert %{disposition: "refused", reason: reason} = item(plan, ctx.world.bierce)
    assert reason =~ ":page_has_canonical"
    refute override?(ctx.world.bierce)

    after_state = state_of(ctx.world.bierce)
    assert after_state.decisions == before.decisions
    assert [%{path: "/people/ambrose-gwinnett-bierce", kind: :canonical}] = after_state.paths
    # Only the other writer's operation is on the ledger.
    assert length(after_state.ledger) == 2
    assert Repo.aggregate(PublicPath, :count) == 1
  end

  test "the subject's kind changing after the checks: refused at the page, rolled back", ctx do
    subject = entity!(:concept, "Late kind", "Q9200007", "Q1")

    {ctx, reviews} =
      with_record(ctx, subject, "/concepts/late-kind", [
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
        {subject, confirm("concepts", "/concepts/late-kind")}
      ])

    run!(ctx)
    before = state_of(subject)

    # Bierce's address is held, so the batch — its inputs already read and
    # compared — waits on the first record while the second one's kind
    # changes underneath it.
    holder = hold(fn -> lock_path!("/people/ambrose-bierce") end)
    backfill = backfill(ctx, reviews, batch_size: 10)
    blocked!(backfill.backend, "advisory")

    Repo.query!("UPDATE entities SET entity_kind = 'edition' WHERE object_id = $1", [
      subject.object_id
    ])

    release(holder)

    assert {:ok, plan} = await(backfill)

    assert item(plan, ctx.world.bierce).disposition == "allocated"

    assert %{disposition: "refused", reason: "page: :target_kind_mismatch"} =
             item(plan, subject)

    assert state_of(subject) == before
    refute override?(subject)
  end

  test "a lost race on the address index rolls the batch back, and the rerun resumes", ctx do
    run!(ctx)
    before = state_of(ctx.world.bierce)
    rival = subject_page!("people", "Ambrose Bierce (namesake)", :person)
    reviews = reviews!(ctx, [{ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}])
    {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, reviews)

    # A writer that bypasses the ledger's locks: only the unique index can see
    # it, and inside the batch's transaction the ledger cannot retry.
    holder = hold(fn -> lock_free_allocation!(rival, "/people/ambrose-bierce", ctx.importer) end)
    backfill = backfill(ctx, reviews, batch_size: 10)
    blocked!(backfill.backend, "transactionid")
    release(holder)

    assert {:raised, %Ecto.ConstraintError{constraint: "public_paths_path_index"}} =
             await(backfill)

    # The whole batch rolled back: no checkpoint, no confirmation.
    run = Repo.get_by!(BackfillRun, run_key: plan.run_key)
    refute Repo.exists?(from i in BackfillItem, where: i.run_id == ^run.id)
    assert state_of(ctx.world.bierce) == before

    # Running it again resumes it, and the address is now refused up front.
    {:ok, _summary} = Backfill.run(plan, ctx.importer.id, batch_size: 10)
    assert %{disposition: "refused", reason: reason} = item(plan, ctx.world.bierce)
    assert reason =~ "belongs to object #{rival.target_object_id}"
    assert state_of(ctx.world.bierce) == before
  end

  # A policy anchor is matched by its identifier and never read (A6 of #219):
  # its record arriving or changing between the export and the run changes
  # neither the outcome nor the fingerprint, so it defers nothing — on the
  # corpus, Q5 is the anchor every person matches through.
  test "a matched anchor's own record arriving or changing defers nothing", ctx do
    ctx = mapped_bierce!(ctx)
    row = Enum.find(ctx.snapshot.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    before = Policy.classify(row, ctx.snapshot.graph, Policy.load())
    refute Enum.any?(before.dependencies, &(&1["qid"] == "Q5"))

    reviews = reviews!(ctx, [{ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}])

    # Q5 arrives after the export, then changes.
    class!("Q5", [])
    class!("Q5", ["Q215627"])

    {plan, _} = run!(ctx, reviews)
    assert item(plan, ctx.world.bierce).disposition == "allocated"

    fresh = export!(Path.join(ctx.dir, "fresh") |> tap(&File.mkdir_p!/1))
    row = Enum.find(fresh.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    now = Policy.classify(row, fresh.graph, Policy.load())

    assert Classifications.fingerprint(now) == Classifications.fingerprint(before)
  end

  # The corpus's case: Q5 is in the export, then its record changes.
  test "a matched anchor the export held, changing afterwards, defers nothing", ctx do
    class!("Q5", [])
    ctx = mapped_bierce!(ctx)
    assert Map.has_key?(ctx.snapshot.graph, "Q5")
    row = Enum.find(ctx.snapshot.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    before = Policy.classify(row, ctx.snapshot.graph, Policy.load())
    refute Enum.any?(before.dependencies, &(&1["qid"] == "Q5"))

    reviews = reviews!(ctx, [{ctx.world.bierce, %{"action" => "confirm", "family" => "people"}}])
    class!("Q5", ["Q215627"])

    {plan, _} = run!(ctx, reviews)
    assert item(plan, ctx.world.bierce).disposition == "allocated"

    fresh = export!(Path.join(ctx.dir, "fresh") |> tap(&File.mkdir_p!/1))
    refute fresh.graph["Q5"] == ctx.snapshot.graph["Q5"]
    row = Enum.find(fresh.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    now = Policy.classify(row, fresh.graph, Policy.load())

    assert Classifications.fingerprint(now) == Classifications.fingerprint(before)
  end

  # Two callers of the backfill at once (#219 A2's concurrency acceptance):
  # the second waits on the first's locks and then refuses what the first
  # allocated. One override and one address survive.
  test "two concurrent runs confirming one record in different families", ctx do
    run!(ctx)

    reviews_a =
      reviews!(ctx, [
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
        {ctx.world.polish, confirm("concepts", "/concepts/polish")}
      ])

    reviews_b =
      reviews!(ctx, [
        {ctx.world.bierce, %{"action" => "confirm", "family" => "people"}},
        {ctx.world.polish, confirm("subjects", "/subjects/polish")}
      ])

    # Run A stops inside Polish's confirmation, its override written under the
    # savepoint, on the address's lock; run B then waits on run A.
    holder = hold(fn -> lock_path!("/concepts/polish") end)
    a = backfill(ctx, reviews_a, batch_size: 10)
    blocked!(a.backend, "advisory")
    b = backfill(ctx, reviews_b, batch_size: 10)
    blocked!(b.backend, "advisory")
    release(holder)

    assert {:ok, plan_a} = await(a)
    assert {:ok, plan_b} = await(b)

    assert item(plan_a, ctx.world.polish).disposition == "allocated"
    assert %{disposition: "refused", reason: reason} = item(plan_b, ctx.world.polish)
    assert reason =~ "already has the address /concepts/polish"
    assert item(plan_b, ctx.world.bierce).disposition == "allocated"

    assert Repo.all(
             from d in ClassificationDecision,
               where: d.object_id == ^ctx.world.polish.object_id and d.origin == :override,
               select: d.family
           ) == [:concepts]

    assert Repo.all(from p in PublicPath, where: like(p.path, "%polish%"), select: p.path) ==
             ["/concepts/polish"]
  end

  # ── under the standing review rule (#237) ───────────────────────────────

  describe "under the standing review rule" do
    # Bierce and both Damans as the corpus would hold them: each stored type
    # projection agreeing with its record, so the evaluator maps them. A
    # fresh export, and the population with its collision group named.
    setup ctx do
      for {entity, type} <- [
            {ctx.world.bierce, "Q5"},
            {ctx.world.daman_af, "Q6256"},
            {ctx.world.daman_in, "Q6256"}
          ] do
        Repo.query!(
          "UPDATE entities SET metadata = metadata || jsonb_build_object('wikidata_instance_of', jsonb_build_array($2::text)) WHERE object_id = $1",
          [entity.object_id, type]
        )
      end

      snapshot = export!(ctx.dir)

      for entity <- [ctx.world.bierce, ctx.world.daman_af, ctx.world.daman_in] do
        row = Enum.find(snapshot.entities, &(&1["object_id"] == entity.object_id))
        assert Policy.classify(row, snapshot.graph, Policy.load()).status == "mapped"
      end

      ctx = %{ctx | snapshot: snapshot, population: population!(ctx.dir, snapshot, ctx.world)}
      %{snapshot: snapshot, population: with_groups!(ctx), rule: signed_rule!(ctx)}
    end

    test "every record is decided by a clause; a confirmation is the signer's override, naming the rule",
         ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      decisions = Backfill.decisions(plan)

      assert %{action: :confirm, clause: "uncontested_mapping", path: "/people/ambrose-bierce"} =
               decisions[ctx.world.bierce.object_id]

      assert %{action: :confirm, clause: "qualified_collision", path: "/places/daman-afghanistan"} =
               decisions[ctx.world.daman_af.object_id]

      assert %{action: :confirm, clause: "qualified_collision", path: "/places/daman-india"} =
               decisions[ctx.world.daman_in.object_id]

      assert %{action: :defer, clause: "classification_review"} =
               decisions[ctx.world.polish.object_id]

      assert %{action: :not_addressed} = decisions[ctx.world.cat.object_id]

      {:ok, summary} = Backfill.run(plan, ctx.importer.id, batch_size: 2)

      assert summary.dispositions == %{
               "allocated" => 3,
               "deferred_by_review" => 1,
               "not_addressed" => 1
             }

      paths = Repo.all(from p in PublicPath, select: p.path) |> Enum.sort()

      assert paths == [
               "/people/ambrose-bierce",
               "/places/daman-afghanistan",
               "/places/daman-india"
             ]

      # Each override is the signer's, and names the rule's digest.
      for entity <- [ctx.world.bierce, ctx.world.daman_af, ctx.world.daman_in] do
        decision = Classifications.current(entity.object_id)
        assert decision.origin == :override
        assert "review_rule:#{ctx.rule.sha256}" in decision.rule_ids
        assert Classifications.rule_sha256(decision) == ctx.rule.sha256
        assert decision.reason =~ ctx.rule.sha256
        assert Repo.get!(Actor, decision.reviewer_actor_id).user_id == ctx.reviewer.id
      end

      # The deferred record and the record outside the population keep the
      # evaluator's decision; no page for either.
      refute override?(ctx.world.polish)
      refute override?(ctx.world.cat)
      refute Repo.get_by(Page, target_object_id: ctx.world.polish.object_id)

      # Every checkpoint row names the rule and its clause.
      for entity <- Map.values(ctx.world) do
        review = item(plan, entity).review
        assert review["rule_sha256"] == ctx.rule.sha256
        assert review["signer"] == ctx.reviewer.email
        assert is_binary(review["clause"])
      end

      # The run row itself says the rule decided it.
      run = Repo.get_by!(BackfillRun, run_key: plan.run_key)
      assert run.rule_sha256 == ctx.rule.sha256
      assert is_nil(run.reviews_sha256)

      manifest = Backfill.manifest(plan.run_key)
      assert manifest["inputs"]["rule_sha256"] == ctx.rule.sha256
      assert manifest["publication_approved"] == 0

      clauses = Map.new(manifest["records"], &{&1.object_id, &1.rule_clause})
      assert clauses[ctx.world.daman_in.object_id] == "qualified_collision"
      assert Repo.all(from p in Page, where: p.publication_state != :draft) == []
    end

    test "the dry run writes nothing", ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      before = identities()
      decisions = Backfill.decisions(plan)

      assert map_size(decisions) == 5
      assert identities() == before
      assert Repo.aggregate(BackfillRun, :count) == 0
    end

    test "a second run, and a new rule over the decided population, write nothing but a checkpoint",
         ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      {:ok, _} = Backfill.run(plan, ctx.importer.id, batch_size: 2)
      before = identities()

      {:ok, again} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      {:ok, _} = Backfill.run(again, ctx.importer.id)
      assert identities() == before

      # Another signed rule: a new run key. Every address is the rule's
      # earlier decision, kept; nothing but the checkpoint is written.
      other = signed_rule!(ctx, &Map.put(&1, "name", "Standing review rule, again"))
      refute other.sha256 == ctx.rule.sha256
      {:ok, next} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: other.path)
      refute next.run_key == plan.run_key

      decisions = Backfill.decisions(next)

      assert %{action: :confirm, clause: "standing_decision", standing: true} =
               decisions[ctx.world.daman_af.object_id]

      {:ok, summary} = Backfill.run(next, ctx.importer.id)
      assert summary.dispositions["allocated"] == 3
      assert Map.delete(identities(), BackfillItem) == Map.delete(before, BackfillItem)
    end

    test "what a reviewer decided stands under the rule", ctx do
      # A reviewer confirmed Bierce and Afghanistan's Daman, and deferred
      # India's; the rule then runs over the same population.
      {:ok, reviewed} = Backfill.load(ctx.snapshot.path, ctx.population, approvals(ctx))
      {:ok, _} = Backfill.run(reviewed, ctx.importer.id)
      overrides = Repo.all(from d in ClassificationDecision, where: d.origin == :override)
      before = identities()

      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      decisions = Backfill.decisions(plan)

      for entity <- [ctx.world.bierce, ctx.world.daman_af] do
        assert %{action: :confirm, clause: "standing_decision", standing: true} =
                 decisions[entity.object_id]
      end

      assert %{action: :defer, clause: "standing_decision", reason: reason} =
               decisions[ctx.world.daman_in.object_id]

      assert reason =~ "qualifier needs a better source"

      {:ok, summary} = Backfill.run(plan, ctx.importer.id)
      assert summary.dispositions["allocated"] == 2
      assert summary.dispositions["deferred_by_review"] == 2

      # The reviewer's overrides stay the decisions; the rule wrote none.
      assert Repo.all(from d in ClassificationDecision, where: d.origin == :override) == overrides
      assert Map.delete(identities(), BackfillItem) == Map.delete(before, BackfillItem)
    end

    test "a page a human retired is a standing decision: deferred, and its group with it", ctx do
      # A reviewer confirmed Afghanistan's Daman alone; a human then retired
      # that page. The rule must not confirm it again, nor allocate India's
      # without it.
      {:ok, reviewed} =
        Backfill.load(
          ctx.snapshot.path,
          ctx.population,
          reviews!(ctx, [
            {ctx.world.daman_af,
             %{"action" => "confirm", "family" => "places", "path" => "/places/daman-afghanistan"}}
          ])
        )

      {:ok, _} = Backfill.run(reviewed, ctx.importer.id)
      page = Repo.get_by!(Page, target_object_id: ctx.world.daman_af.object_id)
      human = Repo.get_by(Actor, actor_kind: :user, user_id: ctx.reviewer.id) || human_actor!(ctx)
      {:ok, _} = Ledger.retire(page.id, actor_id: human.id, reason: "retired by a human")

      before = identities()

      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      decisions = Backfill.decisions(plan)

      assert %{action: :defer, clause: "standing_decision", reason: reason} =
               decisions[ctx.world.daman_af.object_id]

      assert reason =~ "its page is retired"

      assert %{action: :defer, clause: "unqualified_collision", reason: reason} =
               decisions[ctx.world.daman_in.object_id]

      assert reason =~ "#{ctx.world.daman_af.object_id} standing_decision"

      {:ok, summary} = Backfill.run(plan, ctx.importer.id)
      assert summary.dispositions["deferred_by_review"] == 3
      assert summary.dispositions["allocated"] == 1

      # The tombstone stands and nothing in the group was allocated: the
      # only address written is Bierce's, outside the group.
      assert Repo.all(from p in PublicPath, select: {p.path, p.kind}) |> Enum.sort() ==
               [{"/people/ambrose-bierce", :canonical}, {"/places/daman-afghanistan", :tombstone}]

      # India's draft page (every record awaiting review gets one) holds no
      # address; Afghanistan's stays retired.
      assert %Page{canonical_path_id: nil, lifecycle_state: :active} =
               Repo.get_by!(Page, target_object_id: ctx.world.daman_in.object_id)

      assert Repo.get!(Page, page.id).lifecycle_state == :retired
      assert MapSet.size(identities()[RouteChange]) == MapSet.size(before[RouteChange]) + 2
    end

    test "a record the batch defers before the rule's decision applies still names the rule",
         ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)

      # Bierce's input moves between the export and the run.
      Repo.query!(
        "UPDATE entities SET preferred_label = 'Ambrose G. Bierce' WHERE object_id = $1",
        [ctx.world.bierce.object_id]
      )

      {:ok, summary} = Backfill.run(plan, ctx.importer.id)
      assert summary.dispositions["input_changed"] == 1

      review = item(plan, ctx.world.bierce).review
      assert review["rule_sha256"] == ctx.rule.sha256
      assert review["action"] == "stale"
      assert review["reason"] =~ "input_changed"

      manifest = Backfill.manifest(plan.run_key)
      assert manifest["inputs"]["rule_sha256"] == ctx.rule.sha256
      clauses = Map.new(manifest["records"], &{&1.object_id, &1.rule_clause})
      assert clauses[ctx.world.bierce.object_id] == "stale"
    end

    test "a run executes the decisions it printed, or defers what moved meanwhile", ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      decided = Backfill.decisions(plan)
      assert %{action: :confirm} = decided[ctx.world.bierce.object_id]

      # Between the dry run and the run, a reviewer defers Bierce.
      {:ok, reviewed} =
        Backfill.load(
          ctx.snapshot.path,
          ctx.population,
          reviews!(ctx, [{ctx.world.bierce, %{"action" => "defer", "reason" => "not yet"}}])
        )

      {:ok, _} = Backfill.run(reviewed, ctx.importer.id)
      before = identities()

      {:ok, summary} = Backfill.run(plan, ctx.importer.id, decided: decided)
      assert summary.dispositions["allocated"] == 2
      assert summary.dispositions["deferred_by_review"] == 2

      bierce = item(plan, ctx.world.bierce)
      assert bierce.disposition == "deferred_by_review"
      assert bierce.reason =~ "the state moved since the rule decided"
      assert bierce.reason =~ "object #{ctx.world.bierce.object_id} was confirmed"
      refute override?(ctx.world.bierce)

      # The Damans, whose state did not move, were allocated as printed;
      # Bierce got nothing.
      assert Repo.all(from p in PublicPath, select: p.path) |> Enum.sort() ==
               ["/places/daman-afghanistan", "/places/daman-india"]

      assert identities()[ClassificationDecision] |> MapSet.size() ==
               MapSet.size(before[ClassificationDecision]) + 2
    end

    test "a human's confirmation at the rule's own path, made between the printed decisions and the run, stands",
         ctx do
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      decided = Backfill.decisions(plan)
      assert %{action: :confirm, standing: false} = decided[ctx.world.bierce.object_id]

      # Another reviewer confirms Bierce in people, at the same address the
      # rule chose, through a review-file run.
      other = reviewer!()

      {:ok, reviewed} =
        Backfill.load(
          ctx.snapshot.path,
          ctx.population,
          reviews!(ctx, [
            {ctx.world.bierce,
             %{"action" => "confirm", "family" => "people", "reviewer" => other.email}}
          ])
        )

      {:ok, _} = Backfill.run(reviewed, ctx.importer.id)
      human = Classifications.current(ctx.world.bierce.object_id)
      assert human.origin == :override
      assert Repo.get!(Actor, human.reviewer_actor_id).user_id == other.id

      {:ok, summary} = Backfill.run(plan, ctx.importer.id, decided: decided)
      assert summary.dispositions["allocated"] == 3

      # Bierce's address is kept under the human's decision: the rule wrote
      # no override of its own, and the human's stays current.
      item = item(plan, ctx.world.bierce)
      assert item.disposition == "allocated"
      assert item.review["clause"] == "standing_decision"
      assert Classifications.current(ctx.world.bierce.object_id).id == human.id

      assert Repo.all(
               from d in ClassificationDecision,
                 where: d.origin == :override and d.object_id == ^ctx.world.bierce.object_id,
                 select: d.id
             ) == [human.id]
    end

    test "a population whose groups are not its own is refused at load", ctx do
      broken = fn edit ->
        path = Path.join(ctx.dir, "broken-#{System.unique_integer([:positive])}.json")
        doc = ctx.population |> File.read!() |> Jason.decode!()
        File.write!(path, Jason.encode!(edit.(doc)))
        path
      end

      unknown = broken.(&put_in(&1, ["groups", "/places/daman"], [999_999_999]))

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, unknown, nil, rule: ctx.rule.path)

      assert message =~ "names 999999999, which the population does not"

      astray = broken.(&put_in(&1, ["groups", "/places/daman"], [ctx.world.bierce.object_id]))

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, astray, nil, rule: ctx.rule.path)

      assert message =~ "whose candidate path is not /places/daman"

      # A second group over the same members cannot be theirs: their
      # candidate path is the first group's.
      twice = broken.(&put_in(&1, ["groups", "/places/daman-too"], &1["groups"]["/places/daman"]))
      assert {:error, message} = Backfill.load(ctx.snapshot.path, twice, nil, rule: ctx.rule.path)
      assert message =~ "candidate path is not /places/daman-too"

      empty = broken.(&put_in(&1, ["groups", "/places/daman"], []))
      assert {:error, message} = Backfill.load(ctx.snapshot.path, empty, nil, rule: ctx.rule.path)
      assert message =~ "has no members"
    end

    test "a signature written into the rule file by hand does not decide a run", ctx do
      before = identities()
      {:ok, rule} = ReviewRule.read(ctx.rule.path)

      forged = Path.join(ctx.dir, "forged.json")

      File.write!(
        forged,
        ReviewRule.path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("name", "Standing review rule, forged")
        |> then(fn doc ->
          Map.put(doc, "signature", %{
            "signer" => ctx.reviewer.email,
            "user_id" => ctx.reviewer.id,
            "rule_sha256" => ReviewRule.digest(doc),
            "signed_at" => "2026-10-09T12:00:00Z",
            "method" => "typed by hand",
            "attestation" => "not the owner"
          })
        end)
        |> Jason.encode!()
      )

      refute ReviewRule.digest(Jason.decode!(File.read!(forged))) == rule.sha256

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: forged)

      assert message =~ "no signing of"
      assert message =~ "review_rule_signatures"
      assert identities() == before
      assert Repo.aggregate(BackfillRun, :count) == 0
    end

    test "an unsigned, changed or unauthorised rule is refused before anything is written", ctx do
      before = identities()

      unsigned = Path.join(ctx.dir, "unsigned.json")

      File.write!(
        unsigned,
        ctx.rule.path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("signature", nil)
        |> Jason.encode!()
      )

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: unsigned)

      assert message =~ "not signed"

      changed = Path.join(ctx.dir, "changed.json")

      File.write!(
        changed,
        ctx.rule.path
        |> File.read!()
        |> Jason.decode!()
        |> update_in(["clauses", Access.at(5), "text"], &(&1 <> " And more."))
        |> Jason.encode!()
      )

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: changed)

      assert message =~ "changed after it was signed"

      # A rule and a review file never decide one run together.
      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, approvals(ctx),
                 rule: ctx.rule.path
               )

      assert message =~ "not both"

      # The signer no longer a reviewer: refused at load, and at run.
      {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)
      ctx.reviewer |> Ecto.Changeset.change(reviewer: false) |> Repo.update!()

      assert {:error, message} =
               Backfill.load(ctx.snapshot.path, ctx.population, nil, rule: ctx.rule.path)

      assert message =~ "does not hold the reviewer role"
      assert {:error, _} = Backfill.run(plan, ctx.importer.id)

      assert identities() == before
      assert Repo.aggregate(BackfillRun, :count) == 0
    end
  end

  # ── helpers used by the tests ────────────────────────────────────────────

  defp identities do
    for schema <- [Page, PublicPath, ClassificationDecision, RouteChange, BackfillItem],
        into: %{},
        do: {schema, ids(schema)}
  end

  # The population with its collision group named, as candidates.py writes
  # one: the rule decides a group together.
  defp with_groups!(ctx) do
    groups = %{
      "/places/daman" => Enum.sort([ctx.world.daman_af.object_id, ctx.world.daman_in.object_id])
    }

    path = Path.join(ctx.dir, "candidates-groups-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      ctx.population
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("groups", groups)
      |> Jason.encode!()
    )

    path
  end

  # The committed rule, unsigned and edited by `edit`, signed in this test's
  # directory by the test's reviewer with their password.
  defp signed_rule!(ctx, edit \\ & &1) do
    path = Path.join(ctx.dir, "review-rule-#{System.unique_integer([:positive])}.json")

    doc =
      ReviewRule.path()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("signature", nil)
      |> edit.()

    File.write!(path, Jason.encode!(doc, pretty: true))
    AccountsFixtures.set_password(ctx.reviewer)

    {:ok, rule} =
      ReviewRule.sign(path, ctx.reviewer.email, AccountsFixtures.valid_user_password())

    rule
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

  # ── helpers for the atomicity and dependency tests (#219) ────────────────

  defp confirm(family, path), do: %{"action" => "confirm", "family" => family, "path" => path}

  # A class record: `parents` are its P279 values.
  defp class!(qid, parents) do
    Sources.insert_records(Sources.get_source_by_slug!("wikidata"), [
      %{
        external_id: qid,
        raw: %{"id" => qid, "claims" => %{"P279" => Enum.map(parents, &anchor/1)}}
      }
    ])
  end

  # An item record with several P31 types.
  defp typed!(qid, types) do
    Sources.insert_records(Sources.get_source_by_slug!("wikidata"), [
      %{external_id: qid, raw: %{"id" => qid, "claims" => %{"P31" => Enum.map(types, &anchor/1)}}}
    ])
  end

  # A fresh export and population with one more record, a classification
  # review of `entity` proposing `path`, and reviews bound to them.
  defp with_record(ctx, entity, path, entries) do
    snapshot = export!(ctx.dir)

    extra = %{
      "object_id" => entity.object_id,
      "label" => entity.preferred_label,
      "disposition" => "classification review: sole candidate family needs a human decision",
      "address_status" => "classification_review",
      "candidate_path" => path,
      "status" => "needs_review"
    }

    base =
      ctx.population
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("records")

    population = write_population!(ctx.dir, snapshot, base ++ [extra])
    ctx = %{ctx | snapshot: snapshot, population: population}
    {ctx, reviews!(ctx, entries)}
  end

  # The setup's Bierce is `needs_review`: his stored projection names no type
  # while his record says Q5. Agreeing, he is mapped; a fresh export and
  # population follow.
  defp mapped_bierce!(ctx) do
    Repo.query!(
      "UPDATE entities SET metadata = metadata || '{\"wikidata_instance_of\": [\"Q5\"]}' WHERE object_id = $1",
      [ctx.world.bierce.object_id]
    )

    snapshot = export!(ctx.dir)
    row = Enum.find(snapshot.entities, &(&1["object_id"] == ctx.world.bierce.object_id))
    assert Policy.classify(row, snapshot.graph, Policy.load()).status == "mapped"
    %{ctx | snapshot: snapshot, population: population!(ctx.dir, snapshot, ctx.world)}
  end

  defp human_actor!(ctx),
    do: Repo.insert!(%Actor{actor_kind: :user, user_id: ctx.reviewer.id, label: "reviewer"})

  # Everything a confirmation can write about one entity, by value.
  defp state_of(entity) do
    id = entity.object_id

    pages =
      Repo.all(from p in Page, where: p.target_object_id == ^id, order_by: p.id)
      |> Enum.map(
        &Map.take(&1, [
          :id,
          :role,
          :lifecycle_state,
          :publication_state,
          :canonical_path_id,
          :current_revision_id,
          :last_route_change_id
        ])
      )

    page_ids = Enum.map(pages, & &1.id)

    paths =
      Repo.all(
        from p in PublicPath,
          where: p.original_page_id in ^page_ids or p.destination_page_id in ^page_ids,
          order_by: p.id
      )
      |> Enum.map(&Map.take(&1, [:id, :path, :kind, :destination_page_id, :last_route_change_id]))

    path_ids = Enum.map(paths, & &1.id)

    %{
      decisions:
        Repo.all(from d in ClassificationDecision, where: d.object_id == ^id, order_by: d.id)
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :origin,
            :status,
            :family,
            :is_current,
            :evidence_fingerprint,
            :reviewer_actor_id,
            :supersedes_id
          ])
        ),
      pages: pages,
      paths: paths,
      ledger:
        Repo.all(
          from c in RouteChange,
            where:
              c.page_id in ^page_ids or c.path_id in ^path_ids or
                c.after_destination_id in ^page_ids or c.before_destination_id in ^page_ids,
            order_by: c.id,
            select: c.id
        )
    }
  end

  # A writer on its own connection, holding its transaction open after `fun`
  # until released: a concurrent caller the backfill cannot see yet.
  defp hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          fun.()
          send(parent, {:holding, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, pid}, 10_000
    %{task: task, pid: pid}
  end

  defp release(%{task: task, pid: pid}) do
    send(pid, :release)
    assert {:ok, :ok} = Task.await(task, 30_000)
  end

  # The backfill on its own connection; `backend` is its Postgres pid.
  defp backfill(ctx, reviews, opts) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:backend, self(), backend_pid()})
        {:ok, plan} = Backfill.load(ctx.snapshot.path, ctx.population, reviews)

        try do
          {:ok, _summary} = Backfill.run(plan, ctx.importer.id, opts)
          {:ok, plan}
        rescue
          error -> {:raised, error}
        end
      end)

    assert_receive {:backend, pid, backend}, 10_000
    %{task: task, pid: pid, backend: backend}
  end

  defp await(%{task: task}), do: Task.await(task, 30_000)

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Waits, in Postgres, until `backend` waits on a lock of `event` — which no
  # message can announce, because the waiting process is inside a query.
  # Bounded at ten seconds.
  defp blocked!(backend, event, tries \\ 1_000) do
    %{rows: [[blocked?]]} =
      Repo.query!(
        "SELECT count(*) = 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND wait_event = $2",
        [backend, event]
      )

    cond do
      blocked? -> :ok
      tries == 0 -> flunk("the backfill never waited on a #{event} lock")
      true -> Repo.query!("SELECT pg_sleep(0.01)") && blocked!(backend, event, tries - 1)
    end
  end

  # The ledger's own lock on an address, taken and held.
  defp lock_path!(path),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["route-path:" <> path])

  # What a writer that bypassed `Routing.Ledger` would do (as in
  # `ConcurrencyTest`): every row the database requires, none of its locks.
  defp lock_free_allocation!(page, path, actor) do
    operation = Ecto.UUID.generate()
    %{rows: [[id]]} = Repo.query!("SELECT nextval('public_paths_id_seq')")

    created =
      Repo.insert!(%RouteChange{
        operation_id: operation,
        sequence: 1,
        operation: :allocate,
        path_id: id,
        after_kind: :canonical,
        after_destination_id: page.id,
        actor_id: actor.id,
        reason: "lock-free writer"
      })

    Repo.insert!(%PublicPath{
      id: id,
      path: path,
      kind: :canonical,
      original_page_id: page.id,
      destination_page_id: page.id,
      last_route_change_id: created.id
    })

    pointed =
      Repo.insert!(%RouteChange{
        operation_id: operation,
        sequence: 2,
        operation: :allocate,
        page_id: page.id,
        before_lifecycle: :active,
        after_lifecycle: :active,
        after_canonical_path_id: id,
        actor_id: actor.id,
        reason: "lock-free writer"
      })

    page
    |> Ecto.Changeset.change(canonical_path_id: id, last_route_change_id: pointed.id)
    |> Repo.update!()
  end
end
