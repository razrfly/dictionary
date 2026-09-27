defmodule DevilsDictionary.Routing.SubjectsTest do
  @moduledoc """
  The Subjects section's one bounded read (#219 B3): each card's state from
  its current decision and page, in the reading mode; curated members in
  their stored order, never truncated or reordered; discovered subjects
  deduplicated by identity, matched by name after NFC and case folding,
  sorted addressed first then by family, label and id, and capped with the
  total kept. Mars, Mercury and Café here are CI fixtures, not corpus rows.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, importer!: 0]

  alias DevilsDictionary.Registry
  alias DevilsDictionary.Routing.Subjects

  setup do
    %{human: human!(), importer: importer!()}
  end

  defp cards(curated, discovered, lemmas, mode, opts \\ []),
    do: Subjects.cards(curated, discovered, lemmas, mode, opts)

  defp by_id(cards), do: Map.new(cards, &{&1.object_id, &1})

  test "every card state, in both modes", ctx do
    published =
      subject!("Mercury", "nature", path: "/nature/mercury", published: true, actor: ctx.human)

    draft = subject!("Mercury", "subjects", path: "/subjects/mercury", actor: ctx.importer)

    withdrawn =
      subject!("Mercury", "works", path: "/works/mercury", published: true, actor: ctx.human)

    withdrawn!(withdrawn.page)
    mapped = subject!("Mercury", "concepts")
    review = subject!("Mercury", "nature", status: :needs_review, candidates: ["nature", "works"])
    unclassified = subject!("Mercury", "nature", status: :none, page: false)

    public = cards([], [], ["Mercury"], :public) |> Map.fetch!(:discovered) |> by_id()
    internal = cards([], [], ["Mercury"], :internal) |> Map.fetch!(:discovered) |> by_id()

    p = public[published.entity.object_id]

    assert {p.state, p.path, p.family, p.draft?} ==
             {:addressed, "/nature/mercury", "nature", false}

    assert internal[published.entity.object_id].state == :addressed

    d = public[draft.entity.object_id]
    assert {d.state, d.draft?} == {:not_yet_public, false}
    assert d.path == "/entities/#{draft.entity.object_id}/mercury"
    di = internal[draft.entity.object_id]
    assert {di.state, di.path, di.draft?} == {:addressed, "/subjects/mercury", true}

    for mode_cards <- [public, internal] do
      w = mode_cards[withdrawn.entity.object_id]
      assert {w.state, w.path} == {:withdrawn, "/entities/#{withdrawn.entity.object_id}/mercury"}

      m = mode_cards[mapped.entity.object_id]
      assert {m.state, m.family, m.address} == {:no_address, "concepts", nil}

      r = mode_cards[review.entity.object_id]
      assert {r.state, r.candidate_families} == {:awaiting_review, ["nature", "works"]}

      assert mode_cards[unclassified.entity.object_id].state == :unclassified
    end
  end

  test "curated members keep their order and are never capped; the inactive are withheld", ctx do
    subjects = for label <- ~w(Zeta Alpha Mu), do: subject!(label, "concepts").entity
    gone = subject!("Retired", "concepts").entity

    {:ok, _} =
      DevilsDictionary.Registry.retire(gone.object_id, reason: "fixture")

    ids = Enum.map(subjects, & &1.object_id)

    result = cards(ids ++ [gone.object_id], [], [], :public, limit: 1)

    assert Enum.map(Enum.take(result.curated, 3), & &1.object_id) == ids
    assert List.last(result.curated) == {:withheld, gone.object_id}
    assert result.discovered == []
    _ = ctx
  end

  test "discovery is by identity and by folded name, never merging two things with one label",
       ctx do
    planet =
      subject!("Mars", "nature", path: "/nature/mars", published: true, actor: ctx.human).entity

    deity = subject!("Mars", "subjects", fixture: "#219 test fixture").entity
    upper = subject!("MARS", "works", kind: :work).entity
    other = subject!("Marshmallow", "subjects").entity
    retired = subject!("Mars", "concepts").entity
    {:ok, _} = Registry.retire(retired.object_id, reason: "fixture")

    # A recorded name that differs from the preferred label still matches.
    named = subject!("Roman war god", "subjects").entity
    {:ok, _} = Registry.add_name(named.object_id, "Mars", %{name_kind: "alias"})

    # Curated already: not shown twice.
    result = cards([deity.object_id], [planet.object_id], ["mars"], :public)
    discovered = Enum.map(result.discovered, & &1.object_id)

    assert planet.object_id in discovered
    assert upper.object_id in discovered
    assert named.object_id in discovered
    refute deity.object_id in discovered
    refute other.object_id in discovered
    refute retired.object_id in discovered
    assert length(discovered) == length(Enum.uniq(discovered))

    # The fixture carries its mark.
    assert [%{fixture: "#219 test fixture"}] = result.curated

    # Addressed first.
    assert hd(result.discovered).object_id == planet.object_id
  end

  test "labels are matched after NFC and case folding, in either stored form", _ctx do
    decomposed = subject!("Café", "concepts").entity
    composed = subject!("CAFÉ", "subjects").entity

    for lemma <- ["café", "Café", "CAFÉ"] do
      ids = cards([], [], [lemma], :public).discovered |> Enum.map(& &1.object_id)
      assert decomposed.object_id in ids, lemma
      assert composed.object_id in ids, lemma
    end

    # LIKE's own metacharacters in a lemma are text, not patterns.
    percent = subject!("100%", "concepts").entity
    assert [%{object_id: id}] = cards([], [], ["100%"], :public).discovered
    assert id == percent.object_id
    assert cards([], [], ["10_%"], :public).discovered == []
  end

  test "discovery is capped deterministically and the total is kept", ctx do
    for i <- 1..5, do: subject!("Echo", "concepts", description: "#{i}")

    addressed =
      subject!("Echo", "works",
        kind: :work,
        path: "/works/echo",
        published: true,
        actor: ctx.human
      )

    first = cards([], [], ["echo"], :public, limit: 3)
    again = cards([], [], ["echo"], :public, limit: 3)

    assert first.discovered_total == 6
    assert length(first.discovered) == 3

    assert Enum.map(first.discovered, & &1.object_id) ==
             Enum.map(again.discovered, & &1.object_id)

    assert hd(first.discovered).object_id == addressed.entity.object_id

    # Among equals, by id.
    rest = first.discovered |> tl() |> Enum.map(& &1.object_id)
    assert rest == Enum.sort(rest)
  end

  test "an edition's page counts, with its address in Works", ctx do
    edition =
      subject!("Project Gutenberg #972", "works",
        kind: :edition,
        path: "/works/project-gutenberg-sharp-972",
        published: true,
        actor: ctx.human
      )

    assert [card] = cards([edition.entity.object_id], [], [], :public).curated
    assert {card.state, card.role, card.family} == {:addressed, :edition, "works"}
    assert card.path == "/works/project-gutenberg-sharp-972"
  end
end
