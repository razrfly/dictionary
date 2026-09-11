defmodule DevilsDictionaryWeb.EntityLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Connection
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

    ctx = Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})

    definitions =
      for n <- 1..26 do
        word = word!(ctx, "entry #{n}", ~w(bierce), scope: nil)

        entry!(ctx, word, "bierce",
          author: person,
          body: "First line #{n}.\nA long second line that belongs on the word page."
        )
      end

    %{person: person, work: work, definitions: definitions}
  end

  test "role pages are independent, compact and cursor-reachable", ctx do
    slug = Connection.slugify(ctx.person.preferred_label)
    {:ok, live, html} = live(ctx.conn, ~p"/entities/#{ctx.person.object_id}/#{slug}")

    assert html =~ ~s(id="entity-works")
    assert html =~ ~s(id="definitions-next")
    assert html =~ "26 total"
    assert html =~ "First line 1."
    refute html =~ "A long second line"
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
  end

  defp ids(rows), do: MapSet.new(rows, & &1.id)

  defp claim_id(rows, entity) do
    rows
    |> Enum.find(&(&1.object_object_id == entity.object_id))
    |> Map.fetch!(:assertion_id)
  end
end
