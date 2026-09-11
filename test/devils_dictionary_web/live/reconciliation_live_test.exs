defmodule DevilsDictionaryWeb.ReconciliationLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: true

  alias DevilsDictionary.Sources.ReconciliationCase
  alias DevilsDictionary.{Claims, Registry, Repo}

  setup %{conn: conn} do
    DevilsDictionary.Fixtures.seed_catalog!()

    {:ok, input} = Registry.create_person(%{preferred_label: "Ambiguous person"})
    {:ok, output_a} = Registry.create_person(%{preferred_label: "Person A"})
    {:ok, output_b} = Registry.create_person(%{preferred_label: "Person B"})
    {:ok, author} = Registry.create_person(%{preferred_label: "Author"})
    {:ok, work} = Registry.create_work(%{preferred_label: "Work"})

    {:ok, claim} =
      Claims.assert(work.object_id, "authored_by", author.object_id, %{
        context_object_id: input.object_id
      })

    {:ok, _} =
      Registry.split(input.object_id, [output_a.object_id, output_b.object_id],
        reason: "two documented identities"
      )

    kase = Repo.get_by!(ReconciliationCase, assertion_id: claim.id)

    %{
      conn: conn,
      kase: kase,
      output_a: output_a,
      output_b: output_b,
      claim: claim
    }
  end

  test "ordinary and internal-contributor accounts cannot reach the queue", %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    _ = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/reconciliation")
    assert flash["error"] =~ "Reviewer"
  end

  test "a reviewer sees candidates; revocation blocks a stale socket; mapping revises history",
       ctx do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
    reviewer = Repo.update!(Ecto.Changeset.change(user, reviewer: true))
    {:ok, view, _html} = live(conn, ~p"/reconciliation")

    assert has_element?(view, "#reconciliation-form-#{ctx.kase.id}")
    assert has_element?(view, "option[value='#{ctx.output_a.object_id}']")

    Repo.update!(Ecto.Changeset.change(reviewer, reviewer: false))

    view
    |> form("#reconciliation-form-#{ctx.kase.id}", %{
      "replacement_object_id" => ctx.output_a.object_id,
      "reason" => "stale session attempt"
    })
    |> render_submit(%{"decision" => "map"})

    assert Repo.get!(ReconciliationCase, ctx.kase.id).status == :open

    reviewer = Repo.get!(DevilsDictionary.Accounts.User, reviewer.id)
    reviewer = Repo.update!(Ecto.Changeset.change(reviewer, reviewer: true))
    {:ok, fresh, _html} = live(log_in_user(build_conn(), reviewer), ~p"/reconciliation")

    fresh
    |> form("#reconciliation-form-#{ctx.kase.id}", %{
      "replacement_object_id" => ctx.output_a.object_id,
      "reason" => "the evidence identifies Person A"
    })
    |> render_submit(%{"decision" => "map"})

    assert Repo.get!(ReconciliationCase, ctx.kase.id).status == :resolved
    assert Claims.current_revision(ctx.claim.id).context_object_id == ctx.output_a.object_id
    assert length(Claims.history(ctx.claim.id)) == 2
    refute has_element?(fresh, "#reconciliation-form-#{ctx.kase.id}")
  end
end
