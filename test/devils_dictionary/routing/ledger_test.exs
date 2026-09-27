defmodule DevilsDictionary.Routing.LedgerTest do
  @moduledoc """
  Allocation and the approved address operations of ADR 0004 §5–6, checked by
  exact rows and destinations, not counts alone. Every test ends by firing the
  deferred checks a real commit would run (`consistent!/0`).
  """
  # Not async: the sandbox holds each test's transaction — and so its
  # advisory path locks and uncommitted unique paths — for the whole test, and
  # these tests reuse addresses such as /people/voltaire.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Registry

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

  setup do
    %{human: human!(), importer: importer!()}
  end

  defp opts(actor, reason \\ "test"), do: [actor_id: actor.id, reason: reason]

  defp resolve(path), do: path |> Address.encode() |> Resolver.resolve()

  defp paths(page_id) do
    Repo.all(
      from p in PublicPath,
        where: p.destination_page_id == ^page_id,
        order_by: p.path,
        select: {p.path, p.kind, p.original_page_id}
    )
  end

  defp ledger_size, do: Repo.aggregate(RouteChange, :count)

  describe "allocate/3" do
    test "reserves one canonical and records the path, the pointer and the decision", ctx do
      page = subject_page!("people", "Voltaire", :person)
      decision = Classifications.current(page.target_object_id)

      assert {:ok, %PublicPath{path: "/people/voltaire", kind: :canonical} = path} =
               Ledger.allocate(page.id, "/people/voltaire", opts(ctx.importer, "backfill"))

      page = Repo.get!(Page, page.id)
      assert page.canonical_path_id == path.id
      assert path.original_page_id == page.id and path.destination_page_id == page.id

      assert [created, pointed] = Ledger.history(page_id: page.id)
      assert created.operation_id == pointed.operation_id
      assert {created.sequence, pointed.sequence} == {1, 2}

      assert {created.path_id, created.before_kind, created.after_kind,
              created.after_destination_id} ==
               {path.id, nil, :canonical, page.id}

      assert {pointed.page_id, pointed.before_canonical_path_id, pointed.after_canonical_path_id} ==
               {page.id, nil, path.id}

      assert {created.classification_decision_id, created.policy_version, created.actor_id,
              created.reason} == {decision.id, "1.0.0", ctx.importer.id, "backfill"}

      # Allocated is not published: the address is reserved, and nothing serves it.
      assert %Resolution{outcome: :unavailable} = resolve("/people/voltaire")
      consistent!()
    end

    test "is idempotent, and a taken address or a second canonical is refused unwritten", ctx do
      first = subject_page!("people", "Voltaire", :person)
      second = subject_page!("people", "Voltaire (musician)", :person)
      {:ok, path} = Ledger.allocate(first.id, "/people/voltaire", opts(ctx.importer))
      before = ledger_size()

      assert {:ok, ^path} = Ledger.allocate(first.id, "/people/voltaire", opts(ctx.importer))

      assert Ledger.allocate(second.id, "/people/voltaire", opts(ctx.importer)) ==
               {:error,
                {:path_taken, %{path: "/people/voltaire", kind: :canonical, page_id: first.id}}}

      assert Ledger.allocate(first.id, "/people/arouet", opts(ctx.importer)) ==
               {:error, {:page_has_canonical, "/people/voltaire"}}

      assert ledger_size() == before
      assert Repo.get!(Page, second.id).canonical_path_id == nil
      consistent!()
    end

    test "needs a current mapped decision in the path's family; nothing falls back to Subjects",
         ctx do
      unclassified = entity!(:concept, "Unclassified")
      {:ok, unclassified} = Pages.ensure(:subject, unclassified.object_id)

      unmapped = entity!(:concept, "Unmapped")
      leave_unmapped!(unmapped.object_id)
      {:ok, unmapped} = Pages.ensure(:subject, unmapped.object_id)

      person = subject_page!("people", "Candide", :person)
      {:ok, lexeme_page} = Pages.ensure(:lexeme, lexeme!("candide").object_id)
      {:ok, choice} = Pages.create(%{role: :choice})
      before = ledger_size()

      for {page, path, error} <- [
            {unclassified, "/concepts/unclassified", :unclassified},
            {unmapped, "/subjects/unmapped", {:classification_not_mapped, :needs_review}},
            {person, "/subjects/candide", {:family_mismatch, :people}},
            {person, "/on/candide", {:namespace_not_allowed, :subject}},
            {lexeme_page, "/concepts/candide", :not_ledger_addressed},
            {choice, "/concepts/candide", :namespace_undefined}
          ] do
        assert Ledger.allocate(page.id, path, opts(ctx.importer)) == {:error, error}, path
      end

      assert ledger_size() == before

      # An On overview is editorial: no classification, only its own namespace.
      assert {:ok, %PublicPath{path: "/on/mercury"}} =
               Ledger.allocate(overview_page!().id, "/on/mercury", opts(ctx.importer))

      consistent!()
    end

    test "stays idempotent after the page is reclassified", ctx do
      page = live_page!("works", "/works/apple", ctx.human, :work)
      classify!(page.target_object_id, "nature", revision: 2)
      before = ledger_size()

      assert {:ok, %PublicPath{path: "/works/apple"}} =
               Ledger.allocate(page.id, "/works/apple", opts(ctx.importer))

      assert {:ok, %PublicPath{path: "/works/apple"}} =
               Ledger.move(page.id, "/works/apple", opts(ctx.human))

      assert ledger_size() == before
      consistent!()
    end

    test "a refusal inside a caller's transaction does not roll the caller back", ctx do
      first = subject_page!("people", "Voltaire", :person)
      second = subject_page!("people", "Candide", :person)

      taken =
        subject_page!("people", "Arouet", :person) |> allocated!("/people/arouet", ctx.human)

      assert {:ok, results} =
               Repo.transaction(fn ->
                 [
                   Ledger.allocate(first.id, "/people/voltaire", opts(ctx.importer)),
                   Ledger.allocate(second.id, "/people/arouet", opts(ctx.importer))
                 ]
               end)

      assert [
               {:ok, %PublicPath{path: "/people/voltaire"}},
               {:error, {:path_taken, %{page_id: id}}}
             ] =
               results

      assert id == taken.id
      assert %Page{canonical_path_id: kept} = Repo.get!(Page, first.id)
      assert kept != nil
      consistent!()
    end

    test "reclassification never moves a published address", ctx do
      page = live_page!("works", "/works/apple", ctx.human, :work)
      [allocation | _] = Ledger.history(page_id: page.id)
      before = ledger_size()

      decision = classify!(page.target_object_id, "nature", revision: 2)
      assert {decision.status, decision.family} == {:mapped, :nature}

      assert %Resolution{outcome: :canonical, page: %{id: id}, location: "/works/apple"} =
               resolve("/works/apple")

      assert id == page.id
      assert ledger_size() == before
      assert allocation.classification_decision_id != decision.id
      consistent!()
    end
  end

  describe "approved operations" do
    test "a move leaves one 301 behind, and moving back restores the old address", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)

      assert Ledger.move(page.id, "/people/arouet", opts(ctx.importer)) ==
               {:error, :human_approval_required}

      assert {:ok, %PublicPath{path: "/people/arouet"}} =
               Ledger.move(page.id, "/people/arouet", opts(ctx.human, "pen name"))

      assert %Resolution{outcome: :redirect, location: "/people/arouet"} =
               r = resolve("/people/voltaire")

      assert Resolution.http_status(r) == 301
      assert %Resolution{outcome: :canonical} = resolve("/people/arouet")

      assert {:ok, %PublicPath{path: "/people/voltaire"}} =
               Ledger.move(page.id, "/people/voltaire", opts(ctx.human, "restore"))

      assert %Resolution{outcome: :redirect, location: "/people/voltaire"} =
               resolve("/people/arouet")

      assert paths(page.id) == [
               {"/people/arouet", :alias, page.id},
               {"/people/voltaire", :canonical, page.id}
             ]

      other = live_page!("people", "/people/candide", ctx.human, :person)

      assert Ledger.move(other.id, "/people/arouet", opts(ctx.human)) ==
               {:error, {:path_taken, %{path: "/people/arouet", kind: :alias, page_id: page.id}}}

      consistent!()
    end

    test "a merge sends every old address to the survivor in one hop, even along a chain", ctx do
      [a, b, c] =
        for path <- ["/people/arouet", "/people/voltaire", "/people/francois-marie-arouet"],
            do: live_page!("people", path, ctx.human, :person)

      {:ok, _} = Ledger.move(a.id, "/people/arouet-le-jeune", opts(ctx.human))

      assert Ledger.merge(a.id, b.id, opts(ctx.human)) == {:error, :identity_not_merged}

      {:ok, _} = Registry.merge([a.target_object_id], b.target_object_id, reason: "same person")
      assert {:ok, %Page{lifecycle_state: :merged}} = Ledger.merge(a.id, b.id, opts(ctx.human))

      for old <- ["/people/arouet", "/people/arouet-le-jeune"] do
        assert %Resolution{outcome: :redirect, location: "/people/voltaire"} = resolve(old)
      end

      {:ok, _} = Registry.merge([b.target_object_id], c.target_object_id, reason: "same person")
      {:ok, _} = Ledger.merge(b.id, c.id, opts(ctx.human))

      for old <- ["/people/arouet", "/people/arouet-le-jeune", "/people/voltaire"] do
        assert %Resolution{outcome: :redirect, location: "/people/francois-marie-arouet"} =
                 resolve(old)
      end

      # Ownership is history and never moves; only the destination follows the merge.
      assert paths(c.id) == [
               {"/people/arouet", :alias, a.id},
               {"/people/arouet-le-jeune", :alias, a.id},
               {"/people/francois-marie-arouet", :canonical, c.id},
               {"/people/voltaire", :alias, b.id}
             ]

      assert Repo.get!(Page, a.id).merged_into_page_id == b.id

      assert %Resolution{outcome: :redirect, location: "/people/francois-marie-arouet"} =
               Resolver.resolve_page(a.id)

      consistent!()
    end

    test "a published page cannot merge into an unpublished one", ctx do
      published = live_page!("people", "/people/voltaire", ctx.human, :person)
      draft = subject_page!("people", "Arouet", :person)

      {:ok, _} =
        Registry.merge([published.target_object_id], draft.target_object_id, reason: "dup")

      assert Ledger.merge(published.id, draft.id, opts(ctx.human)) ==
               {:error, :survivor_not_published}

      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")
    end

    test "a split becomes a choice among its named successors and never picks one", ctx do
      mercury = live_page!("nature", "/nature/mercury", ctx.human)
      planet = live_page!("nature", "/nature/mercury-planet", ctx.human)
      element = live_page!("nature", "/nature/mercury-element", ctx.human)
      stranger = live_page!("nature", "/nature/venus", ctx.human)

      assert Ledger.split(mercury.id, [planet.id, element.id], opts(ctx.human)) ==
               {:error, :identity_not_split}

      {:ok, _} =
        Registry.split(
          mercury.target_object_id,
          [planet.target_object_id, element.target_object_id],
          reason: "planet and element"
        )

      assert Ledger.split(mercury.id, [planet.id, stranger.id], opts(ctx.human)) ==
               {:error, :successor_not_a_split_output}

      assert {:ok, %Page{lifecycle_state: :split}} =
               Ledger.split(mercury.id, [element.id, planet.id], opts(ctx.human))

      assert %Resolution{outcome: :choice, location: "/nature/mercury", successors: successors} =
               r = resolve("/nature/mercury")

      assert Resolution.http_status(r) == 200

      assert [
               %{
                 page_id: first,
                 resolution: %Resolution{outcome: :canonical, location: "/nature/mercury-element"}
               },
               %{
                 page_id: second,
                 resolution: %Resolution{outcome: :canonical, location: "/nature/mercury-planet"}
               }
             ] = successors

      assert {first, second} == {element.id, planet.id}
      assert paths(mercury.id) == [{"/nature/mercury", :canonical, mercury.id}]
      consistent!()
    end

    test "a published split names only published successors", ctx do
      mercury = live_page!("nature", "/nature/mercury", ctx.human)
      planet = live_page!("nature", "/nature/mercury-planet", ctx.human)
      element = subject_page!("nature", "Mercury (element)")

      {:ok, _} =
        Registry.split(
          mercury.target_object_id,
          [planet.target_object_id, element.target_object_id],
          reason: "planet and element"
        )

      assert Ledger.split(mercury.id, [planet.id, element.id], opts(ctx.human)) ==
               {:error, :successor_not_published}
    end

    test "a retired page nobody saw answers 404, not 410", ctx do
      draft =
        subject_page!("people", "Candide", :person) |> allocated!("/people/candide", ctx.human)

      {:ok, _} = Ledger.retire(draft.id, opts(ctx.human, "never launched"))

      assert %Resolution{outcome: :unavailable} = r = resolve("/people/candide")
      assert Resolution.http_status(r) == 404
      assert %Resolution{outcome: :unavailable} = Resolver.resolve_page(draft.id)
      consistent!()
    end

    test "retirement answers 410 and keeps the address reserved", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))
      {:ok, %Page{lifecycle_state: :retired}} = Ledger.retire(page.id, opts(ctx.human, "removed"))

      for gone <- ["/people/voltaire", "/people/arouet"] do
        assert %Resolution{outcome: :gone} = r = resolve(gone)
        assert Resolution.http_status(r) == 410
      end

      other = subject_page!("people", "Another Voltaire", :person)

      assert {:error, {:path_taken, %{kind: :tombstone, page_id: page_id}}} =
               Ledger.allocate(other.id, "/people/voltaire", opts(ctx.importer))

      assert page_id == page.id
      consistent!()
    end
  end

  describe "rollback/2" do
    test "restores a move exactly and keeps both reservations and the whole ledger", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: move} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      before = ledger_size()

      assert Ledger.rollback(move, opts(ctx.importer)) == {:error, :human_approval_required}
      assert {:ok, ^move} = Ledger.rollback(move, opts(ctx.human, "wrong name"))

      # The address the move created was public: it stays, as a redirect.
      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")

      assert %Resolution{outcome: :redirect, location: "/people/voltaire"} =
               resolve("/people/arouet")

      assert paths(page.id) == [
               {"/people/arouet", :alias, page.id},
               {"/people/voltaire", :canonical, page.id}
             ]

      rollback = Repo.all(from c in RouteChange, where: c.reverts_operation_id == ^move)
      assert length(rollback) == 3 and ledger_size() == before + 3
      assert Ledger.rollback(move, opts(ctx.human)) == {:error, :already_rolled_back}
      consistent!()
    end

    test "restores a merge to the exact paths and page it had", ctx do
      a = live_page!("people", "/people/arouet", ctx.human, :person)
      b = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(a.id, "/people/arouet-le-jeune", opts(ctx.human))
      paths_before = paths(a.id)
      {:ok, _} = Registry.merge([a.target_object_id], b.target_object_id, reason: "dup")
      {:ok, _} = Ledger.merge(a.id, b.id, opts(ctx.human))
      %{operation_id: merge} = Enum.find(Ledger.history(page_id: a.id), &(&1.operation == :merge))

      {:ok, ^merge} = Ledger.rollback(merge, opts(ctx.human))

      assert paths(a.id) == paths_before
      assert %Page{lifecycle_state: :active, merged_into_page_id: nil} = Repo.get!(Page, a.id)

      assert %Resolution{outcome: :canonical, page: %{id: id}} =
               resolve("/people/arouet-le-jeune")

      assert id == a.id
      consistent!()
    end

    test "refuses a stale rollback and a rollback that would unpublish an address", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: first} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      {:ok, _} = Ledger.move(page.id, "/people/francois-marie", opts(ctx.human))

      assert {:error, {:stale, _}} = Ledger.rollback(first, opts(ctx.human))

      [%{operation_id: allocation} | _] = Ledger.history(page_id: page.id)

      assert {:error, {:stale, _}} = Ledger.rollback(allocation, opts(ctx.human))

      draft = subject_page!("people", "Candide", :person)
      {:ok, path} = Ledger.allocate(draft.id, "/people/candide", opts(ctx.importer))
      [%{operation_id: draft_allocation} | _] = Ledger.history(path_id: path.id)
      published!(Repo.get!(Page, draft.id))

      assert Ledger.rollback(draft_allocation, opts(ctx.human)) ==
               {:error, {:published_page_needs_canonical, draft.id}}

      consistent!()
    end

    test "an undone allocation stays reserved, unannounced, for its page to reclaim", ctx do
      page = subject_page!("people", "Voltaire", :person)
      other = subject_page!("people", "Voltaire (musician)", :person)
      {:ok, path} = Ledger.allocate(page.id, "/people/voltaire", opts(ctx.importer))
      [%{operation_id: allocation} | _] = Ledger.history(path_id: path.id)

      {:ok, _} = Ledger.rollback(allocation, opts(ctx.human, "held for review"))
      assert %Page{canonical_path_id: nil} = Repo.get!(Page, page.id)
      assert paths(page.id) == [{"/people/voltaire", :alias, page.id}]

      # Never published, so the reservation answers 404, not 410.
      assert %Resolution{outcome: :unavailable} = r = resolve("/people/voltaire")
      assert Resolution.http_status(r) == 404

      assert {:error, {:path_taken, %{kind: :alias}}} =
               Ledger.allocate(other.id, "/people/voltaire", opts(ctx.importer))

      assert {:ok, %PublicPath{id: id, kind: :canonical}} =
               Ledger.allocate(page.id, "/people/voltaire", opts(ctx.importer))

      assert id == path.id
      consistent!()
    end

    test "is refused once anything it changed has changed again, even back", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: first} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      {:ok, _} = Ledger.move(page.id, "/people/voltaire", opts(ctx.human))
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      # The same state as after the first move, reached by two later ones.
      assert {:error, {:stale, _}} = Ledger.rollback(first, opts(ctx.human))
      assert %Resolution{outcome: :canonical} = resolve("/people/arouet")
      consistent!()
    end

    test "undoes operations newest first, all the way back", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: first} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      {:ok, _} = Ledger.move(page.id, "/people/francois-marie", opts(ctx.human))

      [%{operation_id: second} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      assert {:error, {:stale, _}} = Ledger.rollback(first, opts(ctx.human))
      assert {:ok, ^second} = Ledger.rollback(second, opts(ctx.human))
      assert {:ok, ^first} = Ledger.rollback(first, opts(ctx.human))

      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")

      for old <- ["/people/arouet", "/people/francois-marie"] do
        assert %Resolution{outcome: :redirect, location: "/people/voltaire"} = resolve(old)
      end

      consistent!()
    end

    test "un-merges a merge chain from its last merge back", ctx do
      [a, b, c] =
        for path <- ["/people/arouet", "/people/voltaire", "/people/francois-marie-arouet"],
            do: live_page!("people", path, ctx.human, :person)

      {:ok, _} = Registry.merge([a.target_object_id], b.target_object_id, reason: "dup")
      {:ok, _} = Ledger.merge(a.id, b.id, opts(ctx.human))
      # The page's own merge row: history also lists merges that pointed into it.
      merge_of = fn page ->
        Enum.find(
          Ledger.history(page_id: page.id),
          &(&1.operation == :merge and &1.page_id == page.id)
        )
      end

      %{operation_id: a_into_b} = merge_of.(a)
      {:ok, _} = Registry.merge([b.target_object_id], c.target_object_id, reason: "dup")
      {:ok, _} = Ledger.merge(b.id, c.id, opts(ctx.human))
      %{operation_id: b_into_c} = merge_of.(b)

      assert {:error, {:stale, _}} = Ledger.rollback(a_into_b, opts(ctx.human))
      {:ok, _} = Ledger.rollback(b_into_c, opts(ctx.human))
      {:ok, _} = Ledger.rollback(a_into_b, opts(ctx.human))

      for {page, path} <- [
            {a, "/people/arouet"},
            {b, "/people/voltaire"},
            {c, "/people/francois-marie-arouet"}
          ] do
        assert %Resolution{outcome: :canonical, page: %{id: id}} = resolve(path)
        assert id == page.id

        assert %Page{lifecycle_state: :active, merged_into_page_id: nil} =
                 Repo.get!(Page, page.id)
      end

      consistent!()
    end

    test "a redone operation can be undone again", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: move} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      {:ok, _} = Ledger.rollback(move, opts(ctx.human, "undo"))

      %{operation_id: undo} =
        Enum.find(Ledger.history(page_id: page.id), &(&1.reverts_operation_id == move))

      {:ok, _} = Ledger.rollback(undo, opts(ctx.human, "redo"))
      assert %Resolution{outcome: :canonical} = resolve("/people/arouet")

      assert {:ok, ^move} = Ledger.rollback(move, opts(ctx.human, "undo again"))
      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")
      consistent!()
    end

    test "leaves an editorial revision alone and still undoes the route", ctx do
      page = live_page!("people", "/people/voltaire", ctx.human, :person)
      {:ok, _} = Ledger.move(page.id, "/people/arouet", opts(ctx.human))

      [%{operation_id: move} | _] =
        Ledger.history(path_id: Repo.get!(Page, page.id).canonical_path_id)

      {:ok, typo_fix} = Pages.add_revision(page.id, %{title: "Voltaire"}, [], ctx.human.id)

      assert {:ok, ^move} = Ledger.rollback(move, opts(ctx.human))
      assert %Page{current_revision_id: current} = Repo.get!(Page, page.id)
      assert current == typo_fix.id
      assert %Resolution{outcome: :canonical} = resolve("/people/voltaire")
      consistent!()
    end
  end
end
