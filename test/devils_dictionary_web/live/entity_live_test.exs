defmodule DevilsDictionaryWeb.EntityLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Registry

  setup ctx do
    %{sources: sources, scopes: scopes} = DevilsDictionary.Fixtures.seed_catalog!()
    {:ok, person} = Registry.create_person(%{preferred_label: "High Degree Author"})

    {:ok, work} =
      Registry.create_work(%{
        preferred_label: "A Reachable Work",
        work_kind: "book",
        original_language: "en"
      })

    {:ok, _} = Claims.assert(work.object_id, "authored_by", person.object_id)

    {:ok, edition} =
      Registry.create_edition(%{
        preferred_label: "A Reachable Edition",
        work_id: work.object_id,
        edition_label: "Reader edition"
      })

    {:ok, _} = Claims.assert(edition.object_id, "edition_of", work.object_id)

    ctx = Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})

    definitions =
      for n <- 1..26 do
        word = word!(ctx, "entry #{n}", ~w(bierce), scope: nil)

        entry!(ctx, word, "bierce",
          author: person,
          body: "First line #{n}.\nA long second line that belongs on the word page."
        )
      end

    Map.merge(ctx, %{person: person, work: work, edition: edition, definitions: definitions})
  end

  test "work retains a canonical author path after incoming role deduplication", ctx do
    slug = Connection.slugify(ctx.work.preferred_label)
    author_slug = Connection.slugify(ctx.person.preferred_label)
    {:ok, live, _html} = live(ctx.conn, ~p"/entities/#{ctx.work.object_id}/#{slug}")

    assert has_element?(
             live,
             "#entity-connections a[href='/entities/#{ctx.person.object_id}/#{author_slug}']"
           )
  end

  test "edition retains a canonical parent-work path", ctx do
    slug = Connection.slugify(ctx.edition.preferred_label)
    work_slug = Connection.slugify(ctx.work.preferred_label)
    {:ok, live, _html} = live(ctx.conn, ~p"/entities/#{ctx.edition.object_id}/#{slug}")

    assert has_element?(
             live,
             "#entity-connections a[href='/entities/#{ctx.work.object_id}/#{work_slug}']"
           )
  end

  test "role predicates appear once in their represented direction", ctx do
    word = word!(ctx, "role audit", ~w(bierce), scope: nil)

    content =
      entry!(ctx, word, "bierce",
        author: ctx.person,
        body: "A role-aware definition."
      )

    {:ok, _} = Claims.assert(content.object_id, "published_in", ctx.edition.object_id)
    article = entry!(ctx, ctx.person, "wikipedia", body: "A role-aware biography.")

    person_page = EntityPage.build(ctx.person.object_id)
    work_page = EntityPage.build(ctx.work.object_id)
    edition_page = EntityPage.build(ctx.edition.object_id)

    assert Enum.any?(person_page.works, &(&1.object_id == ctx.work.object_id))
    assert person_page.definitions != []
    assert Enum.any?(person_page.biography, &(&1.object_id == article.object_id))
    assert person_page.connections.incoming == []

    assert Enum.any?(work_page.editions, &(&1.object_id == ctx.edition.object_id))
    assert Enum.any?(work_page.connections.outgoing, &(&1.predicate.key == "authored_by"))

    assert Enum.any?(edition_page.contents, &(&1.object_id == content.object_id))
    assert Enum.any?(edition_page.connections.outgoing, &(&1.predicate.key == "edition_of"))
    refute Enum.any?(edition_page.connections.incoming, &(&1.predicate.key == "published_in"))
  end

  test "definition excerpts bound long prose and normalize verse and Markdown", ctx do
    {:ok, author} = Registry.create_person(%{preferred_label: "Excerpt Author"})

    long_body =
      "A deliberately long paragraph " <>
        String.duplicate("whose words should stay on the word page ", 12)

    markdown_body =
      "## **Sharp** [reader](https://example.test/reader) with `literal` _markers_."

    verse_body = "First measured line\nSecond measured line\nThird measured line"

    bodies = [long_body, markdown_body, verse_body]

    contents =
      for {body, n} <- Enum.with_index(bodies) do
        word = word!(ctx, "excerpt #{n}", ~w(bierce), scope: nil)
        entry!(ctx, word, "bierce", author: author, body: body)
      end

    summaries = author.object_id |> EntityPage.build() |> Map.fetch!(:definitions)
    [long_summary, markdown_summary, verse_summary] = Enum.map(summaries, & &1.summary)

    assert String.length(long_summary) <= 121
    assert String.ends_with?(long_summary, "…")
    assert markdown_summary == "Sharp reader with literal markers."
    assert verse_summary == "First measured line Second measured line Third measured line"

    assert Enum.map(contents, &Registry.current_content_revision(&1.object_id).body) == bodies
  end

  test "role pages are independent, compact and cursor-reachable", ctx do
    slug = Connection.slugify(ctx.person.preferred_label)
    {:ok, live, html} = live(ctx.conn, ~p"/entities/#{ctx.person.object_id}/#{slug}")

    assert html =~ ~s(id="entity-works")
    assert html =~ ~s(id="definitions-next")
    assert html =~ "26 total"
    assert html =~ "First line 1."
    assert html =~ "A long second line"
    refute html =~ ~s(id="entity-connections")

    first_ids =
      ctx.definitions
      |> Enum.take(24)
      |> Enum.map(& &1.object_id)

    last_ids = ctx.definitions |> Enum.drop(24) |> Enum.map(& &1.object_id)

    assert Enum.all?(first_ids, &has_element?(live, "#definition-#{&1}"))
    assert Enum.all?(last_ids, &(not has_element?(live, "#definition-#{&1}")))

    live |> element("#definitions-next") |> render_click()

    assert Enum.all?(last_ids, &has_element?(live, "#definition-#{&1}"))
    assert Enum.all?(first_ids, &(not has_element?(live, "#definition-#{&1}")))
    assert has_element?(live, "#work-#{ctx.work.object_id}")
    refute has_element?(live, "#definitions-next")
  end

  test "claim cursors do not skip or repeat rows in either traversal direction", ctx do
    events =
      for n <- 1..26 do
        {:ok, event} =
          Registry.create_entity(%{entity_kind: :event, preferred_label: "Event #{n}"})

        {:ok, _} = Claims.assert(ctx.person.object_id, "participates_in", event.object_id)
        event
      end

    incoming_first =
      Claims.incoming(ctx.person.object_id,
        predicate: "authored_by",
        subject_kind: "content",
        limit: 24
      )

    incoming_second =
      Claims.incoming(ctx.person.object_id,
        predicate: "authored_by",
        subject_kind: "content",
        after: Claims.next_cursor(incoming_first),
        limit: 24
      )

    assert length(incoming_first) == 24
    assert length(incoming_second) == 2
    assert MapSet.disjoint?(ids(incoming_first), ids(incoming_second))

    outgoing_first =
      Claims.outgoing(ctx.person.object_id, predicate: "participates_in", limit: 24)

    outgoing_second =
      Claims.outgoing(ctx.person.object_id,
        predicate: "participates_in",
        after: Claims.next_cursor(outgoing_first),
        limit: 24
      )

    assert length(outgoing_first) == 24
    assert length(outgoing_second) == 2
    assert MapSet.disjoint?(ids(outgoing_first), ids(outgoing_second))

    assert MapSet.new(Enum.map(events, & &1.object_id)) ==
             MapSet.new(Enum.map(outgoing_first ++ outgoing_second, & &1.object_object_id))

    slug = Connection.slugify(ctx.person.preferred_label)
    {:ok, live, _html} = live(ctx.conn, ~p"/entities/#{ctx.person.object_id}/#{slug}")

    assert has_element?(live, "#connections-out-next")

    assert Enum.all?(
             Enum.take(events, 24),
             &has_element?(live, "#connection-out-#{claim_id(outgoing_first, &1)}")
           )

    live |> element("#connections-out-next") |> render_click()

    assert Enum.all?(
             Enum.drop(events, 24),
             &has_element?(live, "#connection-out-#{claim_id(outgoing_second, &1)}")
           )

    refute has_element?(live, "#connections-out-next")
    assert has_element?(live, "#definitions-next")

    assert Enum.all?(
             Enum.take(ctx.definitions, 24),
             &has_element?(live, "#definition-#{&1.object_id}")
           )
  end

  defp ids(rows), do: MapSet.new(rows, & &1.id)

  defp claim_id(rows, entity) do
    rows
    |> Enum.find(&(&1.object_object_id == entity.object_id))
    |> Map.fetch!(:assertion_id)
  end
end
