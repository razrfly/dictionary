defmodule DevilsDictionary.Routing.MigrationCheckTest do
  @moduledoc """
  `MigrationCheck` on real migrations, over disposable databases: a copy
  holding corpus rows and an empty reference are both migrated from the
  development corpus's version, `20260924222346`, across

    * the pinned routing-only boundary, `20260926193256`, and
    * current main, which adds #206's curation schema after routing.

  The copy passes exactly when it adds what the reference adds and keeps what
  it had; an extra object, a changed row or a reference that started
  elsewhere fails.
  """
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Registry
  alias DevilsDictionary.Routing.{MigrationCheck, Recovery}

  @moduletag :unboxed
  @moduletag :capture_log
  @moduletag timeout: 600_000

  @corpus_version 20_260_924_222_346
  @routing_version 20_260_926_193_256

  setup do
    unique = System.unique_integer([:positive])
    base = Repo.config()[:database]
    db = Map.new(~w(copy reference), &{&1, "#{base}_migcheck_#{unique}_#{&1}"})

    for {_tag, name} <- db do
      :ok = Ecto.Adapters.Postgres.storage_up(Keyword.put(Repo.config(), :database, name))
    end

    on_exit(fn ->
      for {_tag, name} <- db,
          do: Ecto.Adapters.Postgres.storage_down(Keyword.put(Repo.config(), :database, name))
    end)

    migrate!(db["copy"], @corpus_version)
    migrate!(db["reference"], @corpus_version)

    # The copy holds corpus rows; the reference holds none.
    Recovery.with_database(db["copy"], fn ->
      {:ok, _} = Registry.create_lexeme(%{lemma: "oyster", part_of_speech: "noun"})
      {:ok, _} = Registry.create_lexeme(%{lemma: "cockle", part_of_speech: "noun"})
    end)

    %{
      db: db,
      copy_before: MigrationCheck.capture(db["copy"]),
      ref_before: MigrationCheck.capture(db["reference"])
    }
  end

  defp migrate!(database, to) do
    Recovery.with_database(database, fn ->
      opts =
        [dynamic_repo: Repo.get_dynamic_repo(), log: false] ++
          if(to, do: [to: to], else: [all: true])

      Ecto.Migrator.run(Repo, Ecto.Migrator.migrations_path(Repo), :up, opts)
    end)
  end

  test "the pinned routing-only boundary adds exactly the routing schema", ctx do
    assert ctx.copy_before.routing == :absent

    migrate!(ctx.db["copy"], @routing_version)
    migrate!(ctx.db["reference"], @routing_version)

    report =
      MigrationCheck.compare(
        ctx.copy_before,
        MigrationCheck.capture(ctx.db["copy"]),
        ctx.ref_before,
        MigrationCheck.capture(ctx.db["reference"])
      )

    assert report["pass"], inspect(report, pretty: true)
    assert report["migrations_added"] == [@routing_version]
    assert report["tables_added"] == Enum.sort(Recovery.routing_tables())
    assert report["routing_after"] == ":present"
    assert report["pre_existing_rows"] > 0
  end

  test "current main adds routing and then curation, and nothing else", ctx do
    migrate!(ctx.db["copy"], nil)
    migrate!(ctx.db["reference"], nil)
    now = MigrationCheck.capture(ctx.db["copy"])
    ref_after = MigrationCheck.capture(ctx.db["reference"])

    report = MigrationCheck.compare(ctx.copy_before, now, ctx.ref_before, ref_after)
    assert report["pass"], inspect(report, pretty: true)
    assert hd(report["migrations_added"]) == @routing_version
    assert length(report["migrations_added"]) > 1
    assert "editorial_compositions" in report["tables_added"]
    assert Enum.all?(Recovery.routing_tables(), &(&1 in report["tables_added"]))

    # Anything the reference did not add is a difference, not an expected
    # addition: an index on a table the corpus already had…
    Recovery.with_database(ctx.db["copy"], fn ->
      Repo.query!("CREATE INDEX migcheck_extra_index ON lexemes (lemma)")
    end)

    extra =
      MigrationCheck.compare(
        ctx.copy_before,
        MigrationCheck.capture(ctx.db["copy"]),
        ctx.ref_before,
        ref_after
      )

    refute extra["pass"]
    assert [row] = extra["differences_from_the_reference_delta"]["schema_added"]["copy_only"]
    assert row =~ "migcheck_extra_index"

    # …and a changed row in one.
    Recovery.with_database(ctx.db["copy"], fn ->
      Repo.query!("DROP INDEX migcheck_extra_index")
      Repo.query!("UPDATE lexemes SET lemma = 'huitre' WHERE lemma = 'oyster'")
    end)

    changed =
      MigrationCheck.compare(
        ctx.copy_before,
        MigrationCheck.capture(ctx.db["copy"]),
        ctx.ref_before,
        ref_after
      )

    refute changed["pass"]
    assert changed["pre_existing_tables_changed"] == ["lexemes"]
    assert changed["differences_from_the_reference_delta"] == %{}
  end

  test "a reference that started elsewhere proves nothing", ctx do
    migrate!(ctx.db["copy"], @routing_version)
    migrate!(ctx.db["reference"], @routing_version)
    now = MigrationCheck.capture(ctx.db["copy"])
    ref_after = MigrationCheck.capture(ctx.db["reference"])

    # The reference's delta measured from the routing boundary is empty; the
    # copy's is not, and the starts differ.
    report = MigrationCheck.compare(ctx.copy_before, now, ref_after, ref_after)
    refute report["pass"]
    refute report["reference_starts_where_the_copy_started"]

    # And a copy that added no migration is not a migration.
    idle = MigrationCheck.compare(now, now, ref_after, ref_after)
    refute idle["pass"]
  end
end
