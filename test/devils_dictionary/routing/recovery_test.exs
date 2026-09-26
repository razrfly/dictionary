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
     Wikidata before Wikipedia, then `mix dd.materialize --all`, Wikidata
     before Wikipedia. It still matches exactly.
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
    Resolver
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

  test "a restored copy is the same registry and routing state, before and after re-projection",
       ctx do
    ids = project!()
    pages = history!(ids, ctx.human)
    baseline = Recovery.manifest(rows: true)
    resolutions = Recovery.resolutions()

    # The fixture reached every routing table and every operation.
    for table <- Recovery.routing_tables(), do: assert(baseline[table].count > 0, table)

    assert baseline["route_changes"].rows
           |> Enum.map(&(Jason.decode!(&1) |> Enum.at(3)))
           |> MapSet.new() ==
             MapSet.new(~w(allocate move merge split retire restore rollback))

    capture_io(fn ->
      Mix.Tasks.Dd.Export.Replay.run(["--out", ctx.archive, "--quiet"])
    end)

    Snapshot.dump!(Repo.config(), ctx.dump)
    Snapshot.restore!(Keyword.put(Repo.config(), :database, ctx.target), ctx.dump)

    # The operator's command, run from the source's side: exact, and read-only.
    verified =
      capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", ctx.target]) end)

    assert verified =~ "#{ctx.source} matches #{ctx.target} exactly."

    Recovery.with_database(ctx.target, fn ->
      # 3. Exactly the same, section by section and row by row.
      restored = Recovery.manifest(rows: true)
      assert Recovery.diff(baseline, restored) == %{}
      assert Map.keys(restored) == Map.keys(baseline)
      assert Recovery.resolutions() == resolutions
      assert {:ok, report} = Recovery.verify(ctx.source)
      assert report.sections["objects"] == baseline["objects"].count

      # 4. Re-projection through the supported paths, providers reversed —
      #    and not vacuously: every record is replayed and re-materialized.
      output =
        capture_io(fn ->
          for source <- ["wikidata", "wikipedia"] do
            Mix.Tasks.Dd.Replay.run(["--dir", ctx.archive, "--source", source])
          end

          for source <- ["wikidata", "wikipedia"] do
            Mix.Tasks.Dd.Materialize.run(["--source", source, "--all"])
          end
        end)

      assert output =~ ~r/wikidata\s+3 records replayed/
      assert output =~ ~r/wikipedia\s+3 records replayed/
      assert output =~ "wikidata: materializing 3 record(s)"
      assert output =~ "wikipedia: materializing 3 record(s)"

      assert :binary.match(output, "wikidata: materializing") <
               :binary.match(output, "wikipedia: materializing")

      projected = Recovery.manifest(rows: true, sequences: false)
      assert Recovery.diff(Map.delete(baseline, "sequences"), projected) == %{}
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
    assert Recovery.guard(target_config, "reset", ctx.dump) == :ok

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

    # A snapshot with no recorded marks does not count as covering anything.
    bare = ctx.dump <> ".bare"
    Snapshot.dump!(target_config, bare)
    on_exit(fn -> File.rm(bare) end)
    assert {:error, unmarked} = Recovery.guard(target_config, "reset", bare)
    assert unmarked =~ "no routing marks"

    # A snapshot taken before the latest routing write no longer covers it.
    Recovery.with_database(ctx.target, fn ->
      live_page!("people", "/people/micromegas", ctx.human, :person)
    end)

    assert {:error, stale} = Recovery.guard(target_config, "reset", ctx.dump)
    assert stale =~ "has routing writes after"
    assert {:error, missing} = Recovery.guard(target_config, "reset", ctx.dump <> ".absent")
    assert missing =~ "no snapshot"

    # Still there: nothing was dropped.
    assert Recovery.with_database(ctx.target, fn -> Repo.aggregate(Page, :count) end) > 0
    assert Repo.aggregate(PublicPath, :count) > 0
  end
end
