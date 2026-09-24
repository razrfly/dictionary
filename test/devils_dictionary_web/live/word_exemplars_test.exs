defmodule DevilsDictionaryWeb.WordExemplarsTest do
  @moduledoc """
  The exemplar register on `/define/:slug` and the reverse view on the
  person's page (#181 build 2). Cards above the chips in the one `#examples`
  section; the public sees a person's card only once a reviewer accepts it,
  and a contributor sees it before that, marked.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.AccountsFixtures
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Connection, Contributions}
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Examples.{Manifest, Seeder}
  alias DevilsDictionary.{Fixtures, Registry, Repo}

  @bezos "Q312556"
  @cnn "https://www.cnn.com/2024/10/25/media/washington-post-wont-endorse-presidential-candidate"

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)

    contributor =
      user_fixture() |> Ecto.Changeset.change(internal_contributor: true) |> Repo.update!()

    reviewer = user_fixture() |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()

    coward = word!(ctx, "coward", ~w(wordnet))
    coward_sense = sense!(ctx, coward, "wordnet", gloss: "a person who shows fear or timidity")

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(&{&1, Conformance.human(&1, "Jeff Bezos")})

      Req.Test.json(conn, %{"entities" => entities})
    end)

    manifest = %{
      "schema_version" => 1,
      "kind" => "exemplars",
      "manifest" => "live-v1",
      "rows" => [
        %{
          "word" => "coward",
          "sense" => %{"source" => "wordnet", "match" => "fear or timidity"},
          "subject" => %{"wikidata" => @bezos, "label" => "Jeff Bezos", "kind" => "person"},
          "rationale" => "Blocked his newspaper's drafted endorsement before the election.",
          "evidence" => [%{"url" => @cnn, "attribution" => "CNN, 25 October 2024"}],
          "curator" => "holden"
        }
      ],
      "row_count" => 1
    }

    manifest = Map.put(manifest, "checksum", Manifest.checksum(manifest))

    {:ok, %{results: [%{outcome: :created, assertion_id: id}]}} =
      Seeder.run(manifest, Scope.for_user(contributor), claim: fn _ -> {:ok, 0} end)

    Map.merge(ctx, %{
      contributor: contributor,
      reviewer: reviewer,
      coward: coward,
      coward_sense: coward_sense,
      claim_id: id,
      bezos: Registry.by_external_id("wikidata", @bezos)
    })
  end

  defp accept!(ctx, decision \\ "accepted") do
    revision = Claims.current_revision(ctx.claim_id)

    {:ok, _} =
      Contributions.review(
        Scope.for_user(ctx.reviewer),
        ctx.claim_id,
        revision.id,
        decision,
        "Checked the evidence.",
        Contributions.context_items(revision)
      )
  end

  defp card(ctx), do: "#examples-ex-#{ctx.claim_id}"

  test "the public never sees a person nominated here before it is accepted", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    refute has_element?(live, card(ctx))
    refute has_element?(live, "#examples")
  end

  test "a contributor sees the nomination, marked and linked to its review", ctx do
    conn = log_in_user(ctx.conn, ctx.contributor)
    {:ok, live, _html} = live(conn, ~p"/define/coward")

    assert has_element?(live, "#examples-exemplars #{card(ctx)}")
    assert has_element?(live, "#examples-state-#{ctx.claim_id}", "needs review")

    assert has_element?(
             live,
             "#examples-review-#{ctx.claim_id}[href='/connections/#{ctx.claim_id}']"
           )

    assert has_element?(live, "#examples", "1 under review")
  end

  test "a reviewer's accept makes the card public; a reject removes it", ctx do
    accept!(ctx)

    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    assert has_element?(live, card(ctx), "Jeff Bezos")
    assert has_element?(live, card(ctx), "cited as an example of")
    assert has_element?(live, card(ctx), "a person who shows fear or timidity")
    assert has_element?(live, card(ctx), "Blocked his newspaper")
    assert has_element?(live, card(ctx), "nominated by holden")
    assert has_element?(live, card(ctx), "selected by a reviewer")
    assert has_element?(live, "#examples-evidence-#{ctx.claim_id} a[href='#{@cnn}']", "CNN")
    assert has_element?(live, "#examples-votes-#{ctx.claim_id}", "▲ 0 ▽ 0")
    refute has_element?(live, "#examples-state-#{ctx.claim_id}")

    slug = Connection.slugify("Jeff Bezos")
    assert has_element?(live, "#{card(ctx)} a[href='/entities/#{ctx.bezos}/#{slug}']")

    accept!(ctx, "rejected")
    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")
    refute has_element?(live, card(ctx))
  end

  test "the instance chips are unchanged with an exemplar present", ctx do
    hitler = word!(ctx, "Adolf Hitler", ~w(wordnet))
    hitler_sense = sense!(ctx, hitler, "wordnet", group_key: "oewn-hitler-n")

    relation!(ctx, hitler, :instance_of, nil,
      source: "wordnet",
      from_sense: hitler_sense,
      to_sense: ctx.coward_sense
    )

    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")
    before = live |> element("#examples-instances") |> render()

    accept!(ctx)
    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    assert has_element?(live, "#examples-exemplars #{card(ctx)}")
    assert live |> element("#examples-instances") |> render() == before
    assert has_element?(live, "#examples-by-wordnet-sense")
    assert has_element?(live, "#examples", "1 cited")
    assert has_element?(live, "#examples", "1 named by the record")
  end

  test "a contributor can open the pending nomination the Review link names", ctx do
    conn = log_in_user(ctx.conn, ctx.contributor)
    {:ok, live, _html} = live(conn, ~p"/connections/#{ctx.claim_id}")

    refute has_element?(live, "#no-such-connection")

    {:ok, public, _html} = live(build_conn(), ~p"/connections/#{ctx.claim_id}")
    assert has_element?(public, "#no-such-connection")
  end

  test "a pending nomination of a work is public, and its card says so honestly", ctx do
    {:ok, work} =
      Registry.create_work(%{preferred_label: "A Fleeing Figure", work_kind: "artwork"})

    {:ok, claim} =
      Contributions.propose(
        Scope.for_user(ctx.contributor),
        work.object_id,
        "illustrates",
        ctx.coward_sense.object_id,
        %{rationale: "The figure runs from the fight."},
        []
      )

    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    assert has_element?(live, "#examples-ex-#{claim.id}", "Not yet reviewed.")
    refute has_element?(live, "#examples-ex-#{claim.id}", "Not public until")
    refute has_element?(live, "#examples-cited-byline", "contributors only")
  end

  test "a content subject links to its claim, which has a page", ctx do
    {:ok, gif} =
      Registry.create_content(%{content_kind: :media, body: "a gif", headword: "Running away"})

    {:ok, claim} =
      Contributions.propose(
        Scope.for_user(ctx.contributor),
        gif.object_id,
        "illustrates",
        ctx.coward_sense.object_id,
        %{rationale: "Somebody running from a fight."},
        []
      )

    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    assert has_element?(
             live,
             "#examples-ex-#{claim.id} a[href='/connections/#{claim.id}']",
             "Running away"
           )
  end

  test "the person page groups accepted claims by word", ctx do
    slug = Connection.slugify("Jeff Bezos")

    {:ok, live, _html} = live(ctx.conn, ~p"/entities/#{ctx.bezos}/#{slug}")
    refute has_element?(live, "#entity-cited-as")

    accept!(ctx)
    {:ok, live, _html} = live(ctx.conn, ~p"/entities/#{ctx.bezos}/#{slug}")

    assert has_element?(live, "#entity-cited-as #cited-as-#{ctx.coward.object_id}", "coward")
    assert has_element?(live, "#cited-as-claim-#{ctx.claim_id}", "▲ 0 ▽ 0")
    assert has_element?(live, "#cited-as-claim-#{ctx.claim_id}", "selected by a reviewer")
    # The generic list does not draw the same claim twice.
    refute has_element?(live, "#entity-meaning-connections")
  end
end
