defmodule DevilsDictionary.HealthScoreTest do
  @moduledoc """
  The scorecard as a table: every row of #69 §7 present exactly once, graded
  where a query can grade it and honest about where it cannot.

  The numbers themselves are tested where they are computed (`HealthTest`,
  `HealthConceptsTest`, `HealthCoverageTest`); what is tested here is the
  assembly — that no row is missing, none is counted twice, and a row belonging
  to a session that has not run says so instead of reading as a pass.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Health.Score

  # Every row id in #69 §7, in the order the spec lists them.
  @spec_rows ~w(A1 A2 A3 A4 A5 A6 A7 A8 A9 A10
                M1 M2 M3 M4
                R1 R2 R3
                L1 L2 L3 L4
                X1 X2 X3
                U1 U2 U3 U4 U5 U6
                E1 E2 E3
                O1 O2 O3 O4)

  setup do
    Fixtures.seed_catalog!()
    # Parity re-runs materialize/1 over every stored record; the assembly is
    # what is under test, not the check.
    %{rows: Score.rows(skip_parity: true)}
  end

  describe "rows/1" do
    test "every row of the spec is present exactly once", %{rows: rows} do
      ids = Enum.map(rows, & &1.id)

      assert ids == @spec_rows
      assert length(Enum.uniq(ids)) == length(ids)
    end

    test "every row carries an actual, a threshold and a status", %{rows: rows} do
      for row <- rows do
        assert is_binary(row.actual) and row.actual != "", "#{row.id} has no actual"
        assert is_binary(row.wants) and row.wants != "", "#{row.id} has no threshold"
        assert row.status in [:pass, :fail, :report, :pending], "#{row.id}: #{row.status}"
        assert is_binary(row.check) and row.check != ""
      end
    end

    test "rows a session has not run are pending, and name the session", %{rows: rows} do
      pending = for r <- rows, r.status == :pending, do: r.id

      # Provenance and the mobile pass are #71's U2 and U3. On an empty database
      # M2 and E2 join them: nothing has been rebuilt and no second scope is
      # built.
      assert "U3" in pending
      assert "U4" in pending
      assert "M2" in pending
      assert "E2" in pending

      # U1a landed, so the four rows it measures are graded rather than
      # pending, even on an empty database where they grade as failures.
      for id <- ~w(R3 X1 U1 U2 U6), do: refute(id in pending, "#{id} should be graded")

      # X2 and U5 became measurable in S4b, E1 and E3 in S5, and R3 X1 U1 U2 U6
      # in U1a. What is left belongs to #71's later sessions and says so.
      for id <- ~w(U3 U4) do
        row = Enum.find(rows, &(&1.id == id))
        assert row.status == :pending, "#{id} should be pending until its session runs"
        assert row.session in ~w(S4 U1 U3), "#{id} should name the session that owns it"
      end
    end

    test "E1 counts migrations rather than describing the source", %{rows: rows} do
      e1 = Enum.find(rows, &(&1.id == "E1"))

      # The sixth source is in the registry and the schema has not moved: the
      # baseline plus Oban, which is what "0 migrations" means literally.
      assert e1.actual =~ "johnson: 1 sources row, 1 module, 1 registry line"
      assert e1.actual =~ "2 migrations"
      assert e1.status == :pass
    end

    test "E2 is pending until a second scope is actually built", %{rows: rows} do
      # The catalog seeds the scope rows from `priv/scopes/*.json`, but seeding
      # a row is not building it: nothing has members on an empty database.
      e2 = Enum.find(rows, &(&1.id == "E2"))

      assert e2.actual == "no scope built"
      assert e2.status == :pending
      assert e2.session == "S5"
    end

    test "E3 is proven by the sketch it kept, not by prose", %{rows: rows} do
      e3 = Enum.find(rows, &(&1.id == "E3"))

      assert e3.status == :pass
      assert e3.detail =~ "docs/sketches/community_layer_migration.exs"
      refute File.exists?("priv/repo/migrations/20260906092918_community_layer_sketch.exs")
    end

    test "U1 counts the routes that exist and names the ones that do not", %{rows: rows} do
      u1 = Enum.find(rows, &(&1.id == "U1"))

      # All six of #69 §6's pages are routed now that U1a added /define/:slug.
      # A route is a fact the router can be asked for, so this reads the route
      # table rather than trusting the prose.
      assert u1.actual =~ "6 / 6 routes"
      assert u1.status == :pass
    end

    test "U5 grades the badges against Health.coverage/2, per source", %{rows: rows} do
      u5 = Enum.find(rows, &(&1.id == "U5"))

      # An empty scope agrees trivially — every source, nothing attested — and
      # that is the point: the row measures agreement, not size.
      sources = length(DevilsDictionary.Sources.Catalog.sources())
      assert u5.actual =~ "#{sources} / #{sources} sources agree with dd.health"
      assert u5.status == :pass
    end

    test "X2 times the search rather than describing it", %{rows: rows} do
      x2 = Enum.find(rows, &(&1.id == "X2"))

      assert x2.actual =~ ~r/p95 \d+ ms over \d+ probes/
      assert x2.wants == "< 150 ms"
      assert x2.status == :pass
    end

    test "a row the spec gives no threshold is reported, not graded", %{rows: rows} do
      assert Enum.find(rows, &(&1.id == "L2")).status == :report
    end

    test "an empty database fails the rows it should fail, rather than passing them", %{
      rows: rows
    } do
      by_id = Map.new(rows, &{&1.id, &1})

      # Nothing is absorbed, so these cannot be green. A scorecard that read
      # 0 / 0 as success would be worse than no scorecard.
      assert by_id["A1"].status == :fail
      assert by_id["A2"].status == :fail
      assert by_id["A3"].status == :fail
      assert by_id["A8"].status == :fail
      # A9 too: there is no sense or entry to link back, and 0 / 0 is reported
      # as 0%, never as a vacuous 100%.
      assert by_id["A9"].status == :fail
    end

    test "O1 passes because this table exists", %{rows: rows} do
      assert Enum.find(rows, &(&1.id == "O1")).status == :pass
    end
  end

  describe "summary/1" do
    test "counts the graded rows apart from the reported and pending ones", %{rows: rows} do
      summary = Score.summary(rows)

      assert summary.total == length(@spec_rows)
      assert summary.graded == summary.passed + summary.failed
      assert summary.total == summary.graded + summary.reported + summary.pending
      assert summary.reported >= 1
      # U3 and U4 (#71's U2 and U3 sessions), plus M1 (skipped), M2, M4 and E2,
      # which an empty database cannot measure. R3, X1, U1, U2 and U6 became
      # graded in U1a; E1 and E3 in S5.
      assert summary.pending >= 5
    end
  end
end
