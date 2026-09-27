defmodule DevilsDictionary.Routing.OnPageTest do
  @moduledoc """
  An authored overview and the words of an On page (#219 B1, and the
  28 September re-audit's second correction): associated by identity — a
  `supplies_lexical_material` membership naming one of the page's lexemes or
  senses — never by a shared label or slug; found only at its allocated
  address; shown only as the reading mode allows. Every row here is a CI
  fixture.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, lexeme!: 1, lexeme!: 2]

  alias DevilsDictionary.Routing.OnPage

  setup do
    %{sources: sources} = DevilsDictionary.Fixtures.seed_catalog!()
    %{human: human!(), sources: sources}
  end

  test "an overview naming the page's words is their treatment; one naming others is not", ctx do
    mars = lexeme!("Mars")
    martian = lexeme!("martian", "adjective")

    about_mars =
      overview!("On Mars", "/on/mars", [{:supplies_lexical_material, mars.object_id}],
        author: ctx.human,
        published: true
      )

    assert %{associated?: true, page: %{id: id}} =
             OnPage.overview("/on/mars", [mars.object_id], :public)

    assert id == about_mars.id

    # The same address read for words it does not name — an unrelated lexeme
    # that shares the spelling — is a separate thing, not their treatment.
    assert %{associated?: false} = OnPage.overview("/on/mars", [martian.object_id], :public)

    # An overview is found at its address only: nothing re-slugifies a lemma.
    assert OnPage.overview("/on/Mars-planet", [mars.object_id], :public) == nil
  end

  test "a sense membership associates the sense's word", ctx do
    polish = lexeme!("polish", "verb")
    sense = DevilsDictionary.WordFixtures.sense!(ctx, polish, "wordnet")

    overview!("On polishing", "/on/polish", [{:supplies_lexical_material, sense.object_id}],
      author: ctx.human,
      published: true
    )

    assert %{associated?: true} = OnPage.overview("/on/polish", [polish.object_id], :public)
  end

  test "a draft overview is served only internally; a withdrawn one never", ctx do
    word = lexeme!("mercury")

    draft =
      overview!("On Mercury", "/on/mercury", [{:supplies_lexical_material, word.object_id}],
        author: ctx.human
      )

    assert OnPage.overview("/on/mercury", [word.object_id], :public) == nil
    assert %{draft?: true} = OnPage.overview("/on/mercury", [word.object_id], :internal)

    withdrawn!(draft)

    for mode <- [:public, :internal],
        do: assert(OnPage.overview("/on/mercury", [word.object_id], mode) == nil)
  end

  test "an equivalent spelling of a served overview is a redirect for the caller to follow",
       ctx do
    word = lexeme!("venus")

    overview!("On Venus", "/on/venus", [{:supplies_lexical_material, word.object_id}],
      author: ctx.human,
      published: true
    )

    assert %{resolution: %{outcome: :redirect, location: "/on/venus"}} =
             OnPage.overview("/on/Venus", [word.object_id], :public)
  end

  test "lexical pages link the overviews that name their words, at their addresses", ctx do
    cpp = lexeme!("C++", "name")
    c = lexeme!("c", "letter")

    on_cpp =
      overview!("On C++", "/on/c-plus-plus", [{:supplies_lexical_material, cpp.object_id}],
        author: ctx.human,
        published: true
      )

    draft =
      overview!(
        "On C++ (draft)",
        "/on/c-plus-plus-history",
        [{:supplies_lexical_material, cpp.object_id}], author: ctx.human)

    assert [%{page_id: id, path: "/on/c-plus-plus", title: "On C++"}] =
             OnPage.linked([cpp.object_id, c.object_id], :public)

    assert id == on_cpp.id

    internal = OnPage.linked([cpp.object_id, c.object_id], :internal)
    assert Enum.map(internal, & &1.page_id) |> Enum.sort() == Enum.sort([on_cpp.id, draft.id])
    assert Enum.find(internal, &(&1.page_id == draft.id)).draft?

    # The page being read is not linked to itself; `c` alone names none.
    assert OnPage.linked([cpp.object_id], :public, on_cpp.id) == []
    assert OnPage.linked([c.object_id], :internal) == []
  end

  test "members keep their order and relationship; the unshowable are withheld, not replaced",
       ctx do
    mars = lexeme!("Mars")
    ares = subject!("Ares", "subjects", fixture: "#219 test fixture").entity
    candy = subject!("Mars bar", "subjects").entity

    withdrawn_page =
      subject!("Mars (withdrawn)", "nature",
        path: "/nature/mars-withdrawn",
        published: true,
        actor: ctx.human
      ).page

    withdrawn!(withdrawn_page)
    gone = subject!("Mars (retired)", "nature").entity
    {:ok, _} = DevilsDictionary.Registry.retire(gone.object_id, reason: "fixture")

    page =
      overview!(
        "On Mars",
        "/on/mars",
        [
          {:supplies_lexical_material, mars.object_id},
          {:discusses_subject, ares.object_id},
          {:editorial_association, candy.object_id},
          {:discusses_subject, {:page, withdrawn_page.id}},
          {:discusses_subject, gone.object_id}
        ],
        author: ctx.human,
        published: true
      )

    %{members: members} = OnPage.overview("/on/mars", [mars.object_id], :public)

    assert [
             %{kind: :word, relationship: :supplies_lexical_material, position: 1},
             %{
               kind: :subject,
               relationship: :discusses_subject,
               object_id: ares_id,
               label: "Ares"
             },
             %{kind: :subject, relationship: :editorial_association, object_id: candy_id},
             %{kind: :withheld, reason: :withdrawn},
             %{kind: :withheld, reason: :retired}
           ] = members

    assert {ares_id, candy_id} == {ares.object_id, candy.object_id}
    assert page.id
  end
end
