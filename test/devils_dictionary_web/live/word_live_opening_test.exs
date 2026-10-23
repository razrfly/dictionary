defmodule DevilsDictionaryWeb.WordLiveOpeningTest do
  @moduledoc """
  The published opening on the word page, through the real routes (#255 §6,
  tests 9–14): `/on/love` shows what a reviewer published for every *love*,
  `/words/:id/love` is another scope and shows nothing, a withdrawal shows on
  the next request, and no parameter chooses what is shown.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures,
    only: [account: 1, content_spec: 2, enabled_default!: 1, key: 1, quotation_spec: 2]

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Curation.{Compositions, Publications, Reviews}
  alias DevilsDictionary.{Fixtures, Repo}
  alias DevilsDictionary.Sources.Actor

  @johnson_note "Johnson's four senses map the word before Bierce turned it."
  @milton_note "The plainest literary use, so the two leads can be compared."

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)
    reviewer = account([:reviewer])
    {configuration, _version} = enabled_default!(reviewer)

    Map.merge(ctx, %{
      verb: verb,
      author: account([:contributor]),
      reviewer: reviewer,
      configuration: configuration
    })
  end

  defp provision!(ctx, kind, lexemes) do
    {:ok, composition} =
      Compositions.provision(ctx.author, ctx.configuration.id, %{
        scope_kind: kind,
        lexeme_ids: Enum.map(lexemes, & &1.object_id),
        language_tag: "en",
        reason: "P1 #255 test"
      })

    composition
  end

  # Provision, version, review and publish the §5.3 arrangement for `lexemes`.
  defp publish_love!(ctx, kind \\ :lexical_page, lexemes \\ nil) do
    composition = provision!(ctx, kind, lexemes || [ctx.love, ctx.verb])

    {:ok, version} =
      Compositions.create_version(ctx.author, composition.id, %{
        lead: content_spec(ctx.bierce, ctx.love),
        highlights: [
          ctx.johnson |> content_spec(ctx.love) |> Map.put(:note, %{text: @johnson_note}),
          ctx.profound |> quotation_spec(1) |> Map.put(:note, %{text: @milton_note})
        ],
        reason: "P1 #255 test",
        expected_parent: nil
      })

    {:ok, _review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "P1 #255 test",
        idempotency_key: key("review")
      )

    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "P1 #255 test",
        idempotency_key: key("publish"),
        expected_pointer: nil
      )

    %{composition: composition, version: version, receipt: receipt}
  end

  defp label(scope),
    do: Actor |> Repo.get_by!(user_id: scope.user.id) |> Compositions.author_label()

  defp opening_html(view), do: view |> element("#opening") |> render()

  test "9: with nothing published the page begins at the Definitions", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

    refute has_element?(view, "#opening")
    assert has_element?(view, "[id^='definitions-'] h2", "Definitions")
    assert has_element?(view, "#word-rail[class='lg:col-start-1 lg:row-start-1']")
  end

  test "10: a published composition is the opening, in order, signed, with its record", ctx do
    %{composition: composition, receipt: receipt} = publish_love!(ctx)
    {:ok, view, html} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#opening-lead-text", "A temporary insanity curable by marriage")
    assert has_element?(view, "#opening-lead-register", "Satire")
    assert has_element?(view, "#opening-lead-entry[href='#card-bierce']", "Read the whole entry")

    assert has_element?(view, "#opening-highlight-1-register", "Sourced definition")
    assert has_element?(view, "#opening-highlight-1-text", "The passion between the sexes")
    assert has_element?(view, "#opening-highlight-1-entry[href='#card-johnson']")
    assert has_element?(view, "#opening-highlight-2-text", "cordial love")

    {first, _} = :binary.match(html, ~s(id="opening-highlight-1"))
    {second, _} = :binary.match(html, ~s(id="opening-highlight-2"))
    assert first < second

    author = label(ctx.author)
    reviewer = label(ctx.reviewer)

    for {n, note} <- [{1, @johnson_note}, {2, @milton_note}] do
      assert has_element?(view, "#opening-highlight-#{n}-why summary", "Why this is here")
      assert has_element?(view, "#opening-highlight-#{n}-note-0", note)

      assert has_element?(
               view,
               "#opening-highlight-#{n}-note-0-author",
               "Written by #{author} · reviewed by #{reviewer}"
             )
    end

    # The disclosure is the record's (#255 §2.2), and no fixture copy.
    assert has_element?(view, "#opening-about summary", "How this was curated")

    assert has_element?(
             view,
             "#opening-about-configuration",
             "global-default, version 1 · lead rule bierce_first_v1"
           )

    assert has_element?(view, "#opening-about-selected", "#{author} (operator)")
    assert has_element?(view, "#opening-about-published", "#{reviewer} (operator)")
    assert has_element?(view, "#opening-about-published", "version 1 · receipt ##{receipt.id}")
    assert has_element?(view, "#opening-about-panel", "None: published by the operator")
    assert has_element?(view, "#opening-about-withheld", "Nothing")
    assert has_element?(view, "#opening-about-composition", "##{composition.id}, version 1")

    refute has_element?(view, "#opening-fixture")
    refute has_element?(view, "#opening-about-reviewed")
    refute opening_html(view) =~ "development fixture"
    refute opening_html(view) =~ ~r/assessed|next assessment|inputs last changed/i

    # Below it, nothing moved.
    assert has_element?(view, "#card-bierce")
    assert has_element?(view, "[id^='definitions-'] h2", "Definitions")
  end

  test "11: a withdrawal shows on the next request", ctx do
    %{composition: composition, version: version} = publish_love!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")
    assert has_element?(view, "#opening-lead")

    {:ok, _} =
      Publications.withdraw(ctx.reviewer, composition.id,
        reason: "P1 #255 test",
        idempotency_key: key("withdraw"),
        expected_pointer: version.id
      )

    {:ok, fresh, _html} = live(ctx.conn, ~p"/on/love")
    refute has_element?(fresh, "#opening")
    assert has_element?(fresh, "[id^='definitions-'] h2", "Definitions")
  end

  describe "12: the fixture gate" do
    setup do
      previous = Application.get_env(:devils_dictionary, :curated_opening_fixtures)

      on_exit(fn ->
        Application.put_env(:devils_dictionary, :curated_opening_fixtures, previous)
      end)
    end

    test "with fixtures on, ?opening=fixture is the fixture, with its banner", ctx do
      publish_love!(ctx)
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, true)

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")

      assert has_element?(view, "#opening-fixture", "Development fixture")
      assert has_element?(view, "#opening-about-selection", "not a published composition")
      refute has_element?(view, "#opening-about-published")
    end

    test "with fixtures off, it is the published opening or nothing, never the fixture", ctx do
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, false)

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")
      refute has_element?(view, "#opening")

      publish_love!(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")

      assert has_element?(view, "#opening-about-published")
      refute has_element?(view, "#opening-fixture")
    end
  end

  test "13: no parameter chooses a configuration or a composition", ctx do
    %{composition: on} = publish_love!(ctx)
    # Another composition, of the noun alone, published too.
    %{composition: noun} = publish_love!(ctx, :lexeme, [ctx.love])

    {:ok, plain, _html} = live(ctx.conn, ~p"/on/love")
    expected = opening_html(plain)
    assert has_element?(plain, "#opening-about-composition", "##{on.id},")

    for query <- [
          "opening=published",
          "configuration=#{ctx.configuration.id + 1}",
          "configuration=global-default",
          "composition=#{noun.id}",
          "composition=#{on.id}&opening=published&version=2",
          "anything=else"
        ] do
      {:ok, view, _html} = live(ctx.conn, "/on/love?" <> query)
      assert opening_html(view) == expected, "?#{query} changed the opening"
    end

    # Nor can a parameter put a composition on a page whose words are not
    # its scope.
    {:ok, exact, _html} =
      live(ctx.conn, "/words/#{ctx.love.object_id}/love?composition=#{on.id}")

    refute has_element?(exact, "#opening")
  end

  test "14: the exact-word page is another scope and shows nothing", ctx do
    publish_love!(ctx)

    {:ok, on, _html} = live(ctx.conn, ~p"/on/love")
    {:ok, noun, _html} = live(ctx.conn, ~p"/words/#{ctx.love.object_id}/love")
    {:ok, verb, _html} = live(ctx.conn, ~p"/words/#{ctx.verb.object_id}/love")

    assert has_element?(on, "#opening-lead")
    refute has_element?(noun, "#opening")
    refute has_element?(verb, "#opening")
    assert has_element?(noun, "#card-bierce")
  end
end
