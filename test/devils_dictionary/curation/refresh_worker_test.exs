defmodule DevilsDictionary.Curation.RefreshWorkerTest do
  @moduledoc """
  The worker (#259 §6, tests 10–15): a model-free check that completes as
  unchanged or needs-editor, backs off on failure, and writes nothing once
  it has lost its fence. The published pointer never moves.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2]

  alias DevilsDictionary.Curation.{Composition, CompositionPublication, Refresh}
  alias DevilsDictionary.{Registry, Repo}

  setup ctx do
    world = love_world!(ctx)
    composition = provision!(world)
    published = publish!(world, composition)
    Map.merge(world, %{composition: composition, published: published})
  end

  defp pointer(composition), do: Repo.reload!(composition).current_published_version_id
  defp receipts, do: Repo.aggregate(CompositionPublication, :count)

  defp claimed!(composition) do
    row = row!(composition)
    {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
    claim
  end

  test "10: an unchanged check completes, sets its window and touches no publication", ctx do
    before = {pointer(ctx.composition), receipts()}
    visit!()
    started = DateTime.utc_now()

    assert %{success: 1, failure: 0} = drain!()

    row = row!(ctx.composition)
    assert row.state == :idle
    assert row.last_outcome == :unchanged
    assert row.last_outcome_reason == "accepted"
    assert DateTime.compare(row.last_completed_at, started) != :lt

    assert DateTime.diff(row.refresh_after, row.last_completed_at) == Refresh.window_seconds()
    assert String.starts_with?(row.input_fingerprint, Refresh.fingerprint_version() <> ":")
    assert is_nil(row.inputs_last_changed_at)
    assert {pointer(ctx.composition), receipts()} == before

    # No model was asked: no attempt and no ledger entry exist.
    assert Repo.aggregate("inference_attempts", :count) == 0
    assert Repo.aggregate("inference_ledger_entries", :count) == 0
  end

  test "11: a changed fingerprint completes as needs-editor, stores it and records the change",
       ctx do
    visit!()
    drain!()
    row = row!(ctx.composition)

    # An input changed that no trigger reported: the check finds it.
    set!(row,
      input_fingerprint: Refresh.fingerprint_version() <> ":something-else",
      dirty_at: DateTime.utc_now(),
      dirty_reason: "item_withheld"
    )

    before = {pointer(ctx.composition), receipts()}
    visit!()
    drain!()

    row = row!(ctx.composition)
    assert row.last_outcome == :needs_editor
    assert row.last_outcome_reason == "inputs_changed"
    assert row.input_fingerprint != Refresh.fingerprint_version() <> ":something-else"
    assert %DateTime{} = row.inputs_last_changed_at
    assert row.inputs_last_changed_reason == "inputs_changed"
    assert is_nil(row.dirty_at)
    assert {pointer(ctx.composition), receipts()} == before
  end

  test "11b: a reported change keeps its trigger's date and reason", ctx do
    visit!()
    drain!()

    current = Registry.current_sense_revision(ctx.profound.object_id)

    {:ok, _} =
      Registry.add_sense_revision(ctx.profound.object_id, %{
        gloss: current.gloss,
        position: current.position,
        examples: current.examples
      })

    marked = row!(ctx.composition)
    assert marked.inputs_last_changed_reason == "revision_superseded"

    visit!()
    drain!()

    row = row!(ctx.composition)
    assert row.last_outcome == :needs_editor
    assert row.inputs_last_changed_at == marked.inputs_last_changed_at
    assert row.inputs_last_changed_reason == "revision_superseded"
  end

  test "12: a periodic run completes without a model, as needs-editor, and resets the window",
       ctx do
    visit!()
    drain!()
    first = row!(ctx.composition)
    set!(first, refresh_after: ago(1))

    visit!()
    drain!()

    row = row!(ctx.composition)
    assert row.last_outcome == :needs_editor
    assert row.last_outcome_reason == "due"
    assert DateTime.compare(row.refresh_after, DateTime.utc_now()) == :gt
    assert row.refresh_generation == first.refresh_generation + 1
    assert Repo.aggregate("inference_attempts", :count) == 0
  end

  test "13: a failure defers, keeps the last completion, doubles its backoff and retries the generation",
       ctx do
    visit!()
    drain!()
    completed = row!(ctx.composition)
    set!(completed, refresh_after: ago(1))
    visit!()

    # Reading the inputs raises (a slug that is not text stands for any
    # failure there): the run is deferred under its own fence.
    claim = claimed!(ctx.composition)
    assert {:ok, first} = Refresh.check(claim, 404)
    assert first.state == :deferred
    assert first.failures == 1
    assert first.last_completed_at == completed.last_completed_at
    assert is_binary(first.last_error)
    first_wait = DateTime.diff(first.next_retry_at, DateTime.utc_now())
    assert first_wait in 50..70

    # After the backoff the next visit retries the same generation.
    set!(first, next_retry_at: ago(1))
    assert {:ok, :admitted} = visit!()
    retried = row!(ctx.composition)
    assert retried.refresh_generation == first.refresh_generation

    {:ok, second} = Refresh.fail(claimed!(ctx.composition), "again", jitter: & &1)
    assert second.failures == 2
    assert DateTime.diff(second.next_retry_at, DateTime.utc_now()) in 115..120
    assert second.last_completed_at == completed.last_completed_at
    # The cap is `backoff_seconds/2`'s, tested in `RefreshTest`.
  end

  describe "14: a lost fence writes nothing" do
    test "a job on a stale generation is cancelled", ctx do
      visit!()
      row = row!(ctx.composition)
      set!(row, refresh_generation: row.refresh_generation + 1)

      assert %{cancelled: 1, success: 0} = drain!()
      after_row = row!(ctx.composition)
      assert after_row.state == :queued
      assert is_nil(after_row.last_completed_at)
      assert {:error, :stale_generation} = Refresh.claim(row.id, row.refresh_generation)
    end

    test "a worker past its lease writes nothing", ctx do
      visit!()
      claim = claimed!(ctx.composition)
      inputs = Refresh.inputs(claim, "love")
      expired = set!(row!(ctx.composition), lease_expires_at: ago(1))

      assert {:error, :lease_lost} = Refresh.complete(claim, inputs)
      assert {:error, :lease_lost} = Refresh.fail(claim, "late")
      assert row!(ctx.composition) == expired
    end
  end

  test "15: a publication between admission and completion is superseded on arrival", ctx do
    visit!()
    claim = claimed!(ctx.composition)

    johnson_only = [
      ctx.johnson |> content_spec(ctx.love) |> Map.put(:note, %{text: "Johnson alone."})
    ]

    %{version: newer} =
      publish!(ctx, ctx.composition, ctx.published.version.id, highlights: johnson_only)

    {:ok, row} = Refresh.check(claim, "love")

    assert row.superseded_on_arrival
    assert row.admitted_parent_version_id == ctx.published.version.id
    assert pointer(ctx.composition) == newer.id
    assert Repo.get!(Composition, ctx.composition.id).current_published_version_id == newer.id
  end
end
