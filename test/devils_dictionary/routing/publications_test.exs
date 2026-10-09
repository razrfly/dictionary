defmodule DevilsDictionary.Routing.PublicationsTest do
  @moduledoc """
  Publication (#237 C1, ADR 0004 §7): `Routing.Publications.publish/3`
  publishes a launch manifest's pages only through all eight gates, and
  refuses per page without rolling back the rest; every publication and
  withdrawal is a receipt, and the database refuses a publication state
  change without one, a receipt that does not continue its page's history,
  and any edit or deletion of a receipt.

  One test per gate. Six gates (identity for a merged object, decision,
  canonical, content, approval, metadata) each fail alone on a page that
  otherwise passes. Two cannot be isolated through `publish/3`: gate 5,
  permitted display, is tested at `check_display/1`, because the reader
  withholds a restricted body before the gate sees it, so through
  `publish/3` it is the content gate that refuses such a page (asserted
  here too); gate 8, integrity, is tested with a corrupt canonical pointer
  that the canonical gate also refuses, because every corrupt state the
  resolver can report fails identity or canonical as well, and a second
  canonical is impossible by index. Gate 1's retired case likewise fails
  identity among others.

  Voltaire, Arouet and the rest are CI fixtures in this test's sandbox.
  """
  # Not async: the sandbox holds each test's advisory path locks, and these
  # tests reuse addresses.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures
  import Ecto.Query

  alias DevilsDictionary.{AccountsFixtures, Fixtures, Registry, WordFixtures}
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Registry.Entity

  alias DevilsDictionary.Routing.{
    AuditSnapshot,
    Classifications,
    LaunchManifest,
    Page,
    PagePublication,
    Pages,
    Publications,
    Resolution,
    Resolver,
    ReviewRule,
    RouteChange
  }

  alias DevilsDictionary.Sources.Actor

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()

    reviewer =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()

    actor = Repo.insert!(%Actor{actor_kind: :user, user_id: reviewer.id, label: "Reviewer"})
    ctx = %{sources: sources, reviewer: reviewer, actor: actor, importer: importer!()}
    Map.put(ctx, :page, publishable!(ctx, "Voltaire", "/people/voltaire"))
  end

  # A person with a description, a biography paragraph, a mapped decision, a
  # draft subject page and its canonical: everything the gates ask for but
  # the manifest.
  defp publishable!(ctx, label, path, opts \\ []) do
    {:ok, person} = Registry.create_person(%{preferred_label: label})

    Repo.update_all(
      from(e in Entity, where: e.object_id == ^person.object_id),
      set: [description: Keyword.get(opts, :description, "French writer and philosopher")]
    )

    if Keyword.get(opts, :biography, true) do
      WordFixtures.entry!(ctx, person, "wikipedia",
        body: "#{label} was a writer of the Enlightenment. He wrote much."
      )
    end

    classify!(person.object_id, "people")
    {:ok, page} = Pages.ensure(:subject, person.object_id)
    allocated!(page, path, ctx.importer)
  end

  defp entry(page, ctx, fields \\ %{}) do
    page = Repo.get!(Page, page.id)

    Map.merge(
      %{
        "kind" => "subject",
        "page_id" => page.id,
        "object_id" => page.target_object_id,
        "locale" => "en",
        "path" => Repo.get!(DevilsDictionary.Routing.PublicPath, page.canonical_path_id).path,
        "reviewer" => ctx.reviewer.email,
        "clause" => "standing_decision"
      },
      fields
    )
  end

  defp manifest(entries, rule \\ nil) do
    doc = %{
      "format" => LaunchManifest.format(),
      "rule" => rule && %{"sha256" => rule.sha256, "signer" => rule.signer.email},
      "entries" => entries
    }

    LaunchManifest.from_doc(doc, AuditSnapshot.digest(Jason.encode!(doc)))
  end

  defp publish(ctx, entries, opts \\ []) do
    {:ok, report} = Publications.publish(manifest(entries, opts[:rule]), ctx.actor.id, opts)
    report
  end

  defp refused_on(report, page) do
    case Enum.find(report.refused, &(&1.page_id == page.id)) do
      nil -> flunk("page #{page.id} was not refused: #{inspect(report)}")
      refusal -> refusal
    end
  end

  defp state(page), do: Repo.get!(Page, page.id).publication_state
  defp receipts, do: Repo.aggregate(PagePublication, :count)

  # ── publishing ───────────────────────────────────────────────────────────

  test "a page that passes all eight gates is published, with its receipt", ctx do
    ledger = Repo.aggregate(RouteChange, :count)
    report = publish(ctx, [entry(ctx.page, ctx)])

    assert [%{page_id: id, receipt_id: receipt_id}] = report.published
    assert id == ctx.page.id
    assert state(ctx.page) == :published

    receipt = Repo.get!(PagePublication, receipt_id)

    assert {receipt.action, receipt.before_state, receipt.after_state} ==
             {:publish, :draft, :published}

    assert receipt.actor_id == ctx.actor.id
    assert receipt.manifest_sha256 =~ ~r/\A[0-9a-f]{64}\z/
    assert Enum.sort(Map.keys(receipt.gates)) == Enum.sort(Publications.gates())
    assert Enum.all?(receipt.gates, fn {_gate, found} -> found["passed"] end)
    assert receipt.gates["content"]["detail"] =~ "biography 1"

    # Served publicly now, at its canonical; publication moved no address.
    assert %Resolution{outcome: :canonical} = Resolver.resolve("/people/voltaire", mode: :public)
    assert Repo.aggregate(RouteChange, :count) == ledger
  end

  test "publishing is idempotent, a dry run writes nothing, an empty manifest says so", ctx do
    dry = publish(ctx, [entry(ctx.page, ctx)], dry_run: true)
    assert [%{page_id: id}] = dry.would_publish
    assert id == ctx.page.id
    assert receipts() == 0
    assert state(ctx.page) == :draft

    assert [_] = publish(ctx, [entry(ctx.page, ctx)]).published
    again = publish(ctx, [entry(ctx.page, ctx)])
    assert again.published == []
    assert [%{state: :published}] = again.unchanged
    assert receipts() == 1

    empty = publish(ctx, [])
    assert empty.empty
    assert empty.published == [] and empty.refused == []
  end

  test "a refusal is one page's: the rest of the manifest is published", ctx do
    other = publishable!(ctx, "Arouet", "/people/arouet", biography: false)
    report = publish(ctx, [entry(ctx.page, ctx), entry(other, ctx)])

    assert Enum.map(report.published, & &1.page_id) == [ctx.page.id]
    assert refused_on(report, other).failed == ["content"]
    assert state(ctx.page) == :published
    assert state(other) == :draft
    assert receipts() == 1
  end

  # ── one test per gate ────────────────────────────────────────────────────

  test "a refusal the database makes is one page's too, reported in its words", ctx do
    # Only `from_doc/3` can carry a digest the receipt's check constraint
    # refuses; the gates pass, the insert fails, and the batch goes on.
    other = publishable!(ctx, "Arouet", "/people/arouet")
    doc = %{"format" => LaunchManifest.format(), "rule" => nil, "entries" => [entry(other, ctx)]}
    bad = LaunchManifest.from_doc(doc, "not a digest")

    {:ok, report} = Publications.publish(bad, ctx.actor.id)
    assert [%{page_id: id, failed: ["database"], gates: gates}] = report.refused
    assert id == other.id
    assert gates["database"]["detail"] =~ "refused by the database"
    assert state(other) == :draft
    assert receipts() == 0
  end

  test "a manifest made without a rule publishes only as a human's override, recorded as such",
       ctx do
    # D3 as amended: the signed rule is the authority; a human publishes
    # only as an override, with a reason every receipt carries.
    assert {:error, :reason_required} =
             Publications.publish(manifest([entry(ctx.page, ctx)]), ctx.actor.id, override: true)

    report = publish(ctx, [entry(ctx.page, ctx)], override: true, reason: "a hand-named launch")
    assert [%{receipt_id: receipt_id}] = report.published

    assert Repo.get!(PagePublication, receipt_id).reason =~
             "a human's override: a hand-named launch"

    assert is_nil(Repo.get!(PagePublication, receipt_id).rule_sha256)
  end

  test "gate 1, identity: a merged or retired identity is refused", ctx do
    # Merged into another person with content of their own, so the reader
    # still shows a page: only the identity is wrong.
    survivor = publishable!(ctx, "Arouet", "/people/arouet")

    {:ok, _} =
      Registry.merge([ctx.page.target_object_id], survivor.target_object_id, reason: "fixture")

    refusal = refused_on(publish(ctx, [entry(ctx.page, ctx)]), ctx.page)

    assert refusal.failed == ["identity"]
    assert refusal.gates["identity"]["detail"] =~ "merged"
    assert state(ctx.page) == :draft

    # Retired: the reader then shows nothing of it either.
    {:ok, _} = Registry.retire(survivor.target_object_id, reason: "fixture")
    refusal = refused_on(publish(ctx, [entry(survivor, ctx)]), survivor)
    assert "identity" in refusal.failed
    assert refusal.gates["identity"]["detail"] =~ "retired"
  end

  test "gate 2, decision: a decision that is not mapped is refused", ctx do
    current = Classifications.current(ctx.page.target_object_id)

    {:ok, _} =
      Classifications.override(
        ctx.page.target_object_id,
        %{
          status: :needs_review,
          reason: "contested",
          evidence_fingerprint: current.evidence_fingerprint
        },
        ctx.actor.id
      )

    refusal = refused_on(publish(ctx, [entry(ctx.page, ctx)]), ctx.page)
    assert refusal.failed == ["decision"]
    assert refusal.gates["decision"]["detail"] =~ "needs_review"
  end

  test "gate 3, canonical: a manifest naming another address is refused", ctx do
    refusal =
      refused_on(
        publish(ctx, [entry(ctx.page, ctx, %{"path" => "/people/arouet"})]),
        ctx.page
      )

    assert refusal.failed == ["canonical"]
    assert refusal.gates["canonical"]["detail"] =~ "the page's canonical is /people/voltaire"
  end

  test "gate 4, content: a label and an imported description alone, or a fixture, are refused",
       ctx do
    bare = publishable!(ctx, "Arouet", "/people/arouet", biography: false)
    refusal = refused_on(publish(ctx, [entry(bare, ctx)]), bare)
    assert refusal.failed == ["content"]
    assert refusal.gates["content"]["detail"] =~ "a label and an imported description alone"

    Repo.update_all(
      from(e in Entity, where: e.object_id == ^ctx.page.target_object_id),
      set: [metadata: %{"fixture" => "#237 test fixture"}]
    )

    refusal = refused_on(publish(ctx, [entry(ctx.page, ctx)]), ctx.page)
    assert refusal.failed == ["content"]
    assert refusal.gates["content"]["detail"] =~ "a fixture"
  end

  test "gate 5, display: a page showing a body its rights restrict is refused", ctx do
    # The reader redacts a restricted body by construction, so a page built
    # from the corpus cannot fail this gate; it is the guard against one
    # that would. Given such a page, the gate refuses.
    page = EntityPage.build(ctx.page.target_object_id)
    [paragraph | _] = page.biography

    leaking = %{
      page
      | biography: [
          %{paragraph | rights_metadata: %{"display" => "restricted"}, display_restricted?: false}
        ]
    }

    assert %{"passed" => false, "detail" => detail} = Publications.check_display(leaking)
    assert detail =~ "Visibility forbids"
    assert %{"passed" => true} = Publications.check_display(page)

    # And a restricted paragraph the reader redacts is withheld, not shown:
    # with nothing else to show, the page has no content to publish.
    content = Registry.current_content_revision(paragraph.object_id)

    Repo.update_all(
      from(r in "content_revisions", where: r.id == ^content.id),
      set: [rights_metadata: %{"display" => "restricted"}]
    )

    refusal = refused_on(publish(ctx, [entry(ctx.page, ctx)]), ctx.page)
    assert refusal.failed == ["content"]
    assert refusal.gates["display"]["passed"]
    assert refusal.gates["display"]["detail"] =~ "1 withheld"
  end

  test "gate 6, approval: an entry whose reviewer is no reviewer, or not the publisher, is refused",
       ctx do
    plain = AccountsFixtures.user_fixture()

    refusal =
      refused_on(publish(ctx, [entry(ctx.page, ctx, %{"reviewer" => plain.email})]), ctx.page)

    assert refusal.failed == ["approval"]
    assert refusal.gates["approval"]["detail"] =~ "is not a reviewer account"

    someone =
      AccountsFixtures.user_fixture() |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()

    refusal =
      refused_on(publish(ctx, [entry(ctx.page, ctx, %{"reviewer" => someone.email})]), ctx.page)

    assert refusal.failed == ["approval"]
    assert refusal.gates["approval"]["detail"] =~ "who is not that reviewer"
  end

  test "gate 6, approval: under a standing rule, only the signed rule it names, by its signer",
       ctx do
    rule = signed_rule!(ctx)

    # Made under this rule and published by its signer: approved.
    report = publish(ctx, [entry(ctx.page, ctx)], rule: rule, dry_run: true)
    assert [%{gates: gates}] = report.would_publish
    assert gates["approval"]["detail"] =~ "under standing review rule"

    # Made under the rule but published without it, or under another.
    other = signed_rule!(ctx, &Map.put(&1, "name", "Another rule"))
    doc = manifest([entry(ctx.page, ctx)], rule)

    {:ok, without} = Publications.publish(doc, ctx.actor.id)
    assert refused_on(without, ctx.page).gates["approval"]["detail"] =~ "which was not given"

    {:ok, mismatched} = Publications.publish(doc, ctx.actor.id, rule: other)

    assert refused_on(mismatched, ctx.page).gates["approval"]["detail"] =~
             "not #{String.slice(other.sha256, 0, 12)}"

    # A record the rule deferred is not published under it.
    deferred =
      publish(ctx, [entry(ctx.page, ctx, %{"clause" => "classification_review"})], rule: rule)

    assert refused_on(deferred, ctx.page).gates["approval"]["detail"] =~ "did not confirm it"

    # The receipt names the rule.
    [published] = publish(ctx, [entry(ctx.page, ctx)], rule: rule).published
    assert Repo.get!(PagePublication, published.receipt_id).rule_sha256 == rule.sha256
  end

  test "gate 7, metadata: a page whose description cannot be derived is refused", ctx do
    {:ok, person} = Registry.create_person(%{preferred_label: "Quiet"})
    {:ok, work} = Registry.create_work(%{preferred_label: "A Quiet Book", work_kind: "book"})

    {:ok, _} =
      DevilsDictionary.Claims.assert(work.object_id, "authored_by", person.object_id, %{})

    classify!(person.object_id, "people")
    {:ok, page} = Pages.ensure(:subject, person.object_id)
    page = allocated!(page, "/people/quiet", ctx.importer)

    refusal = refused_on(publish(ctx, [entry(page, ctx)]), page)
    assert refusal.failed == ["metadata"]
    assert refusal.gates["content"]["detail"] =~ "works 1"
    assert refusal.gates["metadata"]["detail"] =~ "no description"
  end

  test "gate 8, integrity: a page whose canonical pointer is corrupt is refused", ctx do
    other = publishable!(ctx, "Arouet", "/people/arouet")

    # A state the database refuses at commit; inside this sandbox, which
    # never commits, it can be read. Triggers off for one statement.
    Repo.query!("SET LOCAL session_replication_role = replica")

    Repo.query!("UPDATE pages SET canonical_path_id = $1 WHERE id = $2", [
      Repo.get!(Page, other.id).canonical_path_id,
      ctx.page.id
    ])

    Repo.query!("SET LOCAL session_replication_role = origin")

    refusal =
      refused_on(publish(ctx, [entry(ctx.page, ctx, %{"path" => "/people/arouet"})]), ctx.page)

    assert "integrity" in refusal.failed
    assert refusal.gates["integrity"]["detail"] =~ "corrupt resolver state"
    assert state(ctx.page) == :draft
  end

  # ── withdrawing ──────────────────────────────────────────────────────────

  test "a reviewer withdraws a published page; it is 404 publicly, and the rule does not republish it",
       ctx do
    [_] = publish(ctx, [entry(ctx.page, ctx)]).published

    assert {:error, :human_required} = Publications.withdraw(ctx.page.id, ctx.importer.id, "x")
    assert {:error, :reason_required} = Publications.withdraw(ctx.page.id, ctx.actor.id, " ")
    assert {:error, :not_found} = Publications.withdraw(999_999_999, ctx.actor.id, "x")

    assert {:ok, receipt} = Publications.withdraw(ctx.page.id, ctx.actor.id, "a complaint")

    assert {receipt.action, receipt.before_state, receipt.after_state} ==
             {:withdraw, :published, :withdrawn}

    assert state(ctx.page) == :withdrawn

    resolution = Resolver.resolve("/people/voltaire", mode: :public)
    assert Resolution.http_status(resolution) == 404

    assert {:error, {:not_published, :withdrawn}} =
             Publications.withdraw(ctx.page.id, ctx.actor.id, "again")

    # The manifest again: a withdrawal is a reviewer's decision, kept.
    report = publish(ctx, [entry(ctx.page, ctx)])
    assert [%{state: :withdrawn}] = report.unchanged
    assert state(ctx.page) == :withdrawn

    # Only a reviewer's explicit decision, with a reason, publishes it again.
    assert {:error, :reason_required} =
             Publications.publish(manifest([entry(ctx.page, ctx)]), ctx.actor.id, republish: true)

    report = publish(ctx, [entry(ctx.page, ctx)], republish: true, reason: "resolved")
    assert [%{receipt_id: id}] = report.published
    assert Repo.get!(PagePublication, id).before_state == :withdrawn
    assert Repo.get!(PagePublication, id).reason =~ "republished: resolved"

    assert [:publish, :withdraw, :publish] ==
             Enum.map(Publications.history(ctx.page.id), & &1.action)
  end

  test "publishing needs a human actor", ctx do
    assert {:error, :human_required} =
             Publications.publish(manifest([entry(ctx.page, ctx)]), ctx.importer.id)

    assert receipts() == 0
  end

  # ── what the database refuses ────────────────────────────────────────────

  defp attempt(fun) do
    Repo.transaction(fn ->
      fun.()
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
      Repo.rollback(:accepted)
    end)
  rescue
    error in [Postgrex.Error] -> {:refused, Exception.message(error)}
  after
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
  end

  defp receipt(page_id, action, before, after_state, actor_id) do
    [sql, params] = receipt_sql(page_id, action, before, after_state, actor_id)
    Repo.query!(sql, params)
  end

  test "the database refuses a publication state change without its receipt", ctx do
    id = ctx.page.id

    set = fn state ->
      Repo.query!("UPDATE pages SET publication_state = $1 WHERE id = $2", [state, id])
    end

    assert {:refused, message} = attempt(fn -> set.("published") end)
    assert message =~ "without a publication receipt"

    # A receipt for another change does not cover this one.
    assert {:refused, message} =
             attempt(fn ->
               receipt(id, "publish", "draft", "published", ctx.actor.id)
               set.("withdrawn")
             end)

    assert message =~ "without a publication receipt"

    # A receipt never applied is refused at commit.
    assert {:refused, message} =
             attempt(fn -> receipt(id, "publish", "draft", "published", ctx.actor.id) end)

    assert message =~ "was never applied"

    # A receipt that does not continue the page's history.
    assert {:refused, message} =
             attempt(fn ->
               receipt(id, "publish", "withdrawn", "published", ctx.actor.id)
               set.("published")
             end)

    assert message =~ "without a publication receipt" or message =~ "does not continue"

    # A machine cannot publish, and nothing returns a page to draft.
    assert {:refused, message} =
             attempt(fn -> receipt(id, "publish", "draft", "published", ctx.importer.id) end)

    assert message =~ "needs a human actor"

    assert {:refused, message} =
             attempt(fn -> receipt(id, "withdraw", "published", "draft", ctx.actor.id) end)

    assert message =~ "page_publications_transition"

    # A page is born a draft.
    {:ok, person} = Registry.create_person(%{preferred_label: "Born"})

    assert {:refused, message} =
             attempt(fn ->
               Repo.query!(
                 "INSERT INTO pages (role, locale, target_object_id, publication_state, inserted_at, updated_at) VALUES ('subject', 'en', $1, 'published', now(), now())",
                 [person.object_id]
               )
             end)

    assert message =~ "a page is created a draft"
    assert state(ctx.page) == :draft
  end

  test "receipts are append-only and cannot be truncated", ctx do
    [%{receipt_id: id}] = publish(ctx, [entry(ctx.page, ctx)]).published

    assert {:refused, message} =
             attempt(fn ->
               Repo.query!("UPDATE page_publications SET reason = 'x' WHERE id = $1", [id])
             end)

    assert message =~ "append-only"

    assert {:refused, _} =
             attempt(fn -> Repo.query!("DELETE FROM page_publications WHERE id = $1", [id]) end)

    assert {:refused, message} =
             attempt(fn ->
               Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
               Repo.query!("TRUNCATE page_publications CASCADE")
             end)

    assert message =~ "cannot be truncated"
    assert receipts() == 1
  end

  test "the routing guard's digest covers the receipts", ctx do
    before = DevilsDictionary.Routing.Recovery.durable_tables()
    assert "page_publications" in before
    assert Enum.take(before, 6) == DevilsDictionary.Routing.Recovery.routing_tables()
    _ = ctx
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp signed_rule!(ctx, edit \\ & &1) do
    dir = Path.join(System.tmp_dir!(), "publications-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "rule.json")

    doc =
      ReviewRule.path() |> File.read!() |> Jason.decode!() |> Map.put("signature", nil) |> edit.()

    File.write!(path, Jason.encode!(doc))
    AccountsFixtures.set_password(ctx.reviewer)

    {:ok, rule} =
      ReviewRule.sign(path, ctx.reviewer.email, AccountsFixtures.valid_user_password())

    rule
  end
end
