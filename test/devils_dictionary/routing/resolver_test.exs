defmodule DevilsDictionary.Routing.ResolverTest do
  @moduledoc """
  The resolver's explicit results (ADR 0004 §6). HTTP is Stage 3; these pin
  the outcome, the destination and the status each outcome will be served
  with, by exact page identity.
  """
  # Not async: the sandbox holds each test's transaction — and so its
  # advisory path locks and uncommitted unique paths — for the whole test, and
  # these tests reuse addresses such as /people/voltaire.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{Address, Ledger, Page, PublicPath, Resolution, Resolver}

  setup do
    %{human: human!()}
  end

  defp resolve(raw), do: Resolver.resolve(raw)

  test "a canonical resolves exactly once; every equivalent spelling is one 301 to it", ctx do
    page = live_page!("people", "/people/чехов", ctx.human, :person)
    canonical = Address.encode("/people/чехов")

    assert %Resolution{outcome: :canonical, page: %{id: id}} = r = resolve(canonical)
    assert id == page.id and Resolution.http_status(r) == 200

    for variant <- [
          Address.encode("/people/Чехов"),
          canonical <> "/",
          String.downcase(canonical)
        ] do
      assert %Resolution{outcome: :redirect, location: "/people/чехов", page: %{id: ^id}} =
               r = resolve(variant)

      assert Resolution.http_status(r) == 301
      assert Address.encode(r.location) == canonical
    end
  end

  test "C++, C+ and c are three addresses for three pages", ctx do
    pages =
      for label <- ["C++", "C+", "c"] do
        path = "/concepts/" <> DevilsDictionary.Routing.Policy.slug(label)
        {path, live_page!("concepts", path, ctx.human).id}
      end

    for {path, id} <- pages do
      assert %Resolution{outcome: :canonical, page: %{id: ^id}} = resolve(path)
    end

    [_, _, {"/concepts/c", c}] = pages

    assert %Resolution{outcome: :redirect, location: "/concepts/c", page: %{id: ^c}} =
             resolve("/concepts/C")

    assert %Resolution{outcome: :missing} = resolve("/concepts/c%2B%2B")
  end

  test "an unknown address or id is missing, never a near match", ctx do
    live_page!("people", "/people/voltaire", ctx.human, :person)

    draft =
      subject_page!("people", "Candide", :person) |> allocated!("/people/candide", ctx.human)

    for {raw, outcome, status} <- [
          {"/people/voltair", :missing, 404},
          {"/people/voltaire-2", :missing, 404},
          {"/users/settings", :missing, 404},
          {"/people/candide", :unavailable, 404},
          {"/people/%E0%A4%A", :invalid, 400},
          {"/people/..%2Fadmin", :invalid, 400}
        ] do
      assert %Resolution{outcome: ^outcome} = r = resolve(raw)
      assert Resolution.http_status(r) == status, raw
    end

    assert %Resolution{outcome: :unavailable} = Resolver.resolve_page(draft.id)
    assert %Resolution{outcome: :missing} = Resolver.resolve_page(-1)
    assert Resolver.link(-1) == :error
    assert Resolver.link(draft.id) == :error
  end

  test "link/1 follows an exact id, through a merge, and not past a retirement", ctx do
    page = live_page!("people", "/people/чехов", ctx.human, :person)
    assert Resolver.link(page.id) == {:ok, Address.encode("/people/чехов")}

    on = overview_page!() |> allocated!("/on/mercury", ctx.human) |> published!()
    duplicate = overview_page!() |> allocated!("/on/mercury-myths", ctx.human) |> published!()
    {:ok, _} = Ledger.merge(duplicate.id, on.id, actor_id: ctx.human.id, reason: "one treatment")
    assert Resolver.link(duplicate.id) == {:ok, "/on/mercury"}

    {:ok, _} = Ledger.retire(on.id, actor_id: ctx.human.id, reason: "withdrawn")
    assert Resolver.link(on.id) == :error
    assert %Resolution{outcome: :gone} = Resolver.resolve_page(duplicate.id)
  end

  test "a choice expands its own successors, not theirs", ctx do
    [mercury, planet, element, inner, outer] =
      for path <- ~w(/nature/mercury /nature/mercury-planet /nature/mercury-element
                     /nature/mercury-inner /nature/mercury-outer),
          do: live_page!("nature", path, ctx.human)

    split = fn page, successors ->
      {:ok, _} =
        DevilsDictionary.Registry.split(
          page.target_object_id,
          Enum.map(successors, & &1.target_object_id),
          reason: "fixture"
        )

      {:ok, _} =
        Ledger.split(page.id, Enum.map(successors, & &1.id),
          actor_id: ctx.human.id,
          reason: "fixture"
        )
    end

    split.(mercury, [planet, element])
    split.(planet, [inner, outer])

    assert %Resolution{outcome: :choice, successors: [first, second]} = resolve("/nature/mercury")
    assert %{resolution: %Resolution{outcome: :choice, successors: []}} = first
    assert %{resolution: %Resolution{outcome: :canonical}} = second
  end

  describe "corrupt state is reported, never guessed" do
    setup do
      page = %Page{
        id: 1,
        lifecycle_state: :active,
        publication_state: :published,
        canonical_path_id: 10
      }

      canonical = %PublicPath{
        id: 10,
        path: "/people/voltaire",
        kind: :canonical,
        destination_page_id: 1
      }

      %{page: page, canonical: canonical}
    end

    test "an alias to a merged page, a mismatched pointer, a published page without a canonical",
         ctx do
      alias_path = %{ctx.canonical | id: 11, path: "/people/arouet", kind: :alias}

      for {path, page, canonical, reason} <- [
            {alias_path, %{ctx.page | lifecycle_state: :merged}, nil, :path_on_merged_page},
            {alias_path, ctx.page, %{ctx.canonical | kind: :alias}, :canonical_pointer_mismatch},
            {alias_path, ctx.page, %{ctx.canonical | destination_page_id: 2},
             :canonical_pointer_mismatch},
            {alias_path, %{ctx.page | canonical_path_id: nil}, nil,
             :published_page_without_canonical},
            {ctx.canonical, %{ctx.page | lifecycle_state: :retired}, ctx.canonical,
             :live_path_on_retired_page}
          ] do
        assert %Resolution{
                 outcome: :corrupt,
                 reason: ^reason,
                 location: nil,
                 diagnostics: diagnostics
               } =
                 r = Resolver.decide(path, page, canonical, true)

        assert diagnostics.path_id == path.id and diagnostics.page_id == page.id
        assert Resolution.http_status(r) == 500
      end
    end
  end
end
