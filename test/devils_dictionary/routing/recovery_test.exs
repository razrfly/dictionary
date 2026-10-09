defmodule DevilsDictionary.Routing.RecoveryTest do
  @moduledoc """
  The supported recovery procedure (`docs/routing/recovery.md`), exercised end
  to end against an isolated, disposable database created and dropped here.

  1. A registry built through the real projection — Wikipedia's records
     materialized, then Wikidata's — carries a full routing history: decisions
     and an override, subject and On pages, revisions with membership,
     allocation, a move, a merge, a split, a retirement, a restoration and a
     rollback.
  2. `DevilsDictionary.Snapshot` — the code behind `mix dd.snapshot` — dumps it
     and restores the dump into a new database.
  3. `Routing.Recovery.verify/2` — the code behind `mix dd.routing.verify` —
     finds every registry identity and routing row, by exact id and reference,
     every resolution and every sequence, the same.
  4. The restored copy is re-projected through the supported paths in the
     **opposite provider order**: `mix dd.replay` from an exported archive,
     Wikidata before Wikipedia, then `mix dd.materialize --all --resolve`,
     Wikidata before Wikipedia. It still matches exactly, and each
     materialization found every table it fingerprints, pending relations
     included, identical.
  5. The ledger and resolver work on the restored copy, and the destructive
     tasks refuse it without a covering snapshot.

  The test database is only ever read and dumped; every write in steps 2–5
  lands in the disposable copy.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures
  import ExUnit.CaptureIO

  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Absorb.Sources.{Wikidata, Wikipedia}
  alias DevilsDictionary.{Claims, Fixtures, Registry, Snapshot, Sources}

  alias DevilsDictionary.Routing.{
    Address,
    Classifications,
    Ledger,
    Page,
    Pages,
    PublicPath,
    Recovery,
    Resolution,
    Resolver,
    ReviewRule,
    ReviewRuleSignature
  }

  @moduletag :unboxed
  @moduletag :capture_log
  @moduletag timeout: 300_000

  @records [{"cat", "Q146"}, {"dog", "Q144"}, {"oyster", "Q107411"}]

  setup do
    Fixtures.seed_catalog!()
    Claims.Catalog.seed!()

    source = Repo.config()[:database]
    unique = System.unique_integer([:positive])
    target = "#{source}_recovery_#{unique}"
    dump = Path.join(System.tmp_dir!(), "routing-recovery-#{unique}.dump")
    archive = Path.join(System.tmp_dir!(), "routing-replay-#{unique}")

    on_exit(fn ->
      _ = Ecto.Adapters.Postgres.storage_down(Keyword.put(Repo.config(), :database, target))
      File.rm(dump)
      File.rm(dump <> ".routing.json")
      File.rm_rf(archive)
    end)

    %{source: source, target: target, dump: dump, archive: archive, human: human!()}
  end

  defp opts(actor, reason \\ "recovery fixture"), do: [actor_id: actor.id, reason: reason]
  defp resolve(path), do: path |> Address.encode() |> Resolver.resolve()

  # Wikipedia, then Wikidata twice (its absorb loops for late taxonomy edges):
  # the original provider order.
  defp project! do
    wikipedia = Sources.get_source_by_slug!("wikipedia")
    wikidata = Sources.get_source_by_slug!("wikidata")

    for {lemma, qid} <- @records do
      Sources.insert_records(wikipedia, [
        %{external_id: lemma, raw: Wikipedia.trim(Fixtures.one_raw("wikipedia", lemma))}
      ])

      raw = Fixtures.raw("wikidata", lemma) |> Enum.find(&(&1["id"] == qid)) |> Wikidata.trim()
      Sources.insert_records(wikidata, [%{external_id: qid, raw: raw}])
    end

    Batch.run(Wikipedia, wikipedia, only_stale: false)
    Batch.run(Wikidata, wikidata, only_stale: false)
    Batch.run(Wikidata, wikidata, only_stale: false)

    Map.new(@records, fn {lemma, qid} -> {lemma, Registry.by_external_id("wikidata", qid)} end)
  end

  defp subject_on!(object_id, family, path, human) do
    classify!(object_id, family)
    {:ok, page} = Pages.ensure(:subject, object_id)
    page |> allocated!(path, human) |> published!()
  end

  # A routing history that touches every table and every operation.
  # The standing review rule's recorded signing (#237 Part A′): durable
  # routing state too, so the digest, the snapshot and the restore cover it.
  defp signed_rule! do
    reviewer =
      DevilsDictionary.AccountsFixtures.unconfirmed_user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()

    {:ok, rule} = ReviewRule.read(ReviewRule.path())

    Repo.insert!(%ReviewRuleSignature{
      rule_sha256: rule.sha256,
      user_id: reviewer.id,
      signed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      method: "recovery test fixture",
      attestation: "a signing recorded for the restore to carry"
    })
  end

  defp history!(ids, human) do
    cat = subject_on!(ids["cat"], "nature", "/nature/cat", human)
    dog = subject_on!(ids["dog"], "nature", "/nature/dog", human)
    {:ok, _} = Ledger.move(dog.id, "/nature/domestic-dog", opts(human, "more precise"))

    oyster = entity_on_projection_with_override!(ids["oyster"], human)

    [arouet, voltaire] =
      for path <- ["/people/arouet", "/people/voltaire"],
          do: live_page!("people", path, human, :person)

    {:ok, _} =
      Registry.merge([arouet.target_object_id], voltaire.target_object_id, reason: "one man")

    {:ok, _} = Ledger.merge(arouet.id, voltaire.id, opts(human))

    [mercury, planet, element] =
      for path <- ["/nature/mercury", "/nature/mercury-planet", "/nature/mercury-element"],
          do: live_page!("nature", path, human)

    {:ok, _} =
      Registry.split(
        mercury.target_object_id,
        [planet.target_object_id, element.target_object_id],
        reason: "planet and element"
      )

    {:ok, _} = Ledger.split(mercury.id, [planet.id, element.id], opts(human))

    retired = live_page!("people", "/people/candide", human, :person)
    {:ok, _} = Ledger.retire(retired.id, opts(human, "fiction"))
    reinstated = live_page!("people", "/people/pangloss", human, :person)
    {:ok, _} = Ledger.retire(reinstated.id, opts(human, "withdrawn"))
    {:ok, _} = Ledger.restore(reinstated.id, "/people/pangloss", opts(human, "reinstated"))

    undone = live_page!("people", "/people/zadig", human, :person)
    {:ok, _} = Ledger.move(undone.id, "/people/zadig-le-babylonien", opts(human))
    %{operation_id: move} = Ledger.history(page_id: undone.id) |> List.last()
    {:ok, _} = Ledger.rollback(move, opts(human, "wrong title"))

    on = overview_page!() |> allocated!("/on/mercury", human) |> published!()
    poutine = lexeme!("poutine")

    {:ok, _} =
      Pages.add_revision(
        on.id,
        %{title: "On Mercury", body: "Planet, element, god."},
        [
          %{relationship: :discusses_subject, target_page_id: planet.id},
          %{relationship: :supplies_lexical_material, target_object_id: poutine.object_id},
          %{relationship: :editorial_association, target_object_id: ids["cat"], rationale: "none"}
        ],
        human.id
      )

    {:ok, _} = Pages.add_revision(on.id, %{title: "On Mercury", body: "Revised."}, [], human.id)

    %{cat: cat, dog: dog, oyster: oyster, voltaire: voltaire, zadig: undone, mercury: mercury}
  end

  # Registry references outside the routing tables that a restore must keep:
  # an edition's work and a variant spelling's canonical lexeme.
  defp registry_references! do
    {:ok, candide} = Registry.create_work(%{preferred_label: "Candide", work_kind: "novel"})
    {:ok, zadig} = Registry.create_work(%{preferred_label: "Zadig", work_kind: "novel"})

    {:ok, edition} =
      Registry.create_edition(%{
        preferred_label: "Candide (1759)",
        work_id: candide.object_id,
        publication_year: 1759
      })

    cockle = lexeme!("cockle")

    {:ok, _variant} =
      Registry.create_lexeme(%{
        lemma: "cokel",
        part_of_speech: "noun",
        canonical_lexeme_id: cockle.object_id
      })

    %{
      edition: edition.object_id,
      other_work: zadig.object_id,
      other_lexeme: lexeme!("whelk").object_id
    }
  end

  defp entity_on_projection_with_override!(object_id, human) do
    reviewed = leave_unmapped!(object_id)

    {:ok, _} =
      Classifications.override(
        object_id,
        %{
          status: :mapped,
          family: :nature,
          reason: "a mollusc",
          evidence_fingerprint: reviewed.evidence_fingerprint
        },
        human.id
      )

    {:ok, page} = Pages.ensure(:subject, object_id)
    page |> allocated!("/nature/oyster", human) |> published!()
  end

  # Replaces the Repo's configuration for tasks that read it.
  defp configured_with(config, fun) do
    original = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)
    Application.put_env(:devils_dictionary, DevilsDictionary.Repo, config)

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, original)
    end
  end

  # Points the configured database at `database` for tasks that read it.
  defp configured_as(database, fun) do
    original = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    Application.put_env(
      :devils_dictionary,
      DevilsDictionary.Repo,
      Keyword.put(original, :database, database)
    )

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, original)
    end
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  test "a restored copy is the same registry and routing state, before and after re-projection",
       ctx do
    ids = project!()
    pages = history!(ids, ctx.human)
    signed_rule!()
    references = registry_references!()
    baseline = Recovery.manifest(rows: true)
    baseline_projected = Recovery.manifest(rows: true, mode: :projected)
    resolutions = Recovery.resolutions()

    # The fixture reached every routing table and every operation, the
    # publication receipts (#237): each published page's, and the standing
    # review rule's recorded signing.
    for table <- Recovery.durable_tables(), do: assert(baseline[table].count > 0, table)

    assert baseline["route_changes"].rows
           |> Enum.map(&(Jason.decode!(&1) |> Enum.at(3)))
           |> MapSet.new() ==
             MapSet.new(~w(allocate move merge split retire restore rollback))

    # Nothing hand-picked: every table and the schema are sections.
    assert Map.has_key?(baseline, "edition_details")
    assert Map.has_key?(baseline, "lexemes")
    assert Map.has_key?(baseline, "schema")
    assert Map.has_key?(baseline, "sequences")
    refute Map.has_key?(baseline, "oban_jobs")

    Recovery.snapshot!(Repo.config(), ctx.dump)
    Snapshot.restore!(Keyword.put(Repo.config(), :database, ctx.target), ctx.dump)

    # The operator's command, run from the source's side: exact, and read-only.
    verified =
      capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", ctx.target]) end)

    assert verified =~ "#{ctx.source} on localhost:"
    assert verified =~ "matches #{ctx.target} on localhost:"
    assert verified =~ "every path and page resolves the same"
    refute verified =~ "not applicable"

    Recovery.with_database(ctx.target, fn ->
      # 3. Exactly the same, section by section and row by row.
      restored = Recovery.manifest(rows: true)
      assert Recovery.diff(baseline, restored) == %{}
      assert Map.keys(restored) == Map.keys(baseline)
      assert Recovery.resolutions() == resolutions
      assert {:ok, report} = Recovery.verify(ctx.source)
      assert report.sections["objects"] == baseline["objects"].count
      assert report.sections["page_publications"] == baseline["page_publications"].count

      # Sequences are compared by their own `last_value` and `is_called`, so
      # a changed next id is a difference even for a sequence never used,
      # whose `pg_sequences.last_value` is null (the audit's case).
      %{rows: [[unused]]} =
        Repo.query!("""
        SELECT sequencename::text FROM pg_sequences
         WHERE schemaname = 'public' AND last_value IS NULL
         ORDER BY sequencename COLLATE "C" LIMIT 1
        """)

      [[start, false]] = Repo.query!(~s|SELECT last_value, is_called FROM "#{unused}"|).rows

      for {value, called?} <- [{100, false}, {200, false}, {start, true}] do
        Repo.query!("SELECT setval($1::text::regclass, $2, $3)", [unused, value, called?])
        assert {:error, %{differences: moved}} = Recovery.verify(ctx.source)
        assert Map.keys(moved) == ["sequences"]
        assert [changed] = moved["sequences"].only_after
        assert changed == Jason.encode!([unused, value, called?])
      end

      Repo.query!("SELECT setval($1::text::regclass, $2, false)", [unused, start])
      assert {:ok, _report} = Recovery.verify(ctx.source)

      # And a used one whose `is_called` alone changes: the same last value,
      # but a different next id.
      [[last, true]] = Repo.query!("SELECT last_value, is_called FROM pages_id_seq").rows
      Repo.query!("SELECT setval('pages_id_seq', $1, false)", [last])

      assert {:error, %{differences: %{"sequences" => _} = uncalled}} =
               Recovery.verify(ctx.source)

      assert Map.keys(uncalled) == ["sequences"]
      Repo.query!("SELECT setval('pages_id_seq', $1, true)", [last])
      assert {:ok, _report} = Recovery.verify(ctx.source)

      # 4. Re-projection through the supported paths, providers reversed —
      #    and not vacuously: every record is replayed and re-materialized.
      #    The replay archive is exported from the restored copy itself, so it
      #    holds exactly the records the snapshot held.
      capture_io(fn ->
        Mix.Tasks.Dd.Export.Replay.run(["--out", ctx.archive, "--quiet"])
      end)

      output =
        capture_io(fn ->
          for source <- ["wikidata", "wikipedia"] do
            Mix.Tasks.Dd.Replay.run(["--dir", ctx.archive, "--source", source])
          end

          for source <- ["wikidata", "wikipedia"] do
            Mix.Tasks.Dd.Materialize.run(["--source", source, "--all", "--resolve"])
          end
        end)

      assert output =~ ~r/wikidata\s+3 records replayed/
      assert output =~ ~r/wikipedia\s+3 records replayed/

      # Each replay's run records what its passes materialized, and what
      # they did not project.
      replays = Repo.all(from r in "import_runs", where: r.task == "replay", select: r.stats)
      assert length(replays) == 2

      for stats <- replays do
        assert %{"materialized" => %{"records" => _, "passes" => _, "dispositions" => _}} = stats
      end

      assert output =~ "wikidata: materializing 3 record(s)"
      assert output =~ "wikipedia: materializing 3 record(s)"

      assert :binary.match(output, "wikidata: materializing") <
               :binary.match(output, "wikipedia: materializing")

      assert length(Regex.scan(~r/semantic replay identical: true/, output)) == 2
      refute output =~ "not compared"

      projected = Recovery.manifest(rows: true, mode: :projected)
      assert Recovery.diff(baseline_projected, projected) == %{}
      assert Map.keys(projected) == Map.keys(baseline_projected)
      assert Recovery.sequences_behind() == []
      assert Recovery.resolutions() == resolutions
      assert {:ok, _report} = Recovery.verify(ctx.source, projected: true)

      # 5. The restored ledger and resolver keep working, and new ids follow on.
      assert %Resolution{outcome: :canonical} = resolve("/nature/cat")

      assert %Resolution{outcome: :redirect, location: "/nature/domestic-dog"} =
               resolve("/nature/dog")

      assert %Resolution{outcome: :redirect, location: "/people/voltaire"} =
               resolve("/people/arouet")

      assert %Resolution{outcome: :choice} = resolve("/nature/mercury")
      assert %Resolution{outcome: :gone} = resolve("/people/candide")

      {:ok, _} = Ledger.move(pages.cat.id, "/nature/house-cat", opts(ctx.human))

      assert %Resolution{outcome: :redirect, location: "/nature/house-cat"} =
               resolve("/nature/cat")

      %{operation_id: moved_before_snapshot} =
        Ledger.history(page_id: pages.dog.id) |> Enum.find(&(&1.operation == :move))

      {:ok, _} = Ledger.rollback(moved_before_snapshot, opts(ctx.human, "restored copy"))
      assert %Resolution{outcome: :canonical} = resolve("/nature/dog")

      fresh = live_page!("people", "/people/micromegas", ctx.human, :person)
      assert fresh.id > Enum.max(Enum.map(baseline["pages"].rows, &(Jason.decode!(&1) |> hd())))
      assert %Resolution{outcome: :canonical} = resolve("/people/micromegas")

      # The comparison is not vacuous: those writes are now differences.
      assert {:error, %{differences: differences}} = Recovery.verify(ctx.source)
      assert Map.has_key?(differences, "route_changes")
      assert Map.has_key?(differences, "pages")

      # Nor is it hand-picked: a changed registry reference outside the
      # routing tables — an edition's work, a variant's canonical lexeme — is
      # a difference in exactly its own table.
      untampered = Recovery.manifest(rows: true)

      Repo.query!("UPDATE edition_details SET work_id = $1 WHERE entity_id = $2", [
        references.other_work,
        references.edition
      ])

      Repo.query!(
        "UPDATE lexemes SET canonical_lexeme_id = $1 WHERE canonical_lexeme_id IS NOT NULL",
        [references.other_lexeme]
      )

      tampered = Recovery.diff(untampered, Recovery.manifest(rows: true))
      assert tampered |> Map.keys() |> Enum.sort() == ["edition_details", "lexemes"]
      assert [changed] = tampered["edition_details"].only_after

      assert Jason.decode!(changed) |> Enum.take(3) == [
               references.edition,
               "edition",
               references.other_work
             ]

      # A switched-off guard or a new grant changes no row, but it is a
      # different database to restore into: the schema section differs.
      untampered = Recovery.manifest(rows: true)
      Repo.query!("ALTER TABLE route_changes DISABLE TRIGGER route_changes_guard")
      Repo.query!("GRANT SELECT ON pages TO PUBLIC")
      weakened = Recovery.diff(untampered, Recovery.manifest(rows: true))
      assert Map.keys(weakened) == ["schema"]
      assert Enum.any?(weakened["schema"].only_after, &(&1 =~ "route_changes_guard"))
      assert Enum.any?(weakened["schema"].only_after, &(&1 =~ ~s|"relation","pages"|))

      # Privileges are compared as granted: revoking the grant leaves an
      # explicit ACL equal to the default a NULL one stands for, which is no
      # difference at all.
      Repo.query!("REVOKE SELECT ON pages FROM PUBLIC")

      assert %{rows: [[true]]} =
               Repo.query!(
                 "SELECT relacl IS NOT NULL FROM pg_class WHERE oid = 'pages'::regclass"
               )

      assert Recovery.diff(untampered, Recovery.manifest(rows: true)) |> Map.keys() == ["schema"]
      Repo.query!("ALTER TABLE route_changes ENABLE TRIGGER route_changes_guard")
      assert Recovery.diff(untampered, Recovery.manifest(rows: true)) == %{}

      # Schema and default privileges, which `--no-privileges` does not
      # restore either, are compared too.
      Repo.query!("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC")
      assert Recovery.diff(untampered, Recovery.manifest(rows: true)) |> Map.keys() == ["schema"]
      Repo.query!("ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM PUBLIC")
      Repo.query!("GRANT CREATE ON SCHEMA public TO PUBLIC")
      assert Recovery.diff(untampered, Recovery.manifest(rows: true)) |> Map.keys() == ["schema"]
      Repo.query!("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
      assert Recovery.diff(untampered, Recovery.manifest(rows: true)) == %{}
    end)

    # The source was only read.
    assert Recovery.diff(baseline, Recovery.manifest(rows: true)) == %{}
  end

  test "destructive tasks refuse a database holding routing state unless a covering snapshot exists",
       ctx do
    ids = project!()
    history!(ids, ctx.human)
    target_config = Keyword.put(Repo.config(), :database, ctx.target)

    # A database that does not exist, or holds no routing state, is not guarded.
    assert Recovery.guard(target_config, "reset", nil) == :ok

    Recovery.snapshot!(Repo.config(), ctx.dump)
    Snapshot.restore!(target_config, ctx.dump)

    assert {:error, refusal} = Recovery.guard(target_config, "reset", nil)
    assert refusal =~ "refusing to reset #{ctx.target}: it holds durable routing state"
    assert refusal =~ "docs/routing/recovery.md"

    # A production config names its database only in `url:`; the guard reads
    # it as Ecto does. A config naming no database at all is refused.
    url_config =
      target_config
      |> Keyword.drop([:database, :hostname, :port, :username, :password])
      |> Keyword.put(:url, url(target_config))

    assert {:error, by_url} = Recovery.guard(url_config, "drop", nil)
    assert by_url =~ "refusing to drop #{ctx.target}: it holds durable routing state"

    assert {:error, nameless} =
             Recovery.guard(Keyword.delete(target_config, :database), "drop", nil)

    assert nameless =~ "names no database"

    # Verification under such a config reads the database it is asked to,
    # not the one the URL names.
    configured_with(url_config |> Keyword.put(:url, url(Repo.config())), fn ->
      assert Recovery.with_database(ctx.target, fn ->
               Repo.query!("SELECT current_database()").rows
             end) == [[ctx.target]]
    end)

    # Rolling the routing migrations back would drop the routing tables; each
    # refuses while its tables hold anything. The publication receipts'
    # migration is the newer, so it refuses first (#237); the foundation's,
    # asked alone, refuses as well.
    Recovery.with_database(ctx.target, fn ->
      rollback =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.run(Repo, Ecto.Migrator.migrations_path(Repo), :down,
            to: 20_260_926_193_256,
            dynamic_repo: Repo.get_dynamic_repo(),
            log: false
          )
        end

      assert rollback.postgres.message =~ "refusing to roll back page_publications"

      [{foundation, _}] =
        Repo
        |> Ecto.Migrator.migrations_path()
        |> Path.join("20260926193256_create_routing_foundation.exs")
        |> Code.compile_file()

      rollback =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.run(Repo, [{20_260_926_193_256, foundation}], :down,
            all: true,
            dynamic_repo: Repo.get_dynamic_repo(),
            log: false
          )
        end

      assert rollback.postgres.message =~ "refusing to roll back the routing foundation"
      assert %{rows: [[true]]} = Repo.query!("SELECT to_regclass('route_changes') IS NOT NULL")

      assert %{rows: [[true]]} =
               Repo.query!("SELECT to_regclass('page_publications') IS NOT NULL")
    end)

    # The source's snapshot holds the same routing rows, but it is a snapshot
    # of another database, so it covers nothing here.
    assert {:error, elsewhere} = Recovery.guard(target_config, "reset", ctx.dump)
    assert elsewhere =~ "is a snapshot of #{ctx.source} (cluster"
    assert elsewhere =~ ", not #{ctx.target} (cluster"

    # The tasks consult the guard before they drop, restore or rebuild anything.
    configured_as(ctx.target, fn ->
      assert_raise Mix.Error, ~r/refusing to reset/, fn ->
        Mix.Tasks.Dd.Reset.run(["--database", ctx.target])
      end

      assert_raise Mix.Error, ~r/refusing to restore over/, fn ->
        Mix.Tasks.Dd.Snapshot.run(["--restore", ctx.dump, "--database", ctx.target])
      end
    end)

    assert_raise Mix.Error, ~r/refusing to rebuild/, fn ->
      Mix.Tasks.Dd.Rebuild.run(["--scope", "animals"])
    end

    # A plain dump, with no recorded digest, does not count as covering anything.
    bare = ctx.dump <> ".bare"
    Snapshot.dump!(target_config, bare)
    on_exit(fn -> File.rm(bare) end)
    assert {:error, unmarked} = Recovery.guard(target_config, "reset", bare)
    assert unmarked =~ "no routing digest"

    # A snapshot of the target covers it until its routing state changes.
    covering = ctx.dump <> ".target"
    on_exit(fn -> File.rm(covering) && File.rm(covering <> ".routing.json") end)
    Recovery.snapshot!(target_config, covering)
    assert Recovery.guard(target_config, "reset", covering) == :ok

    # The digest vouches for the dump it was taken with, not for whatever
    # file later has that name: a truncated or a replaced dump is refused
    # even though `pg_restore --list` may still read it.
    damaged = ctx.dump <> ".damaged"
    on_exit(fn -> File.rm(damaged) && File.rm(damaged <> ".routing.json") end)
    File.cp!(covering <> ".routing.json", damaged <> ".routing.json")
    bytes = File.read!(covering)
    File.write!(damaged, binary_part(bytes, 0, byte_size(bytes) - 64))
    assert {:error, truncated} = Recovery.guard(target_config, "reset", damaged)
    assert truncated =~ "is not the dump its routing digest was taken with"
    # The source's dump: every routing table, the same routing rows, and so
    # `pg_restore --list` alone would accept it.
    File.cp!(ctx.dump, damaged)
    assert File.read!(damaged) != bytes
    assert {:error, replaced} = Recovery.guard(target_config, "reset", damaged)
    assert replaced =~ "is not the dump its routing digest was taken with"

    # `mix ecto.drop` and `mix ecto.reset` are guarded too, through the alias.
    assert Mix.Project.config()[:aliases][:"ecto.drop"] == ["dd.routing.guard drop", "ecto.drop"]

    configured_as(ctx.target, fn ->
      with_env("DD_ROUTING_SNAPSHOT", nil, fn ->
        assert_raise Mix.Error, ~r/refusing to drop #{ctx.target}/, fn ->
          Mix.Tasks.Dd.Routing.Guard.run(["drop"])
        end
      end)

      with_env("DD_ROUTING_SNAPSHOT", covering, fn ->
        assert Mix.Tasks.Dd.Routing.Guard.run(["drop"]) == :ok
      end)
    end)

    # A publication change writes no ledger row; its receipt and the page's
    # new state both count (#237).
    Recovery.with_database(ctx.target, fn ->
      %{rows: [[page_id]]} =
        Repo.query!("SELECT min(id) FROM pages WHERE publication_state = 'published'")

      %{rows: [[actor_id]]} =
        Repo.query!("SELECT min(id) FROM actors WHERE actor_kind = 'user'")

      {:ok, _} =
        Repo.transaction(fn ->
          [receipt, params] = receipt_sql(page_id, "withdraw", "published", "withdrawn", actor_id)
          Repo.query!(receipt, params)
          Repo.query!("UPDATE pages SET publication_state = 'withdrawn' WHERE id = $1", [page_id])
        end)
    end)

    assert {:error, stale} = Recovery.guard(target_config, "reset", covering)
    assert stale =~ "routing state has changed since"

    # A write in flight while the snapshot is taken is not in it: once it
    # commits, the snapshot no longer covers the database.
    Recovery.snapshot!(target_config, covering)
    test = self()

    writer =
      Task.async(fn ->
        Recovery.with_database(ctx.target, fn ->
          Repo.transaction(fn ->
            live_page!("people", "/people/micromegas", ctx.human, :person)
            send(test, :written)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :written, 30_000
    Recovery.snapshot!(target_config, covering)
    assert Recovery.guard(target_config, "reset", covering) == :ok
    send(writer.pid, :commit)
    assert {:ok, _} = Task.await(writer, 30_000)

    assert {:error, raced} = Recovery.guard(target_config, "reset", covering)
    assert raced =~ "routing state has changed since"

    assert {:error, missing} = Recovery.guard(target_config, "reset", ctx.dump <> ".absent")
    assert missing =~ "no snapshot"

    # Still there: nothing was dropped.
    assert Recovery.with_database(ctx.target, fn -> Repo.aggregate(Page, :count) end) > 0
    assert Repo.aggregate(PublicPath, :count) > 0

    # And the real `mix ecto.drop`, alias and all, on the disposable copy:
    # refused without a covering snapshot, then allowed with one.
    configured_as(ctx.target, fn ->
      with_env("DD_ROUTING_SNAPSHOT", nil, fn ->
        assert_raise Mix.Error, ~r/refusing to drop #{ctx.target}/, fn ->
          Mix.Task.rerun("ecto.drop", ["--quiet"])
        end
      end)

      assert Recovery.durable_state(target_config) != nil
      Recovery.snapshot!(target_config, covering)

      with_env("DD_ROUTING_SNAPSHOT", covering, fn ->
        capture_io(fn -> Mix.Task.rerun("ecto.drop", ["--quiet"]) end)
      end)
    end)

    assert Recovery.durable_state(target_config) == nil
    assert Ecto.Adapters.Postgres.storage_status(target_config) == :down
  end

  defp url(config) do
    password = if config[:password], do: ":" <> URI.encode_www_form(config[:password]), else: ""
    port = if config[:port], do: ":#{config[:port]}", else: ""

    "ecto://#{config[:username]}#{password}@#{config[:hostname] || "localhost"}#{port}/#{config[:database]}"
  end
end
