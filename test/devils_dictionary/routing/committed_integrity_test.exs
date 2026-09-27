defmodule DevilsDictionary.Routing.CommittedIntegrityTest do
  @moduledoc """
  Raw-SQL attacks on committed routing state, each in its own real
  transaction (ADR 0004 §5).

  The sandboxed `SchemaIntegrityTest` runs setup and attack in one
  transaction, so the setup's own deferred checks fire again at the end and
  can refuse an attack that two separate commits would let through. These
  commit the setup first, as production would, and then attack.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Registry
  alias DevilsDictionary.Routing.{Ledger, Page, PublicPath, RouteChange}

  # A refused COMMIT is logged by Postgrex; it is the expected outcome here.
  @moduletag :unboxed
  @moduletag :capture_log

  setup do
    human = human!()
    page = live_page!("people", "/people/voltaire", human, :person)

    %{
      human: human,
      importer: importer!(),
      page: page,
      path: Repo.get!(PublicPath, page.canonical_path_id)
    }
  end

  # {:refused, message} when the statements or their COMMIT are refused.
  defp attempt(fun) do
    case Repo.transaction(fun) do
      {:ok, _} -> :accepted
      other -> other
    end
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] -> {:refused, Exception.message(error)}
  end

  defp change!(attrs) do
    Repo.insert!(
      struct(
        RouteChange,
        Map.merge(%{operation_id: Ecto.UUID.generate(), sequence: 1, reason: "console"}, attrs)
      )
    )
  end

  defp repoint!(path, kind, destination_id, actor, operation) do
    change =
      change!(%{
        operation: operation,
        actor_id: actor.id,
        path_id: path.id,
        before_kind: path.kind,
        after_kind: kind,
        before_destination_id: path.destination_page_id,
        after_destination_id: destination_id
      })

    path
    |> Ecto.Changeset.change(
      kind: kind,
      destination_page_id: destination_id,
      last_route_change_id: change.id
    )
    |> Repo.update!()
  end

  defp repage!(page, attrs, actor, operation) do
    after_state =
      Map.merge(
        Map.take(page, [:lifecycle_state, :canonical_path_id, :merged_into_page_id]),
        attrs
      )

    change =
      change!(%{
        operation: operation,
        actor_id: actor.id,
        page_id: page.id,
        before_lifecycle: page.lifecycle_state,
        after_lifecycle: after_state.lifecycle_state,
        before_canonical_path_id: page.canonical_path_id,
        after_canonical_path_id: after_state.canonical_path_id,
        before_merged_into_id: page.merged_into_page_id,
        after_merged_into_id: after_state.merged_into_page_id,
        before_revision_id: page.current_revision_id,
        after_revision_id: page.current_revision_id
      })

    page
    |> Ecto.Changeset.change(Map.put(attrs, :last_route_change_id, change.id))
    |> Repo.update!()
  end

  test "calling a retirement an allocation does not make it a machine's to do", ctx do
    assert {:refused, message} =
             attempt(fn ->
               repoint!(ctx.path, :tombstone, ctx.page.id, ctx.importer, :allocate)
             end)

    assert message =~ "route_changes_allocate_shape"
    assert Repo.get!(PublicPath, ctx.path.id).kind == :canonical
  end

  test "a ledgered merge into a page about another identity is refused", ctx do
    unrelated = live_page!("people", "/people/unrelated", ctx.human, :person)

    assert {:refused, message} =
             attempt(fn ->
               repoint!(ctx.path, :alias, unrelated.id, ctx.human, :merge)

               repage!(
                 ctx.page,
                 %{
                   lifecycle_state: :merged,
                   canonical_path_id: nil,
                   merged_into_page_id: unrelated.id
                 },
                 ctx.human,
                 :merge
               )
             end)

    assert message =~ "merged into a page about a different identity"
  end

  test "un-merging a page cannot strand the addresses that reached its survivor", ctx do
    survivor = live_page!("people", "/people/arouet", ctx.human, :person)

    {:ok, _} =
      Registry.merge([ctx.page.target_object_id], survivor.target_object_id, reason: "dup")

    {:ok, _} = Ledger.merge(ctx.page.id, survivor.id, actor_id: ctx.human.id, reason: "dup")

    assert {:refused, message} =
             attempt(fn ->
               merged = Repo.get!(Page, ctx.page.id)

               Repo.query!("UPDATE pages SET publication_state = 'draft' WHERE id = $1", [
                 merged.id
               ])

               repage!(
                 merged,
                 %{lifecycle_state: :active, merged_into_page_id: nil},
                 ctx.human,
                 :move
               )
             end)

    assert message =~ "/people/voltaire) was repurposed"
  end

  test "a split page's successors cannot be swapped outside the ledger", ctx do
    element = live_page!("nature", "/nature/mercury-element", ctx.human)
    planet = live_page!("nature", "/nature/mercury-planet", ctx.human)
    mercury = live_page!("nature", "/nature/mercury", ctx.human)

    {:ok, _} =
      Registry.split(
        mercury.target_object_id,
        [planet.target_object_id, element.target_object_id],
        reason: "fixture"
      )

    {:ok, _} =
      Ledger.split(mercury.id, [planet.id, element.id], actor_id: ctx.human.id, reason: "fixture")

    assert {:refused, message} =
             attempt(fn ->
               Repo.query!("UPDATE pages SET current_revision_id = NULL WHERE id = $1", [
                 mercury.id
               ])
             end)

    assert message =~ "changed its route without a new route change"
  end

  test "a page is a choice among successors only when its identity was split", ctx do
    assert {:refused, message} =
             attempt(fn ->
               repage!(ctx.page, %{lifecycle_state: :split}, ctx.human, :split)
             end)

    assert message =~ "is split but its identity"
  end

  test "a ledger row must be applied, and a rollback must name a real operation", ctx do
    assert {:refused, message} =
             attempt(fn ->
               change!(%{
                 operation: :move,
                 actor_id: ctx.human.id,
                 path_id: ctx.path.id,
                 before_kind: :canonical,
                 after_kind: :alias,
                 before_destination_id: ctx.page.id,
                 after_destination_id: ctx.page.id
               })
             end)

    assert message =~ "was never applied to path"

    assert {:refused, message} =
             attempt(fn ->
               change!(%{
                 operation: :rollback,
                 reverts_operation_id: Ecto.UUID.generate(),
                 actor_id: ctx.human.id,
                 path_id: ctx.path.id,
                 before_kind: :canonical,
                 after_kind: :alias,
                 before_destination_id: ctx.page.id,
                 after_destination_id: ctx.page.id
               })
             end)

    assert message =~ "a rollback reverts an earlier operation"
  end

  # An accident guard: a session that sets the opt-in deliberately can still
  # truncate, which is why production should also withhold TRUNCATE.
  test "routing history is not truncated by accident, even by cascade", _ctx do
    for statement <- [
          "TRUNCATE page_memberships",
          "TRUNCATE route_changes CASCADE",
          "TRUNCATE objects CASCADE"
        ] do
      assert {:refused, message} = attempt(fn -> Repo.query!(statement) end), statement
      assert message =~ "cannot be truncated"
    end

    assert Repo.aggregate(RouteChange, :count) > 0
  end

  test "only a registered, normalized address can be stored", ctx do
    other = subject_page!("people", "Candide", :person)

    for path <- [
          "/users/settings",
          "/People/Candide",
          "/people/cafe\u0301",
          "/people/a/b",
          "/people/c++",
          "/people/it's",
          "/people/a--b",
          "/people/-a"
        ] do
      assert {:refused, message} =
               attempt(fn ->
                 %{rows: [[id]]} = Repo.query!("SELECT nextval('public_paths_id_seq')")

                 change =
                   change!(%{
                     operation: :allocate,
                     actor_id: ctx.importer.id,
                     path_id: id,
                     after_kind: :canonical,
                     after_destination_id: other.id
                   })

                 Repo.insert!(%PublicPath{
                   id: id,
                   path: path,
                   kind: :canonical,
                   original_page_id: other.id,
                   destination_page_id: other.id,
                   last_route_change_id: change.id
                 })
               end),
             path

      assert message =~ ~r/public_paths_(shape|slug_characters)/, path
    end
  end
end
