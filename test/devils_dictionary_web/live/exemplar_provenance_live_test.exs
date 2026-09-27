defmodule DevilsDictionaryWeb.ExemplarProvenanceLiveTest do
  @moduledoc """
  #212 build 2 on the page: the exemplar card's "Why this example is here",
  the person page's "featured in the opening of…" line, the connect form's
  record of the shelf it was prefilled from, and what the public never sees.

  Every subject is a fixture. The adverse person is fictional: someone
  nominated under *coward* whom the public must not see until a reviewer
  accepts it.

  `async: false` because the discovery-path test empties the provider
  registry, which is application-wide.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.{Claims, Discovery, ExemplarFixtures, Registry, Repo, WordFixtures}
  alias DevilsDictionary.Claims.{Assertion, Connection}
  alias DevilsDictionary.Curation.{Compositions, Published, Publications, Reviews}
  alias DevilsDictionaryWeb.ExampleProvenance

  # The pages are drawn for *coward*, a WordNet word with one sense and no
  # Bierce entry, so its compositions have no lead. They are made under the
  # enabled global default, the only configuration ever listed.
  setup do
    world = world!()
    {config, _version} = enabled_default!(world.reviewer)
    coward = WordFixtures.word!(world, "coward", ["wordnet"], scope: nil)

    sense =
      WordFixtures.sense!(world, coward, "wordnet", gloss: "a person who shows fear or timidity")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [coward.object_id],
        language_tag: "en",
        reason: "curate coward"
      })

    Map.merge(world, %{
      coward: coward,
      sense: sense,
      composition: composition,
      person: ExemplarFixtures.person!()
    })
  end

  defp decide!(ctx, revision, decision \\ "accepted"),
    do: ExemplarFixtures.decide!(ctx.reviewer, revision, decision)

  # The reviewer authors the composition, so its selection's actor is not
  # the nomination's (C5).
  defp publish!(ctx, revision) do
    {:ok, version} =
      Compositions.create_version(ctx.reviewer, ctx.composition.id, %{
        lead: nil,
        highlights: [
          %{
            kind: :exemplar,
            assertion_revision_id: revision.id,
            meaning: {:sense_revision, Registry.current_sense_revision(ctx.sense.object_id).id}
          }
        ],
        reason: "an example of coward",
        expected_parent: nil
      })

    {:ok, _} =
      Reviews.decide(ctx.reviewer, version.id, :accepted, reason: "fine", idempotency_key: key())

    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "ship it",
        idempotency_key: key(),
        expected_pointer: nil
      )

    settle!()
    receipt
  end

  defp why(assertion_id), do: "#examples-why-#{assertion_id}"
  defp card(assertion_id), do: "#examples-ex-#{assertion_id}"

  defp person_path(person),
    do: ~p"/entities/#{person.object_id}/#{Connection.slugify(person.preferred_label)}"

  describe "Why this example is here" do
    test "six rows from the records, and the published selection, which no page shows yet",
         ctx do
      claim = ExemplarFixtures.nominate!(ctx.contributor, ctx.person, ctx.sense)
      review = decide!(ctx, claim)
      nominator = actor!(ctx.contributor).label
      reviewer = actor!(ctx.reviewer).label
      nominated_on = ExampleProvenance.date(Repo.get!(Assertion, claim.assertion_id).inserted_at)
      id = claim.assertion_id

      {:ok, live, _html} = live(build_conn(), ~p"/define/coward")

      assert has_element?(live, "#{card(id)} #{why(id)} summary", "Why this example is here")
      assert has_element?(live, "#{why(id)}-source", "Not listed by a source.")

      assert has_element?(
               live,
               "#{why(id)}-nominated",
               "By #{nominator}, through the connect form, on #{nominated_on}"
             )

      assert has_element?(live, "#{why(id)}-model", "None involved.")

      assert has_element?(
               live,
               "#{why(id)}-reviewed",
               "Accepted by #{reviewer} on #{ExampleProvenance.date(review.inserted_at)}."
             )

      assert has_element?(live, "#{why(id)}-shown", "and 1 supporting citation.")
      assert has_element?(live, "#{why(id)}-opening", "Not selected for a published opening.")

      # The card's own line names the nominator the disclosure does.
      assert has_element?(live, card(id), "nominated by #{nominator}")

      receipt = publish!(ctx, claim)
      {:ok, live, _html} = live(build_conn(), ~p"/define/coward")

      # Two histories, two actors (C5): nominated by the contributor, selected
      # by the reviewer. And no claim that a page shows it.
      assert has_element?(
               live,
               "#{why(id)}-opening",
               "Selected for the opening of coward by #{reviewer} (version 1), published on " <>
                 "#{ExampleProvenance.date(receipt.committed_at)}. The page does not show openings yet."
             )

      assert has_element?(live, "#{why(id)}-nominated", "By #{nominator},")
      refute has_element?(live, "#{why(id)}-opening", "/define/")
    end

    test "a claim the record is silent about says unknown, and invents no nominator", ctx do
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})

      {:ok, legacy} =
        Claims.assert(work.object_id, "illustrates", ctx.sense.object_id, %{
          rationale: "a legacy rationale"
        })

      {:ok, live, _html} = live(build_conn(), ~p"/define/coward")

      assert has_element?(live, card(legacy.id), "nominator unknown")
      refute has_element?(live, card(legacy.id), "nominated by")

      assert has_element?(
               live,
               "#{why(legacy.id)}-nominated",
               "Unknown. The record names no nominator."
             )

      assert has_element?(live, "#{why(legacy.id)}-model", "Unknown. The record does not say.")
      assert has_element?(live, "#{why(legacy.id)}-reviewed", "Not yet reviewed.")
    end
  end

  describe "the person page" do
    test "gains one line per published selection, and says no page shows it yet", ctx do
      claim = ExemplarFixtures.nominate!(ctx.contributor, ctx.person, ctx.sense)
      decide!(ctx, claim)
      {:ok, live, _html} = live(build_conn(), person_path(ctx.person))

      assert has_element?(live, "#cited-as-claim-#{claim.assertion_id}")
      refute has_element?(live, "[id^='cited-as-featured-#{claim.assertion_id}-']")

      receipt = publish!(ctx, claim)
      {:ok, live, _html} = live(build_conn(), person_path(ctx.person))

      line = "#cited-as-featured-#{claim.assertion_id}-#{ctx.composition.id}"

      assert has_element?(
               live,
               line,
               "selected for the opening of coward since " <>
                 ExampleProvenance.date(receipt.committed_at)
             )

      assert has_element?(live, line, "not yet shown on its page")
      refute has_element?(live, "#{line} a")

      # Withdrawn, and the line is gone: only a publication that stands counts.
      {:ok, _} =
        Publications.withdraw(ctx.reviewer, ctx.composition.id,
          reason: "take down",
          idempotency_key: key(),
          expected_pointer: Repo.reload!(ctx.composition).current_published_version_id
        )

      {:ok, live, _html} = live(build_conn(), person_path(ctx.person))
      refute has_element?(live, line)
    end
  end

  describe "a pending nomination of a fictional adverse person" do
    setup ctx do
      adverse = ExemplarFixtures.person!("Fixture Adverse Person")
      claim = ExemplarFixtures.nominate!(ctx.contributor, adverse, ctx.sense)
      Map.merge(ctx, %{adverse: adverse, claim: claim})
    end

    test "leaves no trace for the public: card, count, disclosure or person page", ctx do
      id = ctx.claim.assertion_id
      {:ok, live, html} = live(build_conn(), ~p"/define/coward")

      refute has_element?(live, card(id))
      refute has_element?(live, why(id))
      refute has_element?(live, "#examples")
      refute html =~ "Fixture Adverse Person"
      refute html =~ "fixture rationale"

      {:ok, person, html} = live(build_conn(), person_path(ctx.adverse))
      refute has_element?(person, "#entity-cited-as")
      refute html =~ "timidity"
    end

    test "is present and marked for a contributor, disclosure included", ctx do
      id = ctx.claim.assertion_id
      conn = log_in_user(build_conn(), ctx.contributor.user)
      {:ok, live, _html} = live(conn, ~p"/define/coward")

      assert has_element?(live, "#examples", "1 under review")
      assert has_element?(live, "#examples-state-#{id}", "needs review")
      assert has_element?(live, card(id), "Not public until a reviewer accepts it.")
      assert has_element?(live, "#{why(id)}-reviewed", "Not yet reviewed.")

      # The person page is a public read whoever is looking (#212 comment,
      # item 2): a contributor sees there what the public sees.
      {:ok, person, _html} = live(conn, person_path(ctx.adverse))
      refute has_element?(person, "#entity-cited-as")
    end
  end

  describe "a nomination of a work nobody has accepted" do
    setup ctx do
      {:ok, work} =
        Registry.create_work(%{preferred_label: "Fixture Pending Work", work_kind: "artwork"})

      Map.put(ctx, :claim, ExemplarFixtures.nominate!(ctx.contributor, work, ctx.sense, []))
    end

    # The card and the count stay as the person-only gate leaves them (#190
    # owns that); the new surfaces carry nothing until a reviewer accepts.
    test "pending or disputed: its card stays public, with no disclosure; a contributor sees it",
         ctx do
      id = ctx.claim.assertion_id

      for decision <- [nil, "disputed"] do
        if decision, do: decide!(ctx, ctx.claim, decision)
        {:ok, live, _html} = live(build_conn(), ~p"/define/coward")
        assert has_element?(live, card(id))
        refute has_element?(live, why(id))

        conn = log_in_user(build_conn(), ctx.contributor.user)
        {:ok, live, _html} = live(conn, ~p"/define/coward")
        expected = if decision, do: "Disputed", else: "Not yet reviewed."
        assert has_element?(live, "#{why(id)}-reviewed", expected)
      end
    end

    test "rejected or withdrawn: no card, no count and no disclosure, for anyone", ctx do
      id = ctx.claim.assertion_id
      decide!(ctx, ctx.claim, "rejected")

      for conn <- [build_conn(), log_in_user(build_conn(), ctx.contributor.user)] do
        {:ok, live, html} = live(conn, ~p"/define/coward")
        refute has_element?(live, card(id))
        refute has_element?(live, why(id))
        refute html =~ "Fixture Pending Work"
      end

      {:ok, _} = Claims.review(ctx.claim.id, :withdrawn, %{reason: "withdrawn"})
      {:ok, _live, html} = live(build_conn(), ~p"/define/coward")
      refute html =~ "Fixture Pending Work"
    end
  end

  describe "the connect form" do
    setup ctx do
      shelf = ExemplarFixtures.shelved_quotation!(ctx, ctx.coward, "fixture passage words")
      conn = log_in_user(build_conn(), ctx.contributor.user)
      Map.merge(ctx, %{shelf: shelf, conn: conn})
    end

    defp propose_from(ctx, params) do
      query =
        Map.merge(
          %{
            subject: ctx.shelf.quotation.object_id,
            object: ctx.sense.object_id,
            predicate: "illustrates"
          },
          params
        )

      {:ok, view, _html} = live(ctx.conn, ~p"/connect?#{query}")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#composer-form", %{rationale: "found on a shelf"})
        |> render_submit()

      to |> String.split("/") |> List.last() |> String.to_integer() |> Claims.current_revision()
    end

    test "records the result and its provider when the prefill came from a shelf", ctx do
      revision = propose_from(ctx, %{from_result: ctx.shelf.result.id, provider: "forged"})

      # The provider is read from the result's run, never from the URL.
      assert revision.metadata == %{
               "from_result" => ctx.shelf.result.id,
               "provider" => "wikiquote"
             }
    end

    test "records a catalog shelf's provider only for that catalog's own work", ctx do
      {:ok, work} =
        Registry.create_work(%{
          preferred_label: "Fixture Catalog Work",
          work_kind: "artwork",
          metadata: %{"catalog_source" => "met"}
        })

      ctx = %{ctx | shelf: %{ctx.shelf | quotation: work}}
      revision = propose_from(ctx, %{provider: "met"})
      assert revision.metadata == %{"provider" => "met"}

      # A malformed result id is a bad request, not a catalog link: nothing is
      # recorded, even beside the work's own catalog.
      {:ok, _} = Claims.withdraw(revision.assertion_id)
      assert propose_from(ctx, %{from_result: "abc", provider: "met"}).metadata == %{}
    end

    test "records nothing once the contributor proposes another subject than the shelf's", ctx do
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})

      query = %{
        subject: ctx.shelf.quotation.object_id,
        object: ctx.sense.object_id,
        predicate: "illustrates",
        from_result: ctx.shelf.result.id
      }

      {:ok, view, _html} = live(ctx.conn, ~p"/connect?#{query}")
      view |> form("#composer-subject form", %{q: "Fixture Work"}) |> render_change()
      view |> element("#composer-subject-hit-#{work.object_id}") |> render_click()
      view |> element("#predicate-illustrates") |> render_click()
      view |> form("#composer-object form", %{q: "coward"}) |> render_change()
      view |> element("#composer-object-hit-#{ctx.sense.object_id}") |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view |> form("#composer-form", %{rationale: "not the shelf's"}) |> render_submit()

      revision =
        to |> String.split("/") |> List.last() |> String.to_integer() |> Claims.current_revision()

      assert revision.subject_object_id == work.object_id
      assert revision.metadata == %{}
    end

    test "records nothing a URL asserts that the registry does not", ctx do
      # A known source that is not this subject's catalog, an unknown one, a
      # malformed or out-of-range result id, and a result about something
      # else: each proposal is saved, and none says where it was found.
      other = ExemplarFixtures.shelved_quotation!(ctx, ctx.coward, "other fixture words")

      for params <- [
            %{provider: "artsy"},
            %{provider: "no-such-shelf"},
            %{from_result: "not-a-number", provider: "wikiquote"},
            %{from_result: "99999999999999999999"},
            %{from_result: other.result.id}
          ] do
        revision = propose_from(ctx, params)

        assert revision.metadata == %{},
               "#{inspect(params)} recorded #{inspect(revision.metadata)}"

        {:ok, _} = Claims.withdraw(revision.assertion_id)
      end
    end
  end

  # Part of the named discovery path: the quote card has no connect link on
  # `main` and the form prefills no provider evidence, so this starts at the
  # form with the shelf's parameters (#212 comment, item 3; deferred to the
  # linked follow-up).
  test "a shelf-prefilled nomination, read back after retention with every provider off (C7)",
       ctx do
    shelf = ExemplarFixtures.shelved_quotation!(ctx, ctx.coward, "fixture passage words")
    conn = log_in_user(build_conn(), ctx.contributor.user)

    query = %{
      subject: shelf.quotation.object_id,
      object: ctx.sense.object_id,
      predicate: "illustrates",
      from_result: shelf.result.id
    }

    {:ok, view, _html} = live(conn, ~p"/connect?#{query}")

    {:error, {:live_redirect, %{to: to}}} =
      view |> form("#composer-form", %{rationale: "found on the Quotes shelf"}) |> render_submit()

    assertion_id = to |> String.split("/") |> List.last() |> String.to_integer()
    claim = Claims.current_revision(assertion_id)
    decide!(ctx, claim)
    publish!(ctx, claim)

    # Retention takes the result; the claim and the item hold registry ids.
    assert {1, _records} = Discovery.purge_results([shelf.run.id])
    ExemplarFixtures.offline!()

    assert {:ok, %{highlights: [shown]}} = Published.current(ctx.composition.id)
    assert shown.subject.words == "fixture passage words"

    assert shown.content_revision_id ==
             Registry.current_content_revision(shelf.quotation.object_id).id

    {:ok, live, _html} = live(build_conn(), ~p"/define/coward")

    assert has_element?(
             live,
             "#{why(assertion_id)}-nominated",
             "prefilled from a #{shelf.source.name} result on the page"
           )

    assert has_element?(
             live,
             "#{why(assertion_id)}-opening",
             "Selected for the opening of coward"
           )

    # One quotation, one claim about it, no evidence copied from the result.
    assert Repo.aggregate(
             from(c in "content_revisions", where: c.body == "fixture passage words"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(r in "assertion_revisions",
               where: r.subject_object_id == ^shelf.quotation.object_id
             ),
             :count
           ) == 1

    assert Claims.evidence(claim.id) == []
  end
end
