defmodule DevilsDictionaryWeb.WordOpeningExemplarLiveTest do
  @moduledoc """
  #212 Build 3: an exemplar in the curated opening, behind the development
  gate (`?opening=fixture`).

  The committed `coward` composition names three fictional subjects, by
  QIDs no Wikidata item has, under WordNet's *coward* sense as the dev corpus
  has it: two people and a work. This test makes all three and nominates
  each through `Contributions.propose/6`. A reviewer accepts only the first
  person, so every claim, review and review context is a real row. The
  opening holds them to the composition rules (`Curation.Eligibility`): the
  accepted one is a highlight with the six stages the examples card shows,
  and neither nomination nobody accepted is there, though the public still
  sees the pending work's card (#190's person-only gate).

  `async: false` because the offline check empties the provider registry,
  which is application-wide.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.{Claims, Examples, ExemplarFixtures, Lexicon, Registry, Repo}
  alias DevilsDictionary.WordFixtures
  alias DevilsDictionary.Curation.{ManualFixture, Opening}
  alias DevilsDictionary.Curation.Opening.Highlight
  alias DevilsDictionary.Examples.Provenance
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.Entity

  # As the committed composition names them.
  @accepted_qid "Q999999212"
  @pending_qid "Q999999213"
  @work_qid "Q999999214"
  @wordnet_key "5646b1030517f49f0ea250fece9285405dcf0da711fb5b7d47c9c7e76322aad3"
  @gloss "a person who shows fear or timidity"

  @stages ~w(source nominated model reviewed shown opening)
  @not_accepted "it is not an example a reviewer has accepted."

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

    {:ok, work} =
      Registry.create_work(%{preferred_label: "Fixture Pending Work", work_kind: "artwork"})

    {:ok, _} = Registry.add_external_id(work.object_id, "wikidata", @work_qid)

    accepted = ExemplarFixtures.nominate!(world.contributor, pat, sense)
    ExemplarFixtures.decide!(world.reviewer, accepted)

    pending =
      ExemplarFixtures.nominate!(world.contributor, adverse, sense, nil, %{
        rationale: "an adverse fixture rationale"
      })

    pending_work =
      ExemplarFixtures.nominate!(world.contributor, work, sense, [], %{
        rationale: "a pending work's rationale"
      })

    Map.merge(world, %{
      coward: coward,
      sense: sense,
      pat: pat,
      adverse: adverse,
      work: work,
      accepted: accepted,
      pending: pending,
      pending_work: pending_work
    })
  end

  defp page, do: "coward" |> Lexicon.lookup() |> WordPage.build()

  defp card(revision), do: "#examples-ex-#{revision.assertion_id}"

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

    test "a nomination nobody has accepted does not appear, whatever its subject", ctx do
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      # The pending work keeps its public card: #190's person-only gate is
      # the card's, unchanged. The opening's own gate keeps it out.
      assert has_element?(view, card(ctx.pending_work), "Fixture Pending Work")
      refute has_element?(view, card(ctx.pending))

      refute has_element?(view, "#opening-highlight-2")
      refute has_element?(view, "#opening-highlight-3")

      for words <- [
            "Fixture Pending Work",
            "a pending work's rationale",
            "Fixture Adverse Person"
          ] do
        refute has_element?(view, "#opening", words)
      end

      # Withheld, in one sentence that names no one and says nothing of a
      # review that is waiting.
      assert has_element?(view, "#opening-about-withheld", "Highlight 2: #{@not_accepted}")
      assert has_element?(view, "#opening-about-withheld", "Highlight 3: #{@not_accepted}")

      # A contributor sees both nominations on their cards, marked; the
      # opening still shows only what a reviewer accepted.
      conn = log_in_user(build_conn(), ctx.contributor.user)
      {:ok, view, _html} = live(conn, ~p"/on/coward?opening=fixture")

      assert has_element?(view, card(ctx.pending))
      assert has_element?(view, card(ctx.pending_work))
      refute has_element?(view, "#opening-highlight-2")
      refute has_element?(view, "#opening-highlight-3")
    end

    test "it follows the review: accepted, it appears; disputed or rejected, it is withheld",
         ctx do
      ExemplarFixtures.decide!(ctx.reviewer, ctx.pending_work)
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      assert has_element?(view, "#opening-highlight-1-title", "Pat Fixture")
      assert has_element?(view, "#opening-highlight-3-title", "Fixture Pending Work")
      assert has_element?(view, "#opening-highlight-3", "Example · work")

      # Disputed after it was accepted: no longer accepted, so withheld.
      ExemplarFixtures.decide!(ctx.reviewer, ctx.accepted, "disputed")
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      refute has_element?(view, "#opening-highlight-1")
      assert has_element?(view, "#opening-about-withheld", "Highlight 1: #{@not_accepted}")

      ExemplarFixtures.decide!(ctx.reviewer, ctx.pending_work, "rejected")
      {:ok, view, _html} = live(build_conn(), ~p"/on/coward?opening=fixture")

      refute has_element?(view, "#opening")
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
      assert highlight.register == nil
      assert highlight.credits == []

      assert %{kind: :entity, entity_kind: :person, qid: @accepted_qid, words: nil, html: nil} =
               highlight.subject

      # The nominator by label only: no account id reaches the view model.
      assert highlight.claim.nominated_by == %{label: actor!(ctx.contributor).label}

      # Both nominations nobody accepted are withheld by the composition rule,
      # and nothing about either is in the highlight list.
      assert withheld == [
               %{role: :highlight, position: 2, reason: :claim_not_accepted},
               %{role: :highlight, position: 3, reason: :claim_not_accepted}
             ]
    end

    test "an accepted claim is preferred to a pending duplicate of the same pair", ctx do
      # `propose/6` holds a second nomination of a pair, but a row written
      # another way (a legacy claim, an import) can stand beside the first.
      {:ok, later} =
        Claims.assert(ctx.adverse.object_id, "illustrates", ctx.sense.object_id, %{
          rationale: "a later claim of the same pair"
        })

      later = Claims.current_revision(later.id)
      ExemplarFixtures.decide!(ctx.reviewer, later)

      assert %Opening{highlights: [_pat, highlight]} = ManualFixture.opening(page())
      assert highlight.position == 2
      assert highlight.reference.assertion_revision_id == later.id
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
               %{role: :highlight, position: 2, reason: :claim_not_accepted},
               %{role: :highlight, position: 3, reason: :claim_not_accepted}
             ]
    end
  end

  describe "a quotation cited as an example" do
    setup ctx do
      shelf = ExemplarFixtures.shelved_quotation!(ctx, ctx.coward, "Run away! <Run> away!")
      claim = ExemplarFixtures.nominate!(ctx.contributor, shelf.quotation, ctx.sense, [])
      ExemplarFixtures.decide!(ctx.reviewer, claim)
      Map.merge(ctx, %{shelf: shelf, claim: claim})
    end

    # A composition naming one exemplar, the way the committed file names
    # one: the subject's source identity and the meaning's sense.
    defp fixture(content_id) do
      [coward] = Enum.filter(ManualFixture.read()["compositions"], &(&1["key"] == "coward"))

      highlight = %{
        "item" => %{"exemplar" => %{"subject" => %{"content" => source_ref(content_id)}}},
        "meaning" => hd(coward["highlights"])["meaning"]
      }

      %{"compositions" => [%{coward | "highlights" => [highlight]}]}
    end

    # A source record of its own, so the reference names one item.
    defp record_revision!(ctx) do
      sources = Map.put(ctx.sources, "wikiquote", ctx.shelf.source)
      record = WordFixtures.record!(%{ctx | sources: sources}, "wikiquote")

      Repo.one!(
        from r in "source_record_revisions", where: r.source_record_id == ^record.id, select: r.id
      )
    end

    defp source_ref(content_id) do
      Repo.one(
        from cr in "content_revisions",
          join: srr in "source_record_revisions",
          on: srr.id == cr.source_record_revision_id,
          join: rec in "source_records",
          on: rec.id == srr.source_record_id,
          join: s in "sources",
          on: s.id == rec.source_id,
          where: cr.content_id == ^content_id and cr.is_current,
          select: %{
            "source" => s.slug,
            "record" => rec.external_id,
            "revision_key" => srr.revision_key
          }
      )
    end

    test "is shown by its pinned words, as a sourced quotation, with its source's credit and licence",
         ctx do
      opening = ManualFixture.opening(page(), fixtures: fixture(ctx.shelf.quotation.object_id))

      assert %Opening{highlights: [%Highlight{kind: :exemplar} = highlight], withheld: []} =
               opening

      assert highlight.register == :quotation
      assert highlight.reference.content_revision_id
      assert highlight.subject.words == "Run away! <Run> away!"

      assert Enum.map(highlight.credits, &{&1.role, &1.required?}) ==
               [{:source, true}, {:rights, true}]

      html = render_component(&DevilsDictionaryWeb.Opening.section/1, opening: opening)
      doc = LazyHTML.from_fragment(html)

      # Plain text is shown as written, escaped; the credits are on the tile,
      # not only in the disclosure.
      assert doc |> LazyHTML.query("#opening-highlight-1-text") |> LazyHTML.text() =~
               "Run away! <Run> away!"

      assert doc |> LazyHTML.query("#opening-highlight-1-text run") |> Enum.count() == 0

      assert doc |> LazyHTML.query("#opening-highlight-1-register") |> LazyHTML.text() =~
               "Sourced quotation"

      credits = doc |> LazyHTML.query("#opening-highlight-1-credits") |> LazyHTML.text()
      assert credits =~ ctx.shelf.source.license
      assert credits =~ "Quoted in"

      assert doc
             |> LazyHTML.query("#opening-highlight-1-title[href^='/evidence/content/']")
             |> Enum.count() == 1
    end

    test "a passage stored as Markdown is rendered, never shown as markup", ctx do
      {:ok, passage} =
        Registry.create_content(%{
          content_kind: :passage,
          source_id: ctx.shelf.source.id,
          headword: "Fixture passage",
          body: "He *ran* away.",
          body_format: :markdown,
          source_record_revision_id: record_revision!(ctx)
        })

      claim = ExemplarFixtures.nominate!(ctx.contributor, passage, ctx.sense, [])
      ExemplarFixtures.decide!(ctx.reviewer, claim)

      opening = ManualFixture.opening(page(), fixtures: fixture(passage.object_id))
      assert %Opening{highlights: [%Highlight{register: :quotation}]} = opening

      html = render_component(&DevilsDictionaryWeb.Opening.section/1, opening: opening)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#opening-highlight-1-text em") |> LazyHTML.text() == "ran"

      assert doc |> LazyHTML.query("#opening-highlight-1") |> LazyHTML.text() =~
               "Example · passage"
    end

    test "an image cited as an example is withheld: the opening cannot draw one yet", ctx do
      {:ok, image} =
        Registry.create_content(%{
          content_kind: :image,
          source_id: ctx.shelf.source.id,
          headword: "Fixture image",
          body: "A fixture image's caption.",
          source_record_revision_id: record_revision!(ctx)
        })

      claim = ExemplarFixtures.nominate!(ctx.contributor, image, ctx.sense, [])
      ExemplarFixtures.decide!(ctx.reviewer, claim)

      assert %Opening{highlights: [], withheld: withheld} =
               ManualFixture.opening(page(), fixtures: fixture(image.object_id))

      assert withheld == [%{role: :highlight, position: 1, reason: :unsupported_subject}]
    end
  end
end
