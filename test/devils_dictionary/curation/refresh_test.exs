defmodule DevilsDictionary.Curation.RefreshTest do
  @moduledoc """
  Admission and the dirty triggers (#259 §6, tests 1–6, 8 and 9): a visit to
  a pilot On page admits at most one model-free check, and only when the
  composition was never checked, an input changed, its window passed or a
  failed check's backoff ran out.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.WordFixtures, only: [word!: 4, sense!: 4]

  alias DevilsDictionary.Claims.AssertionRevision

  alias DevilsDictionary.Curation.{
    CompositionReview,
    CompositionVersion,
    Configurations,
    Refresh,
    RefreshState,
    Reviews
  }

  import DevilsDictionary.CurationFixtures, only: [key: 1]
  alias DevilsDictionary.{ExemplarFixtures, Registry, Repo}

  defp clean?(composition), do: is_nil(row!(composition).dirty_at)

  setup ctx do
    world = love_world!(ctx)
    composition = provision!(world)
    published = publish!(world, composition)
    Map.merge(world, %{composition: composition, published: published})
  end

  test "1: a fresh visit to a published, assessed composition admits nothing", ctx do
    assert {:ok, :admitted} = visit!()
    drain!()
    assert %{state: :idle, last_outcome: :unchanged} = row!(ctx.composition)

    assert {:ok, :fresh} = visit!()
    assert {:ok, :fresh} = visit!()
    assert length(curation_jobs()) == 1
  end

  test "2: a first visit admits one run; a second while it is queued admits none", ctx do
    assert Repo.aggregate(RefreshState, :count) == 0
    assert {:ok, :admitted} = visit!()

    row = row!(ctx.composition)
    assert row.state == :queued
    assert row.refresh_generation == 1
    assert row.configuration_version_id == ctx.configuration_version.id
    assert row.admitted_parent_version_id == ctx.published.version.id

    assert {:ok, :in_flight} = visit!()

    assert [%{args: %{"refresh_state_id" => id, "generation" => 1, "slug" => "love"}}] =
             curation_jobs()

    assert id == row.id
  end

  test "3: a passed window admits one periodic run; a pending change admits one with its reason",
       ctx do
    visit!()
    drain!()

    ctx.composition |> row!() |> set!(refresh_after: ago(1))
    assert {:ok, :admitted} = visit!()
    assert {:ok, :in_flight} = visit!()
    drain!()
    assert %{last_outcome: :needs_editor, last_outcome_reason: "due"} = row!(ctx.composition)

    assert 1 = Refresh.mark_dirty([ctx.composition.id], "claim_reviewed")
    assert %{dirty_reason: "claim_reviewed", dirty_at: %DateTime{}} = row!(ctx.composition)
    assert {:ok, :admitted} = visit!()
    assert length(curation_jobs()) == 3
  end

  test "4: a withdrawn composition admits nothing; re-opened, it admits one, reason reopened",
       ctx do
    visit!()
    drain!()
    withdraw!(ctx, ctx.composition)

    assert %{state: :suppressed} = row!(ctx.composition)
    assert {:ok, :suppressed} = visit!()
    assert length(curation_jobs()) == 1

    assert 1 = Refresh.reopen(ctx.composition.id)
    assert %{state: :idle, dirty_reason: "reopened"} = row!(ctx.composition)
    assert {:ok, :admitted} = visit!()
    assert length(curation_jobs()) == 2
  end

  test "5: a backoff still running admits nothing", ctx do
    visit!()
    row = row!(ctx.composition)
    {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
    {:ok, deferred} = Refresh.fail(claim, "test failure", jitter: & &1)

    assert deferred.state == :deferred
    assert DateTime.compare(deferred.next_retry_at, DateTime.utc_now()) == :gt
    assert {:ok, :backoff} = visit!()
    assert length(curation_jobs()) == 1
  end

  test "6: an unchanged check and an editor-needed check reserve no review unit and no inference time",
       ctx do
    counts = fn ->
      %{
        versions: Repo.aggregate(CompositionVersion, :count),
        reviews: Repo.aggregate(CompositionReview, :count),
        claims: Repo.aggregate(AssertionRevision, :count),
        attempts: Repo.aggregate("inference_attempts", :count),
        ledger: Repo.aggregate("inference_ledger_entries", :count)
      }
    end

    before = counts.()

    visit!()
    drain!()
    assert %{last_outcome: :unchanged} = row!(ctx.composition)

    ctx.composition |> row!() |> set!(refresh_after: ago(1))
    visit!()
    drain!()
    assert %{last_outcome: :needs_editor} = row!(ctx.composition)

    assert counts.() == before
  end

  describe "8: each trigger marks exactly the compositions that cite the change or gained a candidate" do
    setup ctx do
      hope = word!(ctx, "hope", ~w(wiktionary), scope: nil)

      sense!(ctx, hope, "wiktionary",
        gloss: "a fixture hope sense",
        examples: [%{"type" => "quotation", "text" => "fixture hope words", "ref" => "ref"}]
      )

      other = provision!(ctx, [hope])

      # Both clocks exist and are clean.
      for slug <- ["love", "hope"], do: visit!(slug)
      drain!()

      Map.put(ctx, :other, other)
    end

    test "a cited sense revision superseded", ctx do
      assert clean?(ctx.composition) and clean?(ctx.other)
      current = Registry.current_sense_revision(ctx.profound.object_id)

      {:ok, _} =
        Registry.add_sense_revision(ctx.profound.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples: current.examples
        })

      assert %{dirty_reason: "revision_superseded"} = row!(ctx.composition)
      assert clean?(ctx.other)
    end

    test "a new revision of an uncited sense in the scope is a new candidate", ctx do
      current = Registry.current_sense_revision(ctx.benevolent.object_id)

      {:ok, _} =
        Registry.add_sense_revision(ctx.benevolent.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples: [%{"type" => "quotation", "text" => "a new line", "ref" => "ref"}]
        })

      assert %{dirty_reason: "candidate_added"} = row!(ctx.composition)
      assert clean?(ctx.other)
    end

    test "a cited content revision superseded", ctx do
      {:ok, _} =
        Registry.add_content_revision(ctx.johnson.object_id, %{
          body: "1. The passion between the sexes. (A newer reading.)",
          body_format: :markdown,
          headword: "LOVE"
        })

      assert %{dirty_reason: "revision_superseded"} = row!(ctx.composition)
      assert clean?(ctx.other)
    end

    test "a claim reviewed about a sense of the scope", ctx do
      person = ExemplarFixtures.person!("Fixture Exemplar")
      claim = ExemplarFixtures.nominate!(ctx.author, person, ctx.benevolent)
      assert clean?(ctx.composition)

      ExemplarFixtures.decide!(ctx.reviewer, claim)

      assert %{dirty_reason: "claim_reviewed", inputs_last_changed_reason: "claim_reviewed"} =
               row!(ctx.composition)

      assert clean?(ctx.other)
    end
  end

  describe "9: scope" do
    test "a never-curated pilot page has no refresh identity and admits nothing", ctx do
      word!(ctx, "hope", ~w(wiktionary), scope: nil)

      assert :skip = visit!("hope")
      assert Repo.aggregate(RefreshState, :count) == 0
      assert curation_jobs() == []
    end

    test "a page off the allowlist admits nothing, even with a published composition" do
      previous = Application.fetch_env(:devils_dictionary, :curation_pilot_pages)
      Application.put_env(:devils_dictionary, :curation_pilot_pages, ~w(war))

      on_exit(fn ->
        case previous do
          {:ok, pages} -> Application.put_env(:devils_dictionary, :curation_pilot_pages, pages)
          :error -> Application.delete_env(:devils_dictionary, :curation_pilot_pages)
        end
      end)

      assert :skip = visit!("love")
      assert curation_jobs() == []
    end
  end

  test "a read-time withholding the last check did not see is an input change, noted once", ctx do
    visit!()
    drain!()
    assert clean?(ctx.composition)

    # The cited quotation's sense moves on: the page withholds the highlight.
    # The trigger already marks it; clear that, to see the visit's own check.
    current = Registry.current_sense_revision(ctx.profound.object_id)

    {:ok, _} =
      Registry.add_sense_revision(ctx.profound.object_id, %{
        gloss: current.gloss,
        position: current.position,
        examples: current.examples
      })

    ctx.composition |> row!() |> set!(dirty_at: nil, dirty_reason: nil)
    seq = row!(ctx.composition).dirty_seq

    assert {:ok, :admitted} = visit!()
    row = row!(ctx.composition)
    assert row.dirty_reason == "item_withheld"
    assert row.dirty_seq == seq + 1

    # A second visit while queued does not mark it again.
    assert {:ok, :in_flight} = visit!()
    assert row!(ctx.composition).dirty_seq == seq + 1
  end

  test "a version withheld as a whole is an input change, and the check says an editor is needed",
       ctx do
    visit!()
    drain!()
    assert %{last_outcome: :unchanged} = row!(ctx.composition)

    # The acceptance is withdrawn: the reader withholds the whole version and
    # the page shows no opening.
    {:ok, _} =
      Reviews.decide(ctx.reviewer, ctx.published.version.id, :rejected,
        reason: "#259 test: approval withdrawn",
        idempotency_key: key("reject")
      )

    assert {:ok, :admitted} = visit!()
    assert %{dirty_reason: "item_withheld"} = row!(ctx.composition)
    drain!()

    assert %{last_outcome: :needs_editor, last_outcome_reason: "inputs_changed"} =
             row!(ctx.composition)
  end

  test "a withdrawal before any check creates the row suppressed, and a new configuration version's row inherits it",
       ctx do
    withdraw!(ctx, ctx.composition)
    assert [%RefreshState{state: :suppressed}] = Repo.all(RefreshState)
    assert {:ok, :suppressed} = visit!()

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

    assert {:ok, :suppressed} = Refresh.admit(ctx.composition.id, slug: "love")

    assert [:suppressed, :suppressed] =
             RefreshState |> Repo.all() |> Enum.map(& &1.state)

    assert curation_jobs() == []
  end

  test "the backoff doubles from a minute and stops at six hours" do
    identity = & &1
    assert Refresh.backoff_seconds(1, identity) == 60
    assert Refresh.backoff_seconds(2, identity) == 120
    assert Refresh.backoff_seconds(3, identity) == 240
    assert Refresh.backoff_seconds(30, identity) == 6 * 3600
    assert Refresh.backoff_seconds(30, &(&1 * 1.1)) == 6 * 3600

    for _ <- 1..20 do
      assert Refresh.backoff_seconds(2) in 108..132
    end
  end
end
