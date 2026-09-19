defmodule DevilsDictionary.Discovery.Conformance.OpenverseCommonsFoldTest do
  @moduledoc """
  The multi-source shelf check on **two real providers** (#116 Phase 2).

  Phase 1's `MultiSourceConformanceTest` proves M2–M4 on two coordinated
  stubs, and its own report named what it could not prove: *the multi-source
  check runs on stubs, not on two real fixtures*. This is that check. Commons
  and Openverse both declare `:image`, both go through admission, the
  transport and persistence, and the shelf is read back through
  `Discovery.states/1` and `Culture.section/1` — the same read the word page
  does.

  What only two real fixtures can show:

    * the **fold** of M3 on real response shapes, in **both** of its two
      forms. By identity: Openverse's `source: "wikimedia"` row names its
      Commons file as `…/w/index.php?curid=<pageid>`, the provider proposes
      that pageid in the `commons_file` namespace, and the shelf folds the
      Openverse copy into the Commons item. By **media URL**: a second
      `wikimedia` row whose landing page is the `/wiki/File:` form proposes
      no shared identifier at all, and only the canonical full-size URL joins
      it — which it could not do before D4 of #116 Phase 3, because
      Commons wrote its 640 px thumbnail into `image_url` as well as into
      `thumbnail_url` and a thumbnail is never compared. Neither provider
      names the other in either case.
    * **the linked credit** (D3): the renderer turns the `creator` and the
      `license` inside each provider's own attribution line into links where
      the item carries URLs for them, and leaves the line as plain text where
      it does not — which is what a public-domain Commons file does.
    * **M4's six fixed names on both**, one carrying them from Openverse's own
      fields and one deriving them from Commons `extmetadata`.
    * **both evidence classes the `:image` row admits, from real providers**:
      Commons's `:identity` depiction and Openverse's labelled `:query`.

  The page is *soldier*, which is the target `CommonsFixture` covers: Commons
  reaches a page only through a `refers_to` QID, and writing a second one here
  would be this suite reimplementing that fixture. Openverse's rows are its
  *war* capture, because that is the capture the probe took; what is asserted
  is the fold and the credits, neither of which is a claim about relevance.
  """

  use DevilsDictionary.DataCase, async: false

  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Conformance.{CommonsFixture, OpenverseFixture}
  alias DevilsDictionary.Discovery.Providers.{Commons, Openverse}
  alias DevilsDictionary.Discovery.{MatchReason, Run, Shelf}
  alias DevilsDictionary.Repo
  alias DevilsDictionaryWeb.Culture

  @moduletag :conformance

  # Openverse first, so registry order cannot be where the shelf's order comes
  # from. Since D1 of #116 Phase 3 the two no longer share a tier: Commons is
  # `:middle` because it reaches a page by identity, Openverse is `:plebs`
  # because it reaches one by text, and the identity source leads the rail on
  # tier rather than on the accident of its slug.
  @providers [Openverse, Commons]

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, @providers)

    # One plug for both providers, told apart by host the way the two APIs are.
    # `Req.Test` keys a stub by name and the pipeline has one set of request
    # options, so a router is what puts two real fixtures on one page.
    Application.put_env(:devils_dictionary, :discovery_req_options,
      plug: fn conn ->
        Req.Test.call(conn, if(conn.host =~ "commons", do: Commons, else: Openverse))
      end
    )

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
    end)

    context = %{sources: catalog.sources, scopes: catalog.scopes}

    %{context: context, target: CommonsFixture.covered_target(context)}
  end

  defp deliver!(context, target) do
    commons = CommonsFixture.stub(:results, context)
    openverse = OpenverseFixture.stub(:results, context)

    for provider <- @providers do
      assert {:queued, run} = Discovery.request(target, provider.slug())
      assert :ok = Discovery.execute_run(run.id)
      assert Repo.get!(Run, run.id).status == :succeeded
    end

    %{commons: hd(commons.pages), openverse: hd(openverse.pages)}
  end

  defp shelf_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#culture-results > li")
    |> LazyHTML.attribute("id")
  end

  defp count(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp item!(states, slug, external_id) do
    Enum.find(states[slug].items, &(&1.external_id == external_id)) ||
      flunk("#{slug} delivered no #{external_id}")
  end

  test "the Openverse copy of a Commons file folds into the Commons item", %{
    context: context,
    target: target
  } do
    delivered = deliver!(context, target)

    # Five delivered across two sources, and two of the five are files the
    # other source already has: Openverse's `da6a88c7-…` aggregates Commons's
    # pageid 1001, and `7b0f2e31-…` republishes the file behind 1002.
    assert delivered.commons == ~w(1001 1002)
    assert OpenverseFixture.shared_openverse_id() in delivered.openverse
    assert OpenverseFixture.media_fold_openverse_id() in delivered.openverse
    assert length(delivered.openverse) == 3

    states = Discovery.states(target.object_id)
    assert map_size(states) == 2

    # The identifier that does the folding is the provider's, proposed without
    # knowing Commons exists, and read back off the persisted result.
    shared = item!(states, Openverse.slug(), OpenverseFixture.shared_openverse_id())

    assert %{"namespace" => "commons_file", "external_id" => pageid} =
             Enum.find(shared.identifiers, &(&1["namespace"] == "commons_file"))

    assert pageid == OpenverseFixture.shared_commons_pageid()

    html = render_component(&Culture.section/1, states: states)

    # One shelf, and three cards for four delivered items.
    assert count(html, "[id^='culture-shelf-']") == 1
    assert count(html, "#culture-shelf-image") == 1

    # Commons is `:middle` and Openverse `:plebs` (D1), so the identity source
    # leads and the turns are taken among what survived the fold. Both
    # Openverse copies are gone; each Commons original is the one card its
    # file gets.
    assert shelf_ids(html) == [
             "culture-result-commons_file-1001",
             "culture-result-openverse_media-c80387bb-2dd9-489e-a748-75a1be138f5a",
             "culture-result-commons_file-1002"
           ]

    refute html =~ "culture-result-openverse_media-#{OpenverseFixture.shared_openverse_id()}"

    assert states[Commons.slug()].tier == :middle
    assert states[Openverse.slug()].tier == :plebs
  end

  test "a Commons file republished under no shared identifier folds on its media URL", %{
    context: context,
    target: target
  } do
    deliver!(context, target)
    states = Discovery.states(target.object_id)

    commons = item!(states, Commons.slug(), OpenverseFixture.shared_commons_media_pageid())
    openverse = item!(states, Openverse.slug(), OpenverseFixture.media_fold_openverse_id())

    # Nothing identifies the two as one thing. Openverse proposed only its own
    # UUID, because the landing page it gave is the `/wiki/File:` form and the
    # `commons_file` pageid is not in it.
    assert Enum.map(openverse.identifiers, & &1["namespace"]) == [Openverse.namespace()]

    # Nothing but the media URL can join them: strip the media key from both
    # and no key is left that they share.
    without_media = fn item ->
      item |> Shelf.keys() |> Enum.reject(&match?({:media, _}, &1)) |> MapSet.new()
    end

    assert MapSet.disjoint?(without_media.(commons), without_media.(openverse))

    # D4: Commons's `image_url` is the file `imageinfo` returned, not the
    # 640 px derivative it also returned, so the two copies share one
    # canonical media URL although they are spelled differently.
    assert commons.preview_metadata["image_url"] == "https://upload.commons.test/1002.jpg"
    refute commons.preview_metadata["image_url"] == commons.preview_metadata["thumbnail_url"]

    assert openverse.preview_metadata["image_url"] ==
             "HTTPS://Upload.Commons.test/1002.jpg?download=1"

    assert Shelf.canonical_media_url(commons.preview_metadata["image_url"]) ==
             Shelf.canonical_media_url(openverse.preview_metadata["image_url"])

    assert {:media, "upload.commons.test/1002.jpg"} in Shelf.keys(commons)

    # And the rail shows one card for the file, the Commons one.
    html = render_component(&Culture.section/1, states: states)
    assert "culture-result-commons_file-1002" in shelf_ids(html)

    refute "culture-result-openverse_media-#{OpenverseFixture.media_fold_openverse_id()}" in shelf_ids(
             html
           )
  end

  test "the credit line links the creator and the licence the item named (D3)", %{
    context: context,
    target: target
  } do
    deliver!(context, target)
    states = Discovery.states(target.object_id)
    html = render_component(&Culture.section/1, states: states)
    document = LazyHTML.from_fragment(html)

    # D2 of #126: the line Openverse composes is one sentence naming the two
    # things the licence asks for, and both of them are linked. Its licence
    # is now spelled the same way in the prose and in the field — the needle
    # matcher still treats hyphens and spaces alike, which is what lets a
    # provider that spells them differently link anyway.
    openverse = item!(states, Openverse.slug(), "c80387bb-2dd9-489e-a748-75a1be138f5a")
    credit = credit(document, openverse)

    assert text(credit) == openverse.preview_metadata["attribution"]

    links = credit |> LazyHTML.query("a") |> Enum.map(&{text(&1), href(&1)})

    assert {"zbigphotography (1M+ views)", openverse.preview_metadata["creator_url"]} in links

    assert {"CC-BY-SA-2.0", openverse.preview_metadata["license_url"]} in links
    assert openverse.preview_metadata["license"] == "CC-BY-SA-2.0"

    # Nothing else in the sentence is a link, and the sentence is the whole
    # credit: two anchors, and every other run plain. The only underlined
    # thing on the card's credit is what the licence asks to be underlined.
    assert length(links) == 2
    assert credit |> LazyHTML.query("[class*=underline]") |> Enum.count() == 2

    # The credit's own step on the card's type scale (#126 Phase 2). Measured
    # on 131 real image credits: at `text-sm` the median credit was four rows
    # under a 96 px thumbnail and the longest ten; at `text-xs` the median is
    # three. A credit is an obligation, not reading matter, and it sits below
    # the title, the year and the artist rather than beside them.
    assert credit |> LazyHTML.attribute("class") |> hd() =~ "text-xs"

    # Commons's public-domain file names an author page and no licence URL, so
    # the creator links and the licence stays plain text. The sentence is the
    # same sentence either way.
    commons = item!(states, Commons.slug(), "1001")
    commons_credit = credit(document, commons)

    assert text(commons_credit) == commons.preview_metadata["attribution"]
    refute commons.preview_metadata["license_url"]

    assert commons_credit |> LazyHTML.query("a") |> Enum.map(&{text(&1), href(&1)}) == [
             {"Fixture", "https://commons.wikimedia.org/wiki/User:Fixture"}
           ]
  end

  defp credit(document, item) do
    LazyHTML.query(
      document,
      "#culture-attribution-#{item.external_namespace}-#{item.external_id}"
    )
  end

  defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp href(node), do: node |> LazyHTML.attribute("href") |> List.first()

  test "both providers are credited once, and every card carries its credit without hover", %{
    context: context,
    target: target
  } do
    deliver!(context, target)
    html = render_component(&Culture.section/1, states: Discovery.states(target.object_id))

    assert count(html, "#culture-provider-#{Commons.slug()}") == 1
    assert count(html, "#culture-provider-#{Openverse.slug()}") == 1

    # `:image` is `:required`: a credit on every card the rail shows, and the
    # folded copy is not a card, so it is not owed one.
    for id <- shelf_ids(html) do
      credit = String.replace_prefix(id, "culture-result-", "culture-attribution-")
      assert count(html, "##{credit}") == 1
    end
  end

  test "M4's six fixed names are on both providers' items", %{context: context, target: target} do
    deliver!(context, target)
    states = Discovery.states(target.object_id)

    commons = item!(states, Commons.slug(), "1001")
    openverse = item!(states, Openverse.slug(), "c80387bb-2dd9-489e-a748-75a1be138f5a")

    for item <- [commons, openverse],
        name <- ~w(license license_url creator creator_url attribution source_url) do
      assert Map.has_key?(item.preview_metadata, name),
             "#{item.external_namespace} carries no #{name}"
    end

    # Commons derives them from `extmetadata`, keeping `credit_line` as it was.
    assert commons.preview_metadata["creator"] == "Fixture"

    assert commons.preview_metadata["creator_url"] ==
             "https://commons.wikimedia.org/wiki/User:Fixture"

    assert commons.preview_metadata["license"] == "Public domain"

    assert commons.preview_metadata["credit_line"] ==
             "Fixture, Public domain, via Wikimedia Commons"

    # No `Attribution` on this file, so the line is the composed one.
    assert commons.preview_metadata["attribution"] == commons.preview_metadata["credit_line"]

    # Openverse composes its own, and its licence is the short form M4 names.
    # D2 of #126: one sentence, the creator and the licence in it, no URL —
    # where it used to forward Openverse's *…To view a copy of this license,
    # visit https://…* boilerplate and render seven rows under the thumbnail.
    assert openverse.preview_metadata["license"] == "CC-BY-SA-2.0"
    assert openverse.preview_metadata["creator"] == "zbigphotography (1M+ views)"

    assert openverse.preview_metadata["attribution"] ==
             "\"war\" by zbigphotography (1M+ views), CC-BY-SA-2.0"

    refute openverse.preview_metadata["attribution"] =~ "http"
    assert openverse.preview_metadata["source_url"] =~ "flickr.com"
    # The upstream file, not the Openverse thumbnail: the join key of last resort.
    assert openverse.preview_metadata["image_url"] =~ "live.staticflickr.com"
    assert openverse.preview_metadata["thumbnail_url"] =~ "/thumb/"
  end

  test "the shelf carries both evidence classes the image row admits", %{
    context: context,
    target: target
  } do
    deliver!(context, target)
    states = Discovery.states(target.object_id)

    commons = item!(states, Commons.slug(), "1001")
    openverse = item!(states, Openverse.slug(), "c80387bb-2dd9-489e-a748-75a1be138f5a")

    assert [%MatchReason{kind: :depiction} | _] =
             commons_reasons = MatchReason.from_result(commons.match_details, "soldier")

    assert Enum.all?(commons_reasons, &(MatchReason.evidence(&1) == :identity))

    assert [%MatchReason{kind: :query} = search] =
             MatchReason.from_result(openverse.match_details, "soldier")

    assert MatchReason.evidence(search) == :query

    # M6: the only shelf that may say this, and it says it.
    assert MatchReason.describe(search, [:identity, :query]) ==
             "Search result for “soldier”, ranked by the provider and not matched on an identifier."

    html = render_component(&Culture.section/1, states: states)
    assert html =~ "Search result for"
  end

  test "a gated licence and a repeated upload never become items", %{
    context: context,
    target: target
  } do
    CommonsFixture.stub(:empty, context)
    openverse = OpenverseFixture.stub(:paged, context)

    assert {:queued, run} = Discovery.request(target, Openverse.slug())
    assert :ok = Discovery.execute_run(run.id)

    ids = List.flatten(openverse.pages)

    # Dropped on its own `by-nc-nd`, although the search narrowed `license` to
    # four others: the gate is on the object, never on the query.
    refute "086e0224-d94a-4f8d-b567-f9e656ecc999" in ids

    # Dropped as the same photographer's second frame of the same title, which
    # is not the same *file* and so is not `Shelf.dedup/2`'s to fold.
    refute "30f952b5-31f6-4a33-9e26-3769ef51a3c1" in ids

    states = Discovery.states(target.object_id)
    refute Enum.any?(states[Openverse.slug()].items, &(&1.external_id =~ "086e0224"))
  end
end
