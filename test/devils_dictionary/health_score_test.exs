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

      # S4 owns the pages; S5 the extensibility proof. On an empty database M2
      # joins them: nothing has been rebuilt yet.
      assert "U1" in pending
      assert "E1" in pending
      assert "M2" in pending

      for id <- ~w(R3 X1 X2 U1 U2 U3 U4 U5 U6 E1 E2 E3) do
        row = Enum.find(rows, &(&1.id == id))
        assert row.status == :pending, "#{id} should be pending until its session runs"
        assert row.session in ~w(S4 S5), "#{id} should name the session that owns it"
      end
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
      assert summary.pending >= 12
    end
  end
end
