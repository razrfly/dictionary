defmodule DevilsDictionary.Discovery.Conformance.MultiSourceConformanceTest do
  @moduledoc """
  The multi-source shelf check (#116 Phase 1; K6 of #109).

  Two providers declaring the same content type, each answering eight items
  with one shared identity and one shared media URL, must render **one** shelf
  of fourteen items, interleaved by tier and then slug, each provider credited
  once in the shelf header, the required attribution line present on every
  item, and each reason described against the row's own `evidence`.

  Written against `DevilsDictionary.Discovery` and `DevilsDictionaryWeb.Culture`
  and nothing else, like the single-provider suite: both stubs go through
  admission, the transport and persistence, and the shelf is read back through
  `Discovery.states/1`, which is what the word page reads.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{ContentTypes, MultiSourceStub, Run}
  alias DevilsDictionary.Discovery.MultiSource.{Middle, Plebs}
  alias DevilsDictionary.Repo
  alias DevilsDictionaryWeb.Culture

  @moduletag :conformance

  # Registered with the lesser tier first, so registry order cannot be what
  # the shelf's order comes from.
  @providers [Plebs, Middle]

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, @providers)

    Application.put_env(:devils_dictionary, :discovery_req_options,
      plug: {Req.Test, MultiSourceStub}
    )

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
    end)

    context = %{sources: catalog.sources, scopes: catalog.scopes}
    word = word!(context, "soldier", ~w(wordnet))
    sense!(context, word, "wordnet", gloss: "one who serves in an army")

    target = %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }

    Map.merge(context, %{target: target})
  end

  defp deliver!(target) do
    delivered = MultiSourceStub.stub(@providers)

    for provider <- @providers do
      assert {:queued, run} = Discovery.request(target, provider.slug())
      assert :ok = Discovery.execute_run(run.id)
      assert Repo.get!(Run, run.id).status == :succeeded
    end

    delivered
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

  test "two providers on one type render one shelf of fourteen, interleaved by tier then slug",
       %{target: target} do
    delivered = deliver!(target)
    assert map_size(delivered) == 2
    assert Enum.all?(delivered, fn {_provider, ids} -> length(ids) == 8 end)

    states = Discovery.states(target.object_id)
    assert map_size(states) == 2
    assert states[Middle.slug()].tier == :middle
    assert states[Plebs.slug()].tier == :plebs

    for {_slug, state} <- states do
      assert state.status == :ready
      assert length(state.items) == 8
    end

    html = render_component(&Culture.section/1, states: states)

    # One shelf, the `:image` one, and no second heading anywhere.
    assert count(html, "[id^='culture-shelf-']") == 1
    assert count(html, "#culture-shelf-image") == 1
    assert count(html, "#culture-filter-image") == 1

    # Sixteen delivered, fourteen shown: the Plebs stub's first item shares an
    # upstream identity with the Middle stub's first, and its second shares a
    # media URL with the Middle stub's second (spelled with a different scheme
    # case, host case and query string). The better-tiered copy survives.
    ids = shelf_ids(html)
    assert length(ids) == 14

    middle = fn index -> "culture-result-stub_middle-zz-middle-stub-#{index}" end
    plebs = fn index -> "culture-result-stub_plebs-aa-plebs-stub-#{index}" end

    # Tier before slug: `zz-middle-stub` leads `aa-plebs-stub`. Then turns —
    # item 1 of each, item 2 of each — with the Plebs stub's surviving items
    # starting at its third, and the Middle stub's last two alone once the
    # other has run out.
    assert ids == [
             middle.(1),
             plebs.(3),
             middle.(2),
             plebs.(4),
             middle.(3),
             plebs.(5),
             middle.(4),
             plebs.(6),
             middle.(5),
             plebs.(7),
             middle.(6),
             plebs.(8),
             middle.(7),
             middle.(8)
           ]

    refute plebs.(1) in ids
    refute plebs.(2) in ids
  end

  test "each provider is credited once in the shelf header", %{target: target} do
    deliver!(target)
    html = render_component(&Culture.section/1, states: Discovery.states(target.object_id))

    assert count(html, "#culture-provider-#{Middle.slug()}") == 1
    assert count(html, "#culture-provider-#{Plebs.slug()}") == 1
    assert html =~ "Middle stub"
    assert html =~ "Plebs stub"

    # And each has its own note; the shelf's byline is not a merged provider.
    assert count(html, "#culture-about-#{Middle.slug()}") == 1
    assert count(html, "#culture-about-#{Plebs.slug()}") == 1
  end

  test "the required attribution line is present on every item, not on hover",
       %{target: target} do
    assert ContentTypes.attribution(:image) == :required

    deliver!(target)
    html = render_component(&Culture.section/1, states: Discovery.states(target.object_id))
    document = LazyHTML.from_fragment(html)

    ids = shelf_ids(html)
    assert ids != []

    for id <- ids do
      credits = LazyHTML.query(document, "##{id} [id^='culture-attribution-']")
      assert Enum.count(credits) == 1, "#{id} renders without its attribution line"

      text = credits |> LazyHTML.text() |> String.trim()
      assert text =~ ~r/^Photographer \d+, CC BY 4\.0, via (Middle|Plebs) stub$/

      # Always visible: nothing on the credit or its ancestors within the card
      # hides it until a pointer arrives.
      refute LazyHTML.query(
               document,
               "##{id} [class*='group-hover:'] [id^='culture-attribution-']"
             )
             |> Enum.any?()

      refute LazyHTML.query(document, "##{id} [id^='culture-attribution-'][class*='hover']")
             |> Enum.any?()
    end
  end

  test "each reason is described against the shelf's own evidence row", %{target: target} do
    deliver!(target)
    html = render_component(&Culture.section/1, states: Discovery.states(target.object_id))

    # The identity stub names the QID it matched on; the search stub is called
    # the search result it is (M6), because the `:image` row admits `:query`.
    assert html =~ "Direct depiction of “soldier” (Q4991371)."

    assert html =~
             "Search result for “soldier”, ranked by the provider and not matched on an identifier."

    refute html =~ "The provider returned this result"

    assert ContentTypes.evidence(:image) == [:identity, :query]
  end
end
