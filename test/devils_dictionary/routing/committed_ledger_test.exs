defmodule DevilsDictionary.Routing.CommittedLedgerTest do
  @moduledoc """
  Ledger behaviour that only a real COMMIT settles (ADR 0004 §5): a tombstone
  is not resurrected by allocation — in the code or in the database — while a
  human can still restore it deliberately; and a malformed record in a batch is
  that record's error, not the batch's rollback.

  Every step commits, so the deferred consistency and ledger-chain checks run
  exactly as in production.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{
    Address,
    Classifications,
    Ledger,
    Page,
    Pages,
    PublicPath,
    Resolution,
    Resolver,
    RouteChange
  }

  # A refused COMMIT is logged by Postgrex; it is the expected outcome here.
  @moduletag :unboxed
  @moduletag :capture_log

  @beyond_bigint 9_223_372_036_854_775_808

  setup do
    %{human: human!(), importer: importer!()}
  end

  defp opts(actor, reason \\ "test"), do: [actor_id: actor.id, reason: reason]
  defp resolve(path), do: path |> Address.encode() |> Resolver.resolve()
  defp ledger, do: Repo.all(from c in RouteChange, order_by: c.id)

  # An address a human took down by hand: the page is withdrawn and its only
  # address tombstoned, through honestly ledgered human rows. It is the state
  # in which an automated allocation could otherwise bring the address back.
  defp taken_down!(human) do
    page = live_page!("people", "/people/voltaire", human, :person)
    path = Repo.get!(PublicPath, page.canonical_path_id)
    operation = Ecto.UUID.generate()

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("UPDATE pages SET publication_state = 'withdrawn' WHERE id = $1", [page.id])

        tombstoned =
          Repo.insert!(%RouteChange{
            operation_id: operation,
            sequence: 1,
            operation: :move,
            actor_id: human.id,
            reason: "legal takedown",
            path_id: path.id,
            before_kind: :canonical,
            after_kind: :tombstone,
            before_destination_id: page.id,
            after_destination_id: page.id
          })

        path
        |> Ecto.Changeset.change(kind: :tombstone, last_route_change_id: tombstoned.id)
        |> Repo.update!()

        unpointed =
          Repo.insert!(%RouteChange{
            operation_id: operation,
            sequence: 2,
            operation: :move,
            actor_id: human.id,
            reason: "legal takedown",
            page_id: page.id,
            before_lifecycle: :active,
            after_lifecycle: :active,
            before_canonical_path_id: path.id,
            after_canonical_path_id: nil,
            before_revision_id: page.current_revision_id,
            after_revision_id: page.current_revision_id
          })

        page
        |> Repo.reload!()
        |> Ecto.Changeset.change(canonical_path_id: nil, last_route_change_id: unpointed.id)
        |> Repo.update!()
      end)

    {Repo.get!(Page, page.id), Repo.get!(PublicPath, path.id)}
  end

  describe "a tombstone is a deliberate removal" do
    test "machine allocation refuses it, in the code and in the database, and changes nothing",
         ctx do
      {page, tombstone} = taken_down!(ctx.human)
      history = ledger()

      assert Ledger.allocate(page.id, "/people/voltaire", opts(ctx.importer)) ==
               {:error,
                {:tombstoned, %{path: "/people/voltaire", kind: :tombstone, page_id: page.id}}}

      # The same promotion, written by hand as an importer's allocation.
      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(%RouteChange{
            operation_id: Ecto.UUID.generate(),
            sequence: 1,
            operation: :allocate,
            actor_id: ctx.importer.id,
            reason: "resurrect",
            path_id: tombstone.id,
            before_kind: :tombstone,
            after_kind: :canonical,
            before_destination_id: page.id,
            after_destination_id: page.id
          })
        end

      assert error.constraint == "route_changes_allocate_shape"

      assert ledger() == history
      assert Repo.get!(PublicPath, tombstone.id) == tombstone
      assert Repo.get!(Page, page.id) == page
      assert %Resolution{outcome: :gone} = resolve("/people/voltaire")
    end

    test "a human restores it, on the ledger, and the address answers again", ctx do
      {page, tombstone} = taken_down!(ctx.human)
      history = ledger()

      assert Ledger.restore(page.id, "/people/voltaire", opts(ctx.importer)) ==
               {:error, :human_approval_required}

      assert {:ok, %PublicPath{id: id, kind: :canonical}} =
               Ledger.restore(page.id, "/people/voltaire", opts(ctx.human, "takedown lifted"))

      assert id == tombstone.id
      assert [%{operation: :restore}, %{operation: :restore}] = ledger() -- history
      assert %Page{canonical_path_id: ^id, lifecycle_state: :active} = Repo.get!(Page, page.id)

      published!(page)
      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")
    end

    test "a human can bring back a retired page at one of its addresses", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))
      {:ok, _} = Ledger.retire(page.id, opts(ctx.human, "withdrawn"))

      assert {:error, {:tombstoned, _}} =
               Ledger.allocate(page.id, "/people/arouet", opts(ctx.importer))

      assert {:ok, %PublicPath{kind: :canonical}} =
               Ledger.restore(page.id, "/people/arouet", opts(ctx.human, "reinstated"))

      assert %Resolution{outcome: :canonical} = resolve("/people/arouet")
      # Its other address stays removed until someone restores it too; even a
      # human move onto it is refused, because a tombstone comes back only by
      # restore.
      assert %Resolution{outcome: :gone} = resolve("/people/voltaire")
      assert %Page{lifecycle_state: :active} = Repo.get!(Page, page.id)

      assert {:error, {:tombstoned, _}} =
               Ledger.move(page.id, "/people/voltaire", opts(ctx.human))
    end
  end

  test "a malformed target is one record's error; the batch commits the rest" do
    entity = entity!(:person, "Voltaire")

    assert {:ok, results} =
             Repo.transaction(fn ->
               [
                 Pages.ensure(:subject, nil),
                 Pages.ensure(:subject, Integer.to_string(entity.object_id)),
                 Pages.ensure(:subject, -1),
                 Pages.ensure(:subject, 1.5),
                 Pages.ensure(:subject, @beyond_bigint),
                 Pages.ensure(:homepage, entity.object_id),
                 Pages.ensure(:subject, entity.object_id, "en\n"),
                 Pages.ensure(:subject, entity.object_id)
               ]
             end)

    assert [
             {:error, :target_required},
             {:error, :invalid_target},
             {:error, :invalid_target},
             {:error, :invalid_target},
             {:error, :invalid_target},
             {:error, :invalid_role},
             {:error, %Ecto.Changeset{errors: [locale: _]}},
             {:ok, %Page{id: id}}
           ] = results

    assert %Page{role: :subject} = Repo.get!(Page, id)
  end

  test "every routing writer refuses malformed input without aborting the caller's batch",
       ctx do
    entity = entity!(:person, "Candide")
    classify!(entity.object_id, "people")
    {:ok, page} = Pages.ensure(:subject, entity.object_id)
    decisions = Classifications.history(entity.object_id)
    human = opts(ctx.human)
    author = ctx.human.id

    stale = %{
      status: :mapped,
      family: :people,
      reason: "a philosopher",
      evidence_fingerprint: "not what the reviewer saw"
    }

    assert {:ok, results} =
             Repo.transaction(fn ->
               [
                 Ledger.allocate(nil, "/people/candide", human),
                 Ledger.allocate(Integer.to_string(page.id), "/people/candide", human),
                 Ledger.move(@beyond_bigint, "/people/pangloss", human),
                 Ledger.retire(-1, human),
                 Ledger.restore(1.0, "/people/candide", human),
                 Ledger.merge(nil, page.id, human),
                 Ledger.split(page.id, [nil], human),
                 Ledger.split(page.id, :pangloss, human),
                 Pages.add_revision(nil, %{title: "Candide"}, [], author),
                 Pages.add_revision(page.id, %{title: 1759}, [], author),
                 Pages.add_revision(page.id, %{body_format: :html}, [], author),
                 Pages.add_revision(page.id, %{reviewer_actor_id: @beyond_bigint}, [], author),
                 Pages.add_revision(page.id, %{}, ["not a membership"], author),
                 Pages.add_revision(
                   page.id,
                   %{},
                   [%{relationship: :discusses_subject, target_object_id: @beyond_bigint}],
                   author
                 ),
                 Pages.add_revision(page.id, %{}, [], @beyond_bigint),
                 Pages.add_revision(999_999_999, %{}, [], author),
                 Classifications.override(nil, stale, author),
                 Classifications.override(entity.object_id, stale, author),
                 Classifications.record(%{object_id: "7"}),
                 Classifications.record(evaluate(999_999_999, "Q5")),
                 Resolver.resolve_page(nil).outcome,
                 Resolver.resolve_page(@beyond_bigint).outcome,
                 Resolver.link("7"),
                 Resolver.paths(nil),
                 # The batch's one well-formed record, which must commit.
                 Ledger.allocate(page.id, "/people/candide", opts(ctx.importer))
               ]
             end)

    assert [
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :invalid_page},
             {:error, :successors_required},
             {:error, :invalid_page},
             {:error, :invalid_revision},
             {:error, :invalid_body_format},
             {:error, :invalid_reviewer},
             {:error, :invalid_membership},
             {:error, :membership_target_not_found},
             {:error, :actor_required},
             {:error, :page_not_found},
             {:error, :invalid_object},
             {:error, :stale_evidence},
             {:error, :invalid_object},
             {:error, :object_not_found},
             :missing,
             :missing,
             :error,
             [],
             {:ok, %PublicPath{path: "/people/candide"}}
           ] = results

    # Committed, and nothing a refusal touched changed.
    assert %Page{canonical_path_id: path_id, current_revision_id: nil} = Repo.get!(Page, page.id)
    assert %PublicPath{path: "/people/candide"} = Repo.get!(PublicPath, path_id)
    assert Classifications.history(entity.object_id) == decisions
    assert %Resolution{outcome: :unavailable} = resolve("/people/candide")
  end
end
