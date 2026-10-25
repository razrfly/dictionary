defmodule DevilsDictionary.Curation.RefreshRaceTest do
  @moduledoc """
  One race test per #259 §5 contract (tests 16–18 and 20–22): each
  interleaving is fixed by calling the worker's steps (`Refresh.claim/2`,
  `Refresh.inputs/2`, `Refresh.complete/3`) around the interfering write, in
  order, with no sleep. The two that need real concurrent transactions,
  initialisation under the composition lock and concurrent admissions (7
  and 19), are `RefreshConcurrencyTest`, on committed connections.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, key: 1]

  alias DevilsDictionary.Curation.{Configurations, Refresh, RefreshState}
  alias DevilsDictionary.Repo

  setup ctx do
    world = love_world!(ctx)
    composition = provision!(world)
    published = publish!(world, composition)
    Map.merge(world, %{composition: composition, published: published})
  end

  defp claimed!(composition) do
    row = row!(composition)
    {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
    claim
  end

  defp johnson_only(ctx),
    do: [ctx.johnson |> content_spec(ctx.love) |> Map.put(:note, %{text: "Johnson alone."})]

  test "16: the published parent is captured at admission, not at the worker's claim", ctx do
    assert {:ok, :admitted} = visit!()

    # A publication after admission and before the worker starts.
    %{version: newer} =
      publish!(ctx, ctx.composition, ctx.published.version.id, highlights: johnson_only(ctx))

    claim = claimed!(ctx.composition)
    assert row!(ctx.composition).admitted_parent_version_id == ctx.published.version.id

    {:ok, row} = Refresh.check(claim, "love")
    assert row.admitted_parent_version_id == ctx.published.version.id
    assert row.superseded_on_arrival
    assert Repo.reload!(ctx.composition).current_published_version_id == newer.id
  end

  test "17 and 18: a change during a run stays pending, and its date outlives the next check",
       ctx do
    visit!()
    claim = claimed!(ctx.composition)
    inputs = Refresh.inputs(claim, "love")

    # The change lands after the worker read its inputs.
    assert 1 = Refresh.mark_dirty([ctx.composition.id], "claim_reviewed")
    changed_at = row!(ctx.composition).inputs_last_changed_at

    {:ok, completed} = Refresh.complete(claim, inputs)
    assert completed.last_completed_at
    assert %DateTime{} = completed.dirty_at
    assert completed.dirty_reason == "claim_reviewed"

    # 17: the next visit admits one run for it.
    assert {:ok, :admitted} = visit!()
    assert {:ok, :in_flight} = visit!()
    drain!()

    # 18: that run saw the change and cleared it; the history stays.
    row = row!(ctx.composition)
    assert is_nil(row.dirty_at)
    assert row.inputs_last_changed_at == changed_at
    assert row.inputs_last_changed_reason == "claim_reviewed"
  end

  test "20: an expired lease is recovered with its generation and a new token, at most three times",
       ctx do
    visit!()
    lost = claimed!(ctx.composition)
    inputs = Refresh.inputs(lost, "love")
    expire = fn -> ctx.composition |> row!() |> set!(lease_expires_at: ago(1)) end

    expire.()
    assert {:ok, :recovered} = visit!()
    recovered = row!(ctx.composition)
    assert recovered.state == :queued
    assert recovered.refresh_generation == lost.generation
    assert recovered.lease_token > lost.token
    assert recovered.lease_attempts == 2

    # One job waits for the row, on its generation (the lost worker's own job
    # had not started here, so it took the recovery's arguments).
    assert [%{args: %{"generation" => generation}}] =
             Enum.filter(curation_jobs(), &(&1.state == "available"))

    assert generation == lost.generation

    # The lost worker comes back: refused, nothing written.
    assert {:error, :lease_lost} = Refresh.complete(lost, inputs)
    assert row!(ctx.composition) == recovered

    expire.()
    assert {:ok, :recovered} = visit!()
    assert row!(ctx.composition).lease_attempts == 3

    # The third expiry defers with backoff and keeps the generation.
    expire.()
    assert {:ok, :deferred} = visit!()
    deferred = row!(ctx.composition)
    assert deferred.state == :deferred
    assert deferred.refresh_generation == lost.generation
    assert deferred.failures == 1
    assert DateTime.compare(deferred.next_retry_at, DateTime.utc_now()) == :gt
    assert is_nil(deferred.last_completed_at)
  end

  test "21: a withdrawal during a run refuses its completion", ctx do
    visit!()
    claim = claimed!(ctx.composition)
    inputs = Refresh.inputs(claim, "love")

    withdraw!(ctx, ctx.composition)
    suppressed = row!(ctx.composition)
    assert suppressed.state == :suppressed

    assert {:error, :lease_lost} = Refresh.complete(claim, inputs)
    assert {:error, :lease_lost} = Refresh.fail(claim, "late")
    assert row!(ctx.composition) == suppressed
    assert is_nil(suppressed.last_completed_at)
  end

  test "22: a configuration change during a run refuses its completion and releases the run",
       ctx do
    visit!()
    claim = claimed!(ctx.composition)
    inputs = Refresh.inputs(claim, "love")

    {:ok, newer} =
      Configurations.create_version(ctx.reviewer, ctx.configuration.id, %{
        reason: "#259 test: a second version",
        max_highlights: 2
      })

    {:ok, _} =
      Configurations.activate(ctx.reviewer, ctx.configuration.id, newer.id,
        reason: "#259 test",
        idempotency_key: key("activate"),
        expected: ctx.configuration_version.id
      )

    assert {:error, :configuration_changed} = Refresh.complete(claim, inputs)

    old = Repo.get!(RefreshState, claim.row_id)
    assert old.state == :idle
    assert is_nil(old.last_completed_at)
    assert old.configuration_version_id == ctx.configuration_version.id

    # The next visit admits under the new version, in a row of its own.
    assert {:ok, :admitted} = visit!()
    current = row!(ctx.composition)
    assert current.configuration_version_id == newer.id
    assert current.id != old.id
    assert current.state == :queued
  end

  test "a lost worker's late failure after a recovery is refused too", ctx do
    visit!()
    lost = claimed!(ctx.composition)
    ctx.composition |> row!() |> set!(lease_expires_at: ago(1))
    {:ok, :recovered} = visit!()
    recovered = row!(ctx.composition)

    assert {:error, :lease_lost} = Refresh.fail(lost, "late")
    assert row!(ctx.composition) == recovered
  end
end
