defmodule DevilsDictionary.Routing.SchemaIntegrityTest do
  @moduledoc """
  The routing invariants the database holds by itself (ADR 0004 §5), tried
  with raw SQL that goes around `Routing.Ledger` — the way a future bug, a
  hand-written backfill or an operator's console would.

  Each attempt runs in a savepoint and fires the deferred checks before it
  would commit, then is rolled back, so one test can try several.
  """
  # Not async: the sandbox holds each test's transaction — and so its
  # advisory path locks and uncommitted unique paths — for the whole test, and
  # these tests reuse addresses such as /people/voltaire.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{
    ClassificationDecision,
    Ledger,
    Page,
    Pages,
    PublicPath,
    RouteChange
  }

  setup do
    human = human!()
    page = live_page!("people", "/people/voltaire", human, :person)
    %{human: human, page: page, path: Repo.get!(PublicPath, page.canonical_path_id)}
  end

  # {:refused, message} when the statement or the commit-time checks refuse it.
  defp attempt(fun) do
    Repo.transaction(fn ->
      fun.()
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
      Repo.rollback(:accepted)
    end)
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] -> {:refused, Exception.message(error)}
  after
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
  end

  defp sql(statement, params), do: fn -> Repo.query!(statement, params) end

  # A ledger row that honestly describes a path transition.
  defp ledger_row!(path, kind, destination_id, actor) do
    Repo.insert!(%RouteChange{
      operation_id: Ecto.UUID.generate(),
      sequence: 1,
      operation: :move,
      path_id: path.id,
      before_kind: path.kind,
      after_kind: kind,
      before_destination_id: path.destination_page_id,
      after_destination_id: destination_id,
      actor_id: actor.id,
      reason: "console"
    })
  end

  test "a path cannot change unless a new ledger row records exactly that change", ctx do
    assert {:refused, message} =
             attempt(sql("UPDATE public_paths SET kind = 'alias' WHERE id = $1", [ctx.path.id]))

    assert message =~ "changed without a new route change"

    assert {:refused, message} =
             attempt(fn ->
               # Claims the path was a tombstone: a changing row, but a false one.
               wrong = ledger_row!(%{ctx.path | kind: :tombstone}, :alias, ctx.page.id, ctx.human)

               Repo.query!(
                 "UPDATE public_paths SET kind = 'alias', last_route_change_id = $2 WHERE id = $1",
                 [ctx.path.id, wrong.id]
               )
             end)

    assert message =~ "does not record public path"
  end

  test "an address keeps its spelling and first owner, and is never deleted", ctx do
    other = subject_page!("people", "Someone else", :person)

    assert {:refused, message} =
             attempt(
               sql("UPDATE public_paths SET path = '/people/arouet' WHERE id = $1", [ctx.path.id])
             )

    assert message =~ "keeps its spelling and original owner"

    assert {:refused, _} =
             attempt(
               sql("UPDATE public_paths SET original_page_id = $2 WHERE id = $1", [
                 ctx.path.id,
                 other.id
               ])
             )

    assert {:refused, message} =
             attempt(sql("DELETE FROM public_paths WHERE id = $1", [ctx.path.id]))

    assert message =~ "a path reservation is permanent"
  end

  test "even an honestly ledgered change cannot hand an address to an unrelated page", ctx do
    {:ok, _} =
      Ledger.move(ctx.page.id, "/people/arouet", actor_id: ctx.human.id, reason: "pen name")

    alias_path = Repo.get!(PublicPath, ctx.path.id)
    assert alias_path.kind == :alias
    other = subject_page!("people", "Unrelated person", :person)

    assert {:refused, message} =
             attempt(fn ->
               change = ledger_row!(alias_path, :alias, other.id, ctx.human)

               Repo.query!(
                 """
                 UPDATE public_paths SET destination_page_id = $2, last_route_change_id = $3
                  WHERE id = $1
                 """,
                 [alias_path.id, other.id, change.id]
               )
             end)

    assert message =~ "/people/voltaire) was repurposed"
  end

  test "a page has one canonical, and its pointer agrees with it", ctx do
    other = live_page!("people", "/people/candide", ctx.human, :person)

    assert {:refused, message} =
             attempt(fn ->
               %{rows: [[id]]} = Repo.query!("SELECT nextval('public_paths_id_seq')")

               change =
                 Repo.insert!(%RouteChange{
                   operation_id: Ecto.UUID.generate(),
                   sequence: 1,
                   operation: :allocate,
                   path_id: id,
                   after_kind: :canonical,
                   after_destination_id: ctx.page.id,
                   actor_id: ctx.human.id,
                   reason: "second canonical"
                 })

               Repo.insert!(%PublicPath{
                 id: id,
                 path: "/people/arouet",
                 kind: :canonical,
                 original_page_id: ctx.page.id,
                 destination_page_id: ctx.page.id,
                 last_route_change_id: change.id
               })
             end)

    assert message =~ "public_paths_one_canonical_index"

    assert {:refused, message} =
             attempt(fn ->
               change =
                 Repo.insert!(%RouteChange{
                   operation_id: Ecto.UUID.generate(),
                   sequence: 1,
                   operation: :move,
                   page_id: ctx.page.id,
                   before_lifecycle: :active,
                   after_lifecycle: :active,
                   before_canonical_path_id: ctx.page.canonical_path_id,
                   after_canonical_path_id: other.canonical_path_id,
                   actor_id: ctx.human.id,
                   reason: "point at someone else's canonical"
                 })

               ctx.page
               |> Ecto.Changeset.change(
                 canonical_path_id: other.canonical_path_id,
                 last_route_change_id: change.id
               )
               |> Repo.update!()
             end)

    assert message =~ "which is not its canonical"
  end

  test "a published page has a canonical path", ctx do
    unrouted = subject_page!("people", "Unrouted", :person)

    # Even with its receipt: the commit-time check refuses it.
    [receipt, params] = receipt_sql(unrouted.id, "publish", "draft", "published", ctx.human.id)

    assert {:refused, message} =
             attempt(fn ->
               Repo.query!(receipt, params)

               Repo.query!("UPDATE pages SET publication_state = 'published' WHERE id = $1", [
                 unrouted.id
               ])
             end)

    assert message =~ "published page #{unrouted.id} has no canonical path"
    assert Repo.get!(Page, ctx.page.id).publication_state == :published
  end

  test "a page's role, locale and target are fixed, and its role must fit its target", ctx do
    lexeme = lexeme!("voltaire", "name")

    assert {:refused, message} =
             attempt(
               sql(
                 "INSERT INTO pages (role, locale, target_object_id, inserted_at, updated_at) VALUES ('subject', 'en', $1, now(), now())",
                 [lexeme.object_id]
               )
             )

    assert message =~ "a subject page cannot target lexeme"

    assert {:refused, message} =
             attempt(sql("UPDATE pages SET role = 'edition' WHERE id = $1", [ctx.page.id]))

    assert message =~ "keeps its role, locale and target"

    assert {:refused, message} = attempt(sql("DELETE FROM pages WHERE id = $1", [ctx.page.id]))
    assert message =~ "retire a page instead"
  end

  test "a revision is immutable and its membership sealed", ctx do
    lexeme = lexeme!("candide")

    {:ok, revision} =
      Pages.add_revision(
        ctx.page.id,
        %{title: "Voltaire"},
        [%{relationship: :supplies_lexical_material, target_object_id: lexeme.object_id}],
        ctx.human.id
      )

    other = overview_page!()

    assert {:refused, message} =
             attempt(
               sql("UPDATE page_revisions SET title = 'Arouet' WHERE id = $1", [revision.id])
             )

    assert message =~ "revisions are immutable"

    assert {:refused, message} =
             attempt(
               sql(
                 """
                 INSERT INTO page_memberships (page_id, page_revision_id, position, relationship,
                   target_object_id, evidence, inserted_at) VALUES ($1, $2, 2, 'editorial_association', $3, '{}', now())
                 """,
                 [ctx.page.id, revision.id, lexeme.object_id]
               )
             )

    assert message =~ "declares no membership position 2"

    assert {:refused, message} =
             attempt(
               sql(
                 """
                 INSERT INTO page_revisions (page_id, revision_number, body_format, author_actor_id,
                   evidence, membership_count, inserted_at) VALUES ($1, 9, 'markdown', $2, '{}', 1, now())
                 """,
                 [ctx.page.id, ctx.human.id]
               )
             )

    assert message =~ "declares 1 memberships and has 0"

    assert {:refused, message} =
             attempt(
               sql("UPDATE pages SET current_revision_id = $2 WHERE id = $1", [
                 other.id,
                 revision.id
               ])
             )

    assert message =~ "pages_current_revision_fkey"

    assert {:refused, _} =
             attempt(
               sql("DELETE FROM page_memberships WHERE page_revision_id = $1", [revision.id])
             )
  end

  test "the ledger is append-only, and only allocation may be a machine's", ctx do
    [change | _] = Ledger.history(page_id: ctx.page.id)

    assert {:refused, message} =
             attempt(
               sql("UPDATE route_changes SET reason = 'rewritten' WHERE id = $1", [change.id])
             )

    assert message =~ "the route ledger is append-only"

    importer = importer!()

    assert {:refused, message} =
             attempt(fn ->
               ledger_row!(ctx.path, :alias, ctx.page.id, importer)
             end)

    assert message =~ "route move needs a human actor"
  end

  test "a decision changes only by losing currency, and only a human overrides", ctx do
    decision = Repo.get_by!(ClassificationDecision, object_id: ctx.page.target_object_id)

    assert {:refused, message} =
             attempt(
               sql("UPDATE classification_decisions SET family = 'works' WHERE id = $1", [
                 decision.id
               ])
             )

    assert message =~ "is immutable; supersede it"

    override = %ClassificationDecision{
      object_id: ctx.page.target_object_id,
      origin: :override,
      status: :mapped,
      family: :people,
      policy_version: "1.0.0",
      evidence_fingerprint: decision.evidence_fingerprint,
      reason: "reviewed"
    }

    assert {:refused, message} =
             attempt(fn -> Repo.insert!(%{override | reviewer_actor_id: importer!().id}) end)

    assert message =~ "an override needs a human reviewer"

    assert {:refused, message} =
             attempt(fn -> Repo.insert!(%{override | origin: :evaluator, family: nil}) end)

    assert message =~ "classification_decisions_family"

    assert {:refused, message} =
             attempt(fn ->
               Repo.insert!(%{override | origin: :evaluator, status: :needs_review})
             end)

    assert message =~ "classification_decisions_family"
  end
end
