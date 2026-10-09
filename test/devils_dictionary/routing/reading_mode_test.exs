defmodule DevilsDictionary.Routing.ReadingModeTest do
  @moduledoc """
  The resolver's two reading modes (#219 B1, and the 28 September re-audit's
  first correction): `:public` serves only published pages; `:internal` also
  serves drafts, marked as drafts by their state, and changes nothing. A
  withdrawn page is withheld in both, every lifecycle rule is the same in
  both, and an alias or equivalent spelling answers with its destination's
  outcome in the same mode — a public request never redirects to a draft.
  """
  # Not async: the sandbox holds each test's advisory path locks and
  # uncommitted unique paths, and these tests reuse addresses.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{Ledger, Page, Resolution, Resolver}

  setup do
    %{human: human!(), importer: importer!()}
  end

  test "public serves only published; internal also serves a draft, and neither writes", ctx do
    draft = subject_page!("nature", "Mars") |> allocated!("/nature/mars", ctx.importer)

    assert %Resolution{outcome: :unavailable} = Resolver.resolve("/nature/mars")
    assert %Resolution{outcome: :unavailable} = Resolver.resolve("/nature/mars", mode: :public)

    assert %Resolution{outcome: :canonical, page: %Page{publication_state: :draft}} =
             Resolver.resolve("/nature/mars", mode: :internal)

    assert Resolver.link(draft.id) == :error
    assert Resolver.link(draft.id, mode: :public) == :error
    assert Resolver.link(draft.id, mode: :internal) == {:ok, "/nature/mars"}
    assert %Resolution{outcome: :unavailable} = Resolver.resolve_page(draft.id)
    assert %Resolution{outcome: :canonical} = Resolver.resolve_page(draft.id, mode: :internal)

    # Reading internally approved and published nothing.
    assert Repo.reload!(draft).publication_state == :draft

    published = live_page!("nature", "/nature/venus", ctx.human)

    for mode <- [:public, :internal] do
      assert %Resolution{outcome: :canonical, page: %{id: id}} =
               Resolver.resolve("/nature/venus", mode: mode)

      assert id == published.id
    end
  end

  test "a withdrawn page is withheld in both modes", ctx do
    page = live_page!("nature", "/nature/pluto", ctx.human) |> withdrawn!()

    for mode <- [:public, :internal] do
      assert %Resolution{outcome: :unavailable} = Resolver.resolve("/nature/pluto", mode: mode)
      assert Resolver.link(page.id, mode: mode) == :error
    end
  end

  test "an equivalent spelling answers with its destination's outcome in the same mode", ctx do
    subject_page!("nature", "Mars") |> allocated!("/nature/mars", ctx.importer)

    for spelling <- ["/nature/Mars", "/nature/mars/", "/nature/MARS"] do
      assert %Resolution{outcome: :unavailable, location: nil} =
               Resolver.resolve(spelling, mode: :public)

      assert %Resolution{outcome: :redirect, location: "/nature/mars"} =
               Resolver.resolve(spelling, mode: :internal)
    end
  end

  test "an alias of a moved draft never redirects a public reader to it", ctx do
    draft = subject_page!("nature", "Mars") |> allocated!("/nature/mars", ctx.importer)

    {:ok, _} =
      Ledger.move(draft.id, "/nature/mars-planet", actor_id: ctx.human.id, reason: "qualified")

    assert %Resolution{outcome: :unavailable} = Resolver.resolve("/nature/mars", mode: :public)

    assert %Resolution{outcome: :redirect, location: "/nature/mars-planet"} =
             Resolver.resolve("/nature/mars", mode: :internal)

    # Published, the same alias is one hop for everyone.
    published!(draft)

    for mode <- [:public, :internal] do
      assert %Resolution{outcome: :redirect, location: "/nature/mars-planet"} =
               Resolver.resolve("/nature/mars", mode: mode)
    end
  end

  test "tombstones and retirement read the same in both modes", ctx do
    seen = live_page!("people", "/people/voltaire", ctx.human, :person)

    unseen =
      subject_page!("people", "Candide", :person) |> allocated!("/people/candide", ctx.human)

    for page <- [seen, unseen],
        do: {:ok, _} = Ledger.retire(page.id, actor_id: ctx.human.id, reason: "removed")

    for mode <- [:public, :internal] do
      # Gone is only news for a page the public saw; a draft's tombstone is
      # not, in either mode.
      assert %Resolution{outcome: :gone} = Resolver.resolve("/people/voltaire", mode: mode)
      assert %Resolution{outcome: :unavailable} = Resolver.resolve("/people/candide", mode: mode)
      assert %Resolution{outcome: :gone} = Resolver.resolve_page(seen.id, mode: mode)
      assert %Resolution{outcome: :unavailable} = Resolver.resolve_page(unseen.id, mode: mode)
    end
  end

  test "a choice's successors are resolved in the request's mode", ctx do
    [mercury, planet, element] =
      for path <- ~w(/nature/mercury /nature/mercury-planet /nature/mercury-element),
          do: live_page!("nature", path, ctx.human)

    {:ok, _} =
      DevilsDictionary.Registry.split(
        mercury.target_object_id,
        [planet.target_object_id, element.target_object_id],
        reason: "fixture"
      )

    {:ok, _} =
      Ledger.split(mercury.id, [planet.id, element.id], actor_id: ctx.human.id, reason: "fixture")

    # One successor withdrawn: the choice still names it, and says it serves
    # nothing, in either mode.
    withdrawn!(element)

    for mode <- [:public, :internal] do
      assert %Resolution{outcome: :choice, successors: [first, second]} =
               Resolver.resolve("/nature/mercury", mode: mode)

      assert %{resolution: %Resolution{outcome: :canonical}} = first
      assert %{resolution: %Resolution{outcome: :unavailable}} = second
    end
  end

  test "an unknown mode is refused rather than read as either" do
    assert_raise ArgumentError, ~r/unknown reading mode/, fn ->
      Resolver.resolve("/nature/mars", mode: :preview)
    end

    assert_raise ArgumentError, fn -> Resolver.link(1, mode: "internal") end
  end
end
