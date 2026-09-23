defmodule DevilsDictionary.QuotationFingerprintFoldTest do
  @moduledoc """
  #158 build 3, end to end: one line held by two providers is one subject, one
  card and one row on the person's page, with both sources named on each.

  Two fake quotation providers stand in for Wiktionary and Wikiquote (neither
  exists yet: build 1 renders without a provider and build 4 is the
  Wikiquote one). Each punctuates the #158 fixture's Voltaire line its own
  way; the fingerprint each publishes beside its own id is the only thing they
  share. Every run goes through `Discovery.execute_run/1`.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Conformance, Result, Shelf}
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.FakeQuoteDiscoveryProvider, as: First
  alias DevilsDictionary.FakeQuoteMirrorDiscoveryProvider, as: Second
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, ExternalIdentifier}

  @garden "voltaire-candide-garden"

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [First, Second])

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      First.clear_rows()
      Second.clear_rows()
    end)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(&{&1, Conformance.human(&1, "Voltaire")})

      Req.Test.json(conn, %{"entities" => entities})
    end)

    ctx = %{sources: catalog.sources}
    word = word!(ctx, "garden", ~w(wordnet))

    Map.merge(ctx, %{
      target: %{object_id: word.object_id, term: "garden", language: "en", relevance: "term"}
    })
  end

  defp line(text), do: First.rows([@garden]) |> hd() |> Map.put("text", text)

  defp run!(provider, target, rows) do
    provider.put_rows("garden", rows)
    {:queued, run} = Discovery.request(target, provider.slug())
    assert :ok = Discovery.execute_run(run.id)
    [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
    result
  end

  test "the fixture's line, punctuated two ways, is one fingerprint; a different word is two" do
    assert Fingerprint.fingerprint("We must cultivate our garden.") ==
             Fingerprint.fingerprint("“we must cultivate our garden…”")

    refute Fingerprint.fingerprint("cultivate our garden") ==
             Fingerprint.fingerprint("cultivate one's garden")
  end

  test "two providers holding one line resolve to one subject, credited twice", ctx do
    first = run!(First, ctx.target, [line("We must cultivate our garden.")])

    items = Repo.aggregate(ContentItem, :count)
    revisions = Repo.aggregate(ContentRevision, :count)

    second = run!(Second, ctx.target, [line("“we must cultivate our garden…”")])

    # The second run matched the first's item by fingerprint and wrote no new
    # item and — the text being one text once normalised — no new revision.
    assert first.resolution_state == :newly_created
    assert second.resolution_state == :matched
    assert second.object_id == first.object_id
    assert Repo.aggregate(ContentItem, :count) == items
    assert Repo.aggregate(ContentRevision, :count) == revisions

    assert Registry.current_content_revision(first.object_id).body ==
             "We must cultivate our garden."

    # One fingerprint row, verified, and both providers' own ids on the item.
    fingerprint = Fingerprint.fingerprint("We must cultivate our garden.")

    assert [%ExternalIdentifier{object_id: object_id, status: :verified}] =
             Repo.all(
               from i in ExternalIdentifier,
                 where: i.namespace == "quotation_fingerprint" and i.external_id == ^fingerprint
             )

    assert object_id == first.object_id

    assert Registry.by_external_id("quote_fixture", @garden) == first.object_id
    assert Registry.by_external_id("quote_mirror", @garden) == first.object_id

    # Two assertions on one edge, one per source: the agreement build 5 counts.
    voltaire_id = Registry.by_external_id("wikidata", "Q9068")

    revisions = Claims.outgoing(first.object_id, predicate: "authored_by")
    assert Enum.map(revisions, & &1.object_object_id) == [voltaire_id, voltaire_id]

    sources =
      revisions
      |> Enum.map(&Repo.get!(Assertion, &1.assertion_id).source_id)
      |> Enum.map(&Repo.get!(DevilsDictionary.Sources.Source, &1).slug)
      |> Enum.sort()

    assert sources == ["quote-fixture", "quote-mirror"]

    # The person page: one row, two badges.
    page = EntityPage.build(voltaire_id)
    assert [row] = page.quotations
    assert row.object_id == first.object_id
    assert Enum.map(row.sources, & &1.slug) == ["quote-fixture", "quote-mirror"]
    assert page.pagination.quotations.count == 1
  end

  test "the shelf folds the two copies into one card that names both sources", ctx do
    run!(First, ctx.target, [line("We must cultivate our garden.")])
    run!(Second, ctx.target, [line("we must cultivate our garden")])

    items =
      for provider <- [First, Second],
          item <- Discovery.state(ctx.target.object_id, provider.slug()).items,
          do: {provider.slug(), item}

    assert length(items) == 2

    # Keyed on what the shelf reads at render: the identifiers each source
    # proposed, read back from its source record (#116 M3).
    assert [_one] = items |> Enum.map(&elem(&1, 1)) |> Shelf.dedup()

    assert [{%{external_namespace: "quote_fixture"}, ["quote-fixture", "quote-mirror"]}] =
             Shelf.fold(items, &elem(&1, 0), &Shelf.keys(elem(&1, 1)))
             |> Enum.map(fn {{_slug, item}, sources} -> {item, sources} end)

    # And the reader, handed both providers' states, draws one card.
    states =
      Map.new([First, Second], &{&1.slug(), Discovery.state(ctx.target.object_id, &1.slug())})

    html = render_component(&DevilsDictionaryWeb.Culture.section/1, states: states)

    cards =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(li[id^="culture-result-"]))
      |> Enum.count()

    assert cards == 1
  end

  test "the fold holds on identifiers alone, before either copy has an object", _ctx do
    # A transient item carries no object id; the fingerprint is enough.
    items =
      for {namespace, text} <- [
            {"quote_fixture", "We must cultivate our garden."},
            {"quote_mirror", "we must cultivate our garden"}
          ] do
        %{
          external_namespace: namespace,
          external_id: @garden,
          identifiers: [Fingerprint.identifier(text)],
          preview_metadata: %{}
        }
      end

    assert [{_item, ["quote_fixture", "quote_mirror"]}] =
             Shelf.fold(items, & &1.external_namespace)

    different =
      List.replace_at(items, 1, %{
        hd(items)
        | external_namespace: "quote_mirror",
          identifiers: [Fingerprint.identifier("We must cultivate one's garden.")]
      })

    assert length(Shelf.dedup(different)) == 2
  end

  test "one provider's corrected punctuation is the same text; a new wording is an alternate",
       ctx do
    first = run!(First, ctx.target, [line("We must cultivate our garden.")])

    refresh = fn text ->
      First.put_rows("garden", [line(text)])

      mapping =
        Repo.one!(
          from m in Discovery.Mapping,
            where: m.target_object_id == ^ctx.target.object_id and m.source_id == ^source_id(),
            limit: 1
        )

      discovery = Application.fetch_env!(:devils_dictionary, :discovery)

      Application.put_env(
        :devils_dictionary,
        :discovery,
        Keyword.put(discovery, :refresh_cooldown_seconds, 0)
      )

      {:queued, run} = Discovery.request_mapping(mapping, refresh: true)
      assert :ok = Discovery.execute_run(run.id)
      Application.put_env(:devils_dictionary, :discovery, discovery)
    end

    refresh.("We must cultivate our garden!")
    refresh.("Let us cultivate our garden.")

    bodies =
      Repo.all(
        from r in ContentRevision,
          where: r.content_id == ^first.object_id,
          order_by: r.revision_number,
          select: {r.body, r.is_current}
      )

    assert bodies == [
             {"We must cultivate our garden.", true},
             {"Let us cultivate our garden.", false}
           ]
  end

  test "a correction onto another item's wording is a conflict to review, not a silent fold",
       ctx do
    garden = line("We must cultivate our garden.")
    dangerous = First.rows(["voltaire-dangerous-right"]) |> hd()

    First.put_rows("garden", [garden, dangerous])
    {:queued, run} = Discovery.request(ctx.target, First.slug())
    assert :ok = Discovery.execute_run(run.id)

    # Upstream "corrects" the garden row into the other row's words.
    Second.put_rows("garden", [%{garden | "text" => dangerous["text"]}])
    {:queued, run} = Discovery.request(ctx.target, Second.slug())
    assert :ok = Discovery.execute_run(run.id)

    # The mirror's own id is new and its fingerprint is the dangerous row's, so
    # it resolves to that item — which is the right answer for the mirror.
    [mirror] = Repo.all(from r in Result, where: r.run_id == ^run.id)

    assert mirror.object_id ==
             Registry.by_external_id("quote_fixture", "voltaire-dangerous-right")

    # The first provider itself rewording its garden row onto that text: its
    # own id says one item, the fingerprint another. Nobody picks a winner.
    First.put_rows("garden", [%{garden | "text" => dangerous["text"]}, dangerous])
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(discovery, :refresh_cooldown_seconds, 0)
    )

    mapping =
      Repo.one!(
        from m in Discovery.Mapping,
          where: m.target_object_id == ^ctx.target.object_id and m.source_id == ^source_id(),
          limit: 1
      )

    {:queued, refresh} = Discovery.request_mapping(mapping, refresh: true)
    assert :ok = Discovery.execute_run(refresh.id)
    Application.put_env(:devils_dictionary, :discovery, discovery)

    conflicted =
      Repo.one!(
        from r in Result,
          where: r.run_id == ^refresh.id and r.external_id == @garden
      )

    assert conflicted.resolution_state == :conflicting_identifiers

    assert Repo.exists?(
             from c in DevilsDictionary.Sources.ReconciliationCase,
               where:
                 c.kind == "external_identifier_conflict" and
                   c.payload["reason"] == "identifiers_resolve_to_different_objects"
           )
  end

  defp source_id, do: DevilsDictionary.Sources.get_source_by_slug!("quote-fixture").id
end
