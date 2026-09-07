defmodule DevilsDictionary.HealthScoreMobileTest do
  @moduledoc """
  Scorecard row **U4** — the mobile pass (#71 §8, U3).

  Its own file, and `async: false`, because the falsifiability test moves a
  file on disk: the row reads `docs/mobile/` and every other test in the suite
  computes the same scorecard.

  U4 is the one row no query can answer. A page either scrolls sideways on a
  phone or it does not, and the only honest instrument is a viewport and a pair
  of eyes — so it is graded the way **E3** is, as a dated attestation whose
  evidence is checked in. What is tested here is that the evidence is load
  bearing: delete a screenshot and the row goes red.
  """

  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Health.Score

  setup do
    Fixtures.seed_catalog!()
    :ok
  end

  defp u4, do: Score.rows(skip_parity: true) |> Enum.find(&(&1.id == "U4"))

  test "it passes as a dated attestation over the pages it names" do
    row = u4()

    assert row.status == :pass
    assert row.session == "U3"
    assert row.actual =~ "2026-09-07"
    assert row.actual =~ "375 px"
    assert row.detail =~ "docs/mobile/README.md"
    assert File.exists?("docs/mobile/README.md")

    for page <- ~w(home browse health), do: assert(row.actual =~ page)
  end

  test "the screenshots it attests to are in the repo" do
    shots = Path.wildcard("docs/mobile/375-*.jpg")

    assert length(shots) >= 7
    assert Enum.all?(shots, &(File.stat!(&1).size > 0))
  end

  test "it fails when a screenshot goes missing, which is what makes it a measurement" do
    shot = "docs/mobile/375-home.jpg"
    hidden = shot <> ".hidden"

    try do
      File.rename!(shot, hidden)
      row = u4()

      assert row.status == :fail
      assert row.actual =~ "evidence missing"
      assert row.actual =~ "375-home.jpg"
    after
      File.rename!(hidden, shot)
    end

    assert u4().status == :pass
  end
end
