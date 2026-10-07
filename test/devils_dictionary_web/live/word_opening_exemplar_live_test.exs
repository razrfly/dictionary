defmodule DevilsDictionaryWeb.WordOpeningExemplarLiveTest do
  @moduledoc """
  #212 Build 3: an exemplar in the curated opening, behind the development
  gate (`?opening=fixture`).

  The committed `coward` composition names two fictional people, by QIDs no
  Wikidata item has, under WordNet's *coward* sense as the dev corpus has it.
  This test makes both people, nominates both through
  `Contributions.propose/6`, and has a reviewer accept only the first, so
  every claim, review and review context is a real row. The opening holds
  them to the composition rules (`Curation.Eligibility`): the accepted one
  is a highlight with the six stages the examples card shows, and the
  nomination nobody accepted is not there.

  `async: false` because the offline check empties the provider registry,
  which is application-wide.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.{Examples, ExemplarFixtures, Lexicon, Repo, WordFixtures}
  alias DevilsDictionary.Curation.{ManualFixture, Opening}
  alias DevilsDictionary.Curation.Opening.Highlight
  alias DevilsDictionary.Examples.Provenance
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.Entity

  # As the committed composition names them.
  @accepted_qid "Q999999212"
  @pending_qid "Q999999213"
  @wordnet_key "5646b1030517f49f0ea250fece9285405dcf0da711fb5b7d47c9c7e76322aad3"
  @gloss "a person who shows fear or timidity"

  @stages ~w(source nominated model reviewed shown opening)

  setup do
    world = world!()
    coward = WordFixtures.word!(world, "coward", ["wordnet"], scope: nil)

    record =
      WordFixtures.record!(world, "wordnet",
        external_id: "oewn-09637077-n",
        content_hash: @wordnet_key
      )

    sense =
      WordFixtures.sense!(world, coward, "wordnet",
        record: record,
        external_id: "oewn-09637077-n#coward",
        group_key: "oewn-09637077-n",
        gloss: @gloss
      )

    pat = WordFixtures.concept!(@accepted_qid, "Pat Fixture", kind: :person)
    adverse = WordFixtures.concept!(@pending_qid, "Fixture Adverse Person", kind: :person)

    accepted = ExemplarFixtures.nominate!(world.contributor, pat, sense)
    ExemplarFixtures.decide!(world.reviewer, accepted)

    pending =
      ExemplarFixtures.nominate!(world.contributor, adverse, sense, nil, %{
        rationale: "an adverse fixture rationale"
      })

    Map.merge(world, %{
      coward: coward,
      sense: sense,
      pat: pat,
      adverse: adverse,
      accepted: accepted,
      pending: pending
    })
  end

  defp page, do: "coward" |> Lexicon.lookup() |> WordPage.build()

  # One element's text, its whitespace as a reader sees it.
  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, "id"))
    |> List.flatten()
  end

  describe "the opening, with the fixture asked for" do
    test "one accepted exemplar is a highlight, with the six stages the card shows", ctx do
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")
      tile = "#opening-highlight-1"

      assert has_element?(view, "#opening-fixture", "Development fixture")
      assert has_element?(view, "#{tile}-title", "Pat Fixture")
      assert has_element?(view, "#{tile}-cited", @gloss)
      assert has_element?(view, "#{tile}-rationale", "fixture rationale")

      # Six rows, in the card's order.
      assert ids(view, "#{tile}-stages > div[id^='opening-highlight-1-stage-']") ==
               Enum.map(@stages, &"opening-highlight-1-stage-#{&1}")

      # The four about the claim say, word for word, what the examples card
      # on the same page says about the same claim.
      card = "#examples-why-#{ctx.accepted.assertion_id}"

      for key <- ~w(source nominated model reviewed) do
        assert text(view, "#{tile}-stage-#{key} dd") == text(view, "#{card}-#{key} dd"),
               "the #{key} stage disagrees with the card"
      end

      assert has_element?(
               view,
               "#{tile}-stage-reviewed",
               "Accepted by #{actor!(ctx.reviewer).label}"
             )

      assert has_element?(view, "#{tile}-stage-nominated", "By #{actor!(ctx.contributor).label}")

      # The two about this placement say where it is, and claim no page.
      assert has_element?(
               view,
               "#{tile}-stage-shown",
               "Chosen for this opening by Claude Code (Opus 5.5), an AI model, " <>
                 "in a development fixture (version 1)."
             )

      assert has_element?(view, "#{tile}-stage-opening", "Not published.")

      # Its exact revisions name the claim, and inspect it.
      assert has_element?(view, "#opening-about-revision-1", "claim revision #{ctx.accepted.id}")

      assert has_element?(
               view,
               "#opening-about-revision-1 a[href='/connections/#{ctx.accepted.assertion_id}']"
             )
    end

    test "a nomination nobody has accepted does not appear, and its withholding names no one",
         ctx do
      {:ok, view, html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      refute has_element?(view, "#opening-highlight-2")

      assert has_element?(
               view,
               "#opening-about-withheld",
               "Highlight 2: it is not an example a reviewer has accepted."
             )

      refute html =~ "Fixture Adverse Person"
      refute html =~ "an adverse fixture rationale"
      refute html =~ @pending_qid

      # A contributor sees the nomination on its card, marked; the opening
      # still shows only what a reviewer accepted.
      conn = log_in_user(build_conn(), ctx.contributor.user)
      {:ok, view, _html} = live(conn, ~p"/on/coward?opening=fixture")

      assert has_element?(view, "#examples-ex-#{ctx.pending.assertion_id}")
      refute has_element?(view, "#opening-highlight-2")
    end

    test "it follows the review: accepted, it appears; rejected, it is withheld at once", ctx do
      ExemplarFixtures.decide!(ctx.reviewer, ctx.pending)
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      assert has_element?(view, "#opening-highlight-1-title", "Pat Fixture")
      assert has_element?(view, "#opening-highlight-2-title", "Fixture Adverse Person")

      ExemplarFixtures.decide!(ctx.reviewer, ctx.accepted, "rejected")
      {:ok, view, html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      refute has_element?(view, "#opening-highlight-1")
      assert has_element?(view, "#opening-highlight-2-title", "Fixture Adverse Person")

      assert has_element?(
               view,
               "#opening-about-withheld",
               "Highlight 1: it is not an example a reviewer has accepted."
             )

      refute html =~ "Pat Fixture"
    end

    test "without the parameter the page has no opening", _ctx do
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward")
      refute has_element?(view, "#opening")
    end
  end

  describe "the reader" do
    test "carries the card's own provenance; only the placement stages are the fixture's",
         ctx do
      ExemplarFixtures.offline!()

      assert %Opening{highlights: [%Highlight{kind: :exemplar} = highlight], withheld: withheld} =
               ManualFixture.opening(page())

      item =
        [ctx.coward.object_id]
        |> Examples.exemplars(:public)
        |> Enum.find(&(&1.claim.revision_id == ctx.accepted.id))

      card = Provenance.of(item, :public)
      claim_stages = [:id, :source, :nomination, :agent, :review, :featured]

      assert Map.take(highlight.provenance, claim_stages) == Map.take(card, claim_stages)

      assert %{
               kind: :fixture,
               composition: "fixture:coward",
               version: 1,
               selected_by: %{kind: :model, label: "Claude Code (Opus 5.5)"}
             } = highlight.provenance.selection

      assert highlight.provenance.publication == :none
      assert highlight.reference.object_id == ctx.pat.object_id
      assert highlight.reference.assertion_revision_id == ctx.accepted.id

      assert highlight.subject == %{
               kind: :entity,
               entity_kind: :person,
               qid: @accepted_qid,
               words: nil
             }

      # The nomination nobody accepted is withheld by the composition rule,
      # and nothing about it is in the highlight list.
      assert withheld == [%{role: :highlight, position: 2, reason: :claim_not_accepted}]
    end

    test "after a rejection, a new nomination of the same pair is the claim it reads", ctx do
      # A rejected claim holds nothing (`propose/6`), so the same person may
      # be nominated again; once that one is accepted, it is the one shown,
      # never the rejected claim before it.
      ExemplarFixtures.decide!(ctx.reviewer, ctx.accepted, "rejected")

      again =
        ExemplarFixtures.nominate!(ctx.contributor, ctx.pat, ctx.sense, nil, %{
          rationale: "nominated again"
        })

      ExemplarFixtures.decide!(ctx.reviewer, again)

      assert %Opening{highlights: [highlight]} = ManualFixture.opening(page())
      assert highlight.reference.assertion_revision_id == again.id
      assert highlight.claim.rationale == "nominated again"
    end

    test "holds the exemplar to the composition rules: a changed subject is withheld", ctx do
      # The context a reviewer accepted no longer describes what is shown
      # (decision 2): the opening withholds it, as a composition would.
      Repo.update_all(from(e in Entity, where: e.object_id == ^ctx.pat.object_id),
        set: [preferred_label: "Pat Fixture, renamed"]
      )

      assert %Opening{highlights: [], withheld: withheld} = ManualFixture.opening(page())

      assert withheld == [
               %{role: :highlight, position: 1, reason: :claim_context_changed},
               %{role: :highlight, position: 2, reason: :claim_not_accepted}
             ]
    end
  end
end
