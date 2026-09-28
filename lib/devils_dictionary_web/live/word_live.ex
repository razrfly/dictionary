defmodule DevilsDictionaryWeb.WordLive do
  @moduledoc """
  `/on/:slug` and `/words/:id/:slug` — a page for every word in the index
  (#71 §8a), and the everyday reading entry (#219).

  The whole page is one round of queries in `handle_params/3`, well under the
  150 ms #71 §7 budgets and nowhere near the 2.5 s long-poll fallback the S4
  audit drew the line at: `mount/3` runs three times over a page's life (dead
  render, connected mount, and again on every reconnect), so anything slow
  there is slow three times and can abandon its own websocket.

  For the same reason the page is rebuilt only when the word or the walk
  changes. Opening the ⓘ drawer is a patch to the same word, so it re-runs
  `handle_params/3`; without the guard every ⓘ click would re-run ten queries
  to render the page it is already on.

  Nothing here raises. `/on/zzzz` is a page that says *no such word* and
  offers the nearest words the trigram can find (served as a 404 by
  `DevilsDictionaryWeb.ReadingStatus`); a bare index row is a page with a
  headword and a promise. X1 renders 200 random index lexemes and most of the
  index is bare.

  ## Two ways in, and only one of them is identity

  ADR decision 10. `/words/:id/:slug` is **canonical**: the id is the word's
  `object_id`, and the slug is a readable tail nothing reads back; a missing
  id is a miss, never a word found by the slug. `/on/:slug` is the
  **aggregate**, kept because a slug is what a reader types — but a slug is
  lossy. 28,306 slug groups hold more than one distinct lemma (`C++`, `C+` and
  `c` share `c`). So when a slug reaches several distinct lemmas this page
  offers the choice instead of silently picking one, and every word it lists
  links to its canonical address. An exact selection — from search, a card, a
  drawer — keeps `/words/:id/:slug` through navigation and reload.

  ## On (#219)

  `/on/:slug` adds what an On page is to the words:

    * the **authored overview** allocated at that very address, when the
      resolver serves it in the reader's mode — above the words when its
      lexical membership names them, as a separate choice when it does not
      (`Routing.OnPage`: identity, never a shared spelling);
    * the overviews elsewhere whose membership names these words, linked;
    * the **Subjects** section (`Routing.Subjects`): the overview's curated
      members in its order, then the subjects the sources and names reach,
      each at its address or its exact identity.

  The reading mode (`DevilsDictionaryWeb.ReadingMode`) decides what is
  served; this page writes nothing.
  """

  use DevilsDictionaryWeb, :live_view

  # Read-only: the current scope, which tells the page whether the reader may
  # carry an artwork candidate into the review composer (it grants nothing;
  # `/connect` is still gated on the server by `:require_internal_contributor`),
  # and the reading mode every link and address on the page is decided in.
  on_mount DevilsDictionaryWeb.ReadingMode

  alias DevilsDictionary.Demo, as: Samples
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.ContentTypes
  alias DevilsDictionary.Discovery.Providers
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Curation.Opening, as: CuratedOpening
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Routing.{Links, OnPage}
  alias DevilsDictionary.Routing.Subjects, as: SubjectCards

  alias DevilsDictionaryWeb.{
    CrowdCard,
    Culture,
    Demo,
    Examples,
    Opening,
    Provenance,
    SourceBadge,
    Subjects,
    Thing,
    Word
  }

  @trail_cap 12
  @suggestions 5

  # The key the committed catalog's shelf state travels under. It is not a
  # provider slug and never reaches `Discovery`, which is why it cannot collide
  # with one.
  @catalog_shelf "catalog"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       slug: nil,
       trail: [],
       page: nil,
       demo: false,
       evidence: [],
       object_id: nil,
       choices: [],
       # A definition's artwork candidate is only a candidate. An internal
       # contributor needs the composer link on the shelf to carry it into the
       # review flow with its exact sense and source-record evidence
       # preselected; everyone else sees the candidate and no write path.
       contributor: Contributions.internal_contributor?(socket.assigns[:current_scope]),
       discovery_target: nil,
       cultures: %{},
       culture_notes: [],
       opening: nil,
       opening_reader: nil,
       # The page's own path, as in the address bar: what its drawers patch
       # to, so an exact word keeps its identity through a reload.
       base: nil,
       exact: nil,
       overview: nil,
       choice_overview: nil,
       choice_paths: %{},
       linked_overviews: [],
       subjects: nil,
       follow: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id, "slug" => slug} = params, uri, socket) do
    # The canonical address. The id is identity; a slug that does not match is
    # a redirect rather than an error, so an old link keeps working and the
    # address bar tells the truth.
    #
    # `Map.delete(params, "id")` before delegating, always: leaving it in would
    # match this clause again, for ever.
    resolver = Map.delete(params, "id")

    # A missing id is a miss, and never the word the slug would find: the
    # slug is a readable tail, not an identity (ADR 0004 §4).
    case Lexicon.by_object_id(id) do
      nil ->
        handle_params(resolver, uri, assign(socket, object_id: nil, exact: :missing))

      lexeme ->
        if slug == lexeme.slug do
          handle_params(resolver, uri, assign(socket, object_id: lexeme.object_id, exact: :found))
        else
          {:noreply, push_navigate(socket, to: ~p"/words/#{id}/#{lexeme.slug}")}
        end
    end
  end

  def handle_params(%{"slug" => slug} = params, uri, socket) do
    socket =
      if socket.assigns.live_action == :on,
        do: assign(socket, object_id: nil, exact: nil),
        else: socket

    # Not text (bad UTF-8, a NUL): no word can have it, and no query may see
    # it. The page says so, under the plug's 400.
    {slug, socket} =
      if DevilsDictionary.Routing.Input.text?(slug),
        do: {slug, socket},
        else: {"", assign(socket, object_id: nil, exact: :invalid)}

    base = URI.parse(uri).path
    trail = parse_trail(params["trail"])
    demo = Samples.on?(params)
    # `nil` everywhere a public page is rendered: Phase 1's only reader is the
    # development fixture, gated by config and by `?opening=fixture` (#156).
    reader = CuratedOpening.reader(params)

    # The path is part of the guard: `/on/c` and `/words/<C++>/c` share a slug
    # and are two pages.
    socket =
      if base == socket.assigns.base and slug == socket.assigns.slug and
           trail == socket.assigns.trail and demo == socket.assigns.demo and
           reader == socket.assigns.opening_reader and
           socket.assigns[:loaded_mode] == socket.assigns.reading_mode do
        socket
      else
        load(assign(socket, :base, base), slug, trail, demo, reader)
      end

    case socket.assigns[:follow] do
      nil ->
        {:noreply,
         assign(socket, :provenance, provenance(socket.assigns.page, params["provenance"]))}

      # An equivalent spelling of an overview's address, followed as the
      # plug answers a direct request: to the canonical, one hop.
      location ->
        {:noreply, push_navigate(assign(socket, :follow, nil), to: location, replace: true)}
    end
  end

  # A sample card's drawer is invented too. Falling through to
  # `WordPage.provenance/2` would put the word's real concept links under a
  # card that does not exist, which is the one dishonest thing the mode could
  # do.
  defp provenance(page, ref) do
    Samples.provenance(page, ref || "") || WordPage.provenance(page, ref)
  end

  defp load(socket, slug, trail, demo, reader) do
    # A contributor or reviewer reads the exemplars as `:internal`, so a
    # nomination still under review shows, marked; everyone else reads the
    # public view, where a person nominated here waits for acceptance.
    viewer = if socket.assigns.contributor, do: :internal, else: :public

    page = socket.assigns |> lookup(slug) |> WordPage.build(trail: trail, viewer: viewer)

    samples =
      if demo, do: Samples.samples(page.headword.lemma || slug), else: %{cards: [], evidence: []}

    # The curated opening (#156) reads the page as built, before any sample is
    # merged: it quotes real entries by their exact revisions, and a sample
    # card is neither. Database reads only — no provider, no model.
    opening = CuratedOpening.for_page(page, reader)

    # Counted before the samples go in: the source line is a claim about what has
    # been absorbed, and "8 sources" on a page where three of them are invented
    # would be the mode telling a lie the banner cannot take back.
    card_sources = page.cards |> Enum.map(& &1.source.name) |> Enum.uniq()
    page = if demo, do: Samples.decorate(page, samples), else: page

    socket =
      socket
      |> assign(:slug, slug)
      |> assign(:trail, trail)
      |> assign(:demo, demo)
      |> assign(:evidence, samples.evidence)
      |> assign(:page, page)
      |> assign(:opening, opening)
      |> assign(:opening_reader, reader)
      |> assign(:card_sources, card_sources)
      |> assign(:suggestions, suggestions(page, slug))
      |> assign(:choices, choices(slug, socket.assigns.object_id))
      |> assign(:loaded_mode, socket.assigns.reading_mode)
      |> assign_on(page)

    socket
    |> assign(:page_title, title(page, slug, socket.assigns))
    |> prepare_discovery(page, demo)
  end

  # What On adds to the words (#219): the overview at this address, the
  # overviews elsewhere that name these words, and the Subjects section. One
  # resolver read for the address, one query for the overviews that name the
  # words, one bounded query for every card.
  defp assign_on(socket, page) do
    mode = socket.assigns.reading_mode
    lexeme_ids = Enum.map(page.headword.lexemes, & &1.id)

    at_address =
      if socket.assigns.live_action == :on,
        do: OnPage.overview(socket.assigns.base, lexeme_ids, mode)

    # A moved overview's old address answers with it only where no word
    # holds the slug: words are never redirected away (#219 B1).
    {overview, follow} =
      case at_address do
        %{resolution: %{outcome: :redirect, location: location}} when lexeme_ids == [] ->
          {nil, DevilsDictionary.Routing.Address.encode(location)}

        %{resolution: %{outcome: :redirect}} ->
          {nil, nil}

        %{resolution: _gone_or_corrupt} ->
          {nil, nil}

        overview ->
          {overview, nil}
      end

    # The overview belongs to these words only by its lexical membership; with
    # no words on the page it is the page.
    {treatment, choice} =
      cond do
        is_nil(overview) -> {nil, nil}
        overview.associated? or lexeme_ids == [] -> {overview, nil}
        true -> {nil, overview}
      end

    curated =
      for %{kind: :subject, object_id: id, relationship: rel} <-
            (treatment && treatment.members) || [],
          rel in [:discusses_subject, :editorial_association],
          do: id

    lemmas = page.headword.lexemes |> Enum.map(& &1.lemma) |> Enum.uniq()

    subjects =
      if lexeme_ids != [] or treatment,
        do: SubjectCards.cards(curated, discovered(page.thing), lemmas, mode)

    choice_paths =
      if choice,
        do:
          Links.paths(
            for(
              %{kind: :subject, object_id: id, label: label} <- choice.members,
              do: {id, label}
            ),
            mode
          ),
        else: %{}

    socket
    |> assign(:overview, treatment)
    |> assign(:choice_overview, choice)
    |> assign(:choice_paths, choice_paths)
    |> assign(:linked_overviews, OnPage.linked(lexeme_ids, mode, overview && overview.page.id))
    |> assign(:subjects, subjects)
    |> assign(:follow, follow)
  end

  # The identities the page's sources name: the thing, the disagreement and
  # the `may_refer_to` candidates. Name matches are the query's own.
  defp discovered(nil), do: []

  defp discovered(thing) do
    concept = if thing[:concept], do: [thing.concept.object_id], else: []

    concept ++
      Enum.map(thing[:disagreement] || [], & &1.object_id) ++
      Enum.map(thing[:may_refer_to] || [], & &1.object_id)
  end

  defp prepare_discovery(socket, page, demo) do
    target = Discovery.target_for_page(page, socket.assigns.object_id, demo)
    old_target = socket.assigns.discovery_target

    culture_providers =
      Providers.server_providers()
      |> Enum.filter(fn provider ->
        ContentTypes.any_known?(provider.capabilities().content_types) and
          Discovery.covers?(provider, target)
      end)

    if (connected?(socket) and old_target) &&
         (!target || old_target.object_id != target.object_id) do
      Discovery.unsubscribe(old_target.object_id)
    end

    cultures =
      cond do
        is_nil(target) or culture_providers == [] ->
          %{}

        connected?(socket) ->
          if is_nil(old_target) or old_target.object_id != target.object_id do
            :ok = Discovery.subscribe(target.object_id)
          end

          culture_providers
          |> Enum.map(fn provider ->
            {provider.slug(), Discovery.request(target, provider.slug())}
          end)
          |> Enum.reduce(%{}, fn {provider_slug, outcome}, states ->
            state =
              target.object_id
              |> Discovery.state(provider_slug)
              |> Map.merge(%{term: target.term, relevance: target.relevance})
              |> state_for_outcome(outcome)

            if state.mapping_id || state.status != :idle,
              do: Map.put(states, provider_slug, state),
              else: states
          end)

        true ->
          culture_providers
          |> Enum.map(fn provider ->
            attrs = provider.source_attrs()

            {provider.slug(),
             %{
               status: :loading,
               items: [],
               provider: provider.slug(),
               provider_name: attrs.name,
               content_types: provider.capabilities().content_types,
               mapping_id: nil,
               term: target.term,
               relevance: target.relevance
             }}
          end)
          |> Map.new()
      end

    cultures =
      cultures
      |> Map.merge(catalog_shelf(page, target))
      |> Map.merge(quote_corpus_shelf(page, target))

    socket
    |> assign(:discovery_target, target)
    |> assign(:cultures, cultures)
    |> assign(:culture_notes, uncovered_notes(target, culture_providers, cultures))
    # Every browser-transport provider the registry holds, in registry order,
    # asked for its own config — rather than one named module (#144 Phase 3).
    # A second one is a registration and nothing here.
    |> assign(:browsers, Enum.map(Providers.browser_providers(target), &elem(&1, 1)))
    |> assign(:urban_dictionary, DevilsDictionary.Sources.UrbanDictionary.browser_config(target))
    |> assign_page_sources()
  end

  # Every source that put something on this page, for the rail's stack (#152):
  # the definition sources, the thing's encyclopedia rows, the Crowd card, each
  # shelf's contributors — a catalog state opened into the corpora on it — and
  # the browser shelves. Tier then slug, one badge per slug, each with the
  # anchor of the block it stands for. Recomputed whenever the states that
  # feed it are assigned, which is what makes the stack grow as results land.
  defp assign_page_sources(socket) do
    %{page: page, cultures: cultures, browsers: browsers, urban_dictionary: crowd} =
      socket.assigns

    assign(socket, :page_sources, page_sources(page, cultures, browsers, crowd))
  end

  defp page_sources(page, cultures, browsers, crowd) do
    definitions =
      for group <- page.source_groups,
          do: badge_entry(group.source, "#" <> group.card_id)

    thing =
      case page.thing do
        %{} = thing ->
          [
            thing.article && thing.article.source &&
              badge_entry(thing.article.source, "#thing-article"),
            thing[:wikidata_source] && badge_entry(thing.wikidata_source, "#concept-card")
          ]

        _none ->
          []
      end

    # Every source that named a thing under this word's meanings, anchored at
    # the section that says so.
    examples =
      case page.examples do
        %{sources: sources} -> Enum.map(sources, &badge_entry(&1, "#examples"))
        _none -> []
      end

    crowd =
      case crowd do
        %{source: source, term: term} ->
          [badge_entry(source, "#urban-dictionary-" <> Base.url_encode64(term, padding: false))]

        _none ->
          []
      end

    shelves =
      cultures
      |> Map.values()
      |> Enum.filter(&(&1.items != []))
      |> Enum.flat_map(&shelf_sources/1)

    browser =
      for config <- browsers do
        badge_entry(
          %{slug: config.provider, name: config.provider_name, tier: Map.get(config, :tier)},
          "#culture-filter-#{config.content_type}-#{config.provider}"
        )
      end

    # One read of the rows for the marks: a shelf state carries its own, but a
    # catalog corpus is named by its items and a browser config by what it
    # chose to send, and the row is where the logo lives (#152 Phase 4).
    logos = Map.new(DevilsDictionary.Sources.list_sources(), &{&1.slug, &1.logo})

    (definitions ++ examples ++ thing ++ crowd ++ shelves ++ browser)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{&1 | logo: &1.logo || logos[&1.slug]})
    |> SourceBadge.compose()
  end

  # A live state is one source; the catalog state is however many corpora put
  # an item on it, each named by its own item, so the Met and Wikidata are two
  # badges rather than one called *Saved catalog*.
  defp shelf_sources(%{archetype: :corpus, items: items} = state) do
    anchor = shelf_anchor(state)

    items
    |> Enum.map(
      &%{
        slug: Map.get(&1, :source_slug),
        name: &1.preview_metadata["provider"],
        tier: Map.get(&1, :source_tier)
      }
    )
    |> Enum.reject(&is_nil(&1.slug))
    |> Enum.uniq_by(& &1.slug)
    |> Enum.map(&badge_entry(&1, anchor))
  end

  defp shelf_sources(state) do
    [
      badge_entry(
        %{
          slug: state.provider,
          name: state.provider_name,
          tier: Map.get(state, :tier),
          logo: Map.get(state, :logo)
        },
        shelf_anchor(state)
      )
    ]
  end

  # The shelf a state renders on is its content type's row (`Culture` keys
  # shelves the same way), and the row's id is stable however the shelves sort.
  defp shelf_anchor(state) do
    types = Map.get(state, :content_types) || []
    type = Enum.find(types, :film, &(&1 in ContentTypes.known()))
    "#culture-shelf-#{type}"
  end

  defp badge_entry(source, anchor) do
    %{
      slug: Map.get(source, :slug),
      name: Map.get(source, :name) || Map.get(source, :slug),
      tier: Map.get(source, :tier),
      logo: Map.get(source, :logo),
      anchor: anchor
    }
  end

  # The committed catalog as one more state on the shared shelf (K2 of #109).
  # It is not a provider: nothing is requested, no mapping exists and no run is
  # admitted — the works are already local and the match is a QID the
  # encyclopedia already asserts. `archetype: :corpus` is what sorts it after
  # the live results and what makes its note say *held locally* rather than
  # *searched for*.
  defp catalog_shelf(%{headword: %{lexemes: []}}, _target), do: %{}

  defp catalog_shelf(page, target) do
    lexeme_ids =
      if target,
        do: Discovery.page_lexeme_ids(target),
        else: Enum.map(page.headword.lexemes, & &1.id)

    case Artworks.shelf_items(lexeme_ids) do
      [] ->
        %{}

      items ->
        %{
          @catalog_shelf => %{
            status: :ready,
            archetype: :corpus,
            items: items,
            provider: @catalog_shelf,
            provider_name: "Saved catalog",
            provider_detail: catalog_providers(items),
            corpora: catalog_providers(items),
            # A corpus never refreshes, by design, so the honest thing to say
            # about its age is when it was made: the `generated_at` of the
            # committed manifests these items came from, oldest first (#144
            # Phase 2).
            held_since:
              items
              |> Enum.map(& &1[:source_slug])
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()
              |> Corpus.Manifest.held_since(),
            content_types: [:artwork],
            mapping_id: nil,
            term: page.headword.lemma,
            relevance: if(length(page.headword.lexemes) > 1, do: "term_unverified", else: "term")
          }
        }
    end
  end

  # #172 build C: a provider that declined this page says why, when it has a
  # sentence for it and nothing else filled its content type. Asked of the
  # registry and `covers?/1` only — no request, no row.
  defp uncovered_notes(nil, _covering, _cultures), do: []

  defp uncovered_notes(_target, covering, cultures) do
    filled = cultures |> Map.values() |> Enum.flat_map(&(&1[:content_types] || []))

    for provider <- Providers.server_providers(),
        provider not in covering,
        Code.ensure_loaded?(provider) and function_exported?(provider, :uncovered_note, 0),
        note = provider.uncovered_note(),
        is_binary(note),
        type = Enum.find(provider.capabilities().content_types, &(&1 in ContentTypes.known())),
        type not in filled,
        do: %{type: type, text: note}
  end

  # The public-domain Wikiquote corpus as one more state on the Quotes shelf
  # (#174): like the catalog, nothing is requested and no run is admitted —
  # the lines are seeded, and the match is a concept the page's senses already
  # refer to. `archetype: :corpus` makes every card say *held locally*; on
  # this shelf alone it also opens the 👑 band rather than trailing it
  # (decision 2, `Culture.archetype_rank/1`).
  defp quote_corpus_shelf(%{headword: %{lexemes: []}}, _target), do: %{}

  defp quote_corpus_shelf(page, target) do
    lexeme_ids =
      if target,
        do: Discovery.page_lexeme_ids(target),
        else: Enum.map(page.headword.lexemes, & &1.id)

    slug = DevilsDictionary.Quotations.Corpus.slug()

    case DevilsDictionary.Quotations.Corpus.shelf_items(lexeme_ids) do
      [] ->
        %{}

      items ->
        source = DevilsDictionary.Sources.get_source_by_slug(slug)

        %{
          slug => %{
            status: :ready,
            archetype: :corpus,
            items: items,
            provider: slug,
            provider_name: "Wikiquote, public domain",
            provider_detail: "a verified public-domain selection",
            # The row's own mark on the card and in the byline: the corpus is
            # Wikiquote's words, and says so the way the live shelf does.
            tier: source && source.tier,
            logo: source && source.logo,
            held_since: Corpus.Manifest.held_since([slug]),
            content_types: [:quote],
            mapping_id: nil,
            term: page.headword.lemma,
            relevance: "term"
          }
        }
    end
  end

  # Whoever is actually on this shelf, in the order the interleave put them, so
  # the byline is a fact about the items rather than a list of the corpora that
  # exist.
  defp catalog_providers(items) do
    items
    |> Enum.map(& &1.preview_metadata["provider"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "the local catalog"
      # Commas, not the interpuncts the byline itself is joined with: "Saved
      # catalog · Wikidata · The Met" reads as three providers.
      providers -> Enum.join(providers, ", ")
    end
  end

  # A provider that declined the target is not a provider in trouble: there is
  # nothing to report and nothing to wait for, so the shelf never appears.
  defp state_for_outcome(state, {:error, :target_not_covered}), do: state

  defp state_for_outcome(state, {:deferred, _reason}) when state.status == :idle,
    do: Map.put(state, :status, :deferred)

  defp state_for_outcome(state, {:error, _reason}) when state.status == :idle,
    do: Map.put(state, :status, :failed)

  defp state_for_outcome(state, _outcome), do: state

  @impl true
  def handle_info(
        {:discovery_updated, target_id, mapping_id, provider_slug, transient_items},
        %{assigns: %{discovery_target: %{object_id: target_id} = target}} = socket
      ) do
    current = Discovery.state(target_id, provider_slug)

    cond do
      not Providers.supports_any?(provider_slug, ContentTypes.known()) ->
        {:noreply, socket}

      current.mapping_id == mapping_id ->
        state =
          if transient_items == [] do
            current
          else
            Map.merge(current, %{status: :ready, items: transient_items})
          end

        state = Map.merge(state, %{term: target.term, relevance: target.relevance})

        {:noreply,
         socket |> update(:cultures, &Map.put(&1, provider_slug, state)) |> assign_page_sources()}

      is_nil(current.mapping_id) ->
        {:noreply,
         socket |> update(:cultures, &Map.delete(&1, provider_slug)) |> assign_page_sources()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:discovery_updated, _target_id, _mapping_id, _provider, _items}, socket),
    do: {:noreply, socket}

  # One *Load more* per shelf, advancing every source on it (#126 D3). The
  # control names the sources it advances, because which sources are on which
  # shelf is the reader's composition and not this module's: `Culture` reads
  # the content-type table to build the shelf, and a second copy of that
  # reading here would be a second answer to the same question. A slug that
  # names no state on this page advances nothing.
  @impl true
  def handle_event("discovery_more", %{"providers" => providers}, socket) do
    {:noreply,
     providers
     |> String.split(",", trim: true)
     |> Enum.reduce(socket, &advance_page/2)}
  end

  defp advance_page(provider_slug, socket) do
    culture = socket.assigns.cultures[provider_slug]
    target = socket.assigns.discovery_target

    if target && culture && culture[:next_cursor] do
      result =
        Discovery.request_next(
          target.object_id,
          culture.provider,
          culture.page_context,
          culture.page,
          culture.next_cursor
        )

      state =
        case result do
          {:queued, _run} ->
            Map.put(culture, :loading_more, true)

          {:cached, _run} ->
            Discovery.state(target.object_id, provider_slug)

          {:deferred, _reason} ->
            culture |> Map.put(:status, :deferred) |> Map.put(:loading_more, false)

          {:error, _reason} ->
            target.object_id
            |> Discovery.state(provider_slug)
            |> Map.merge(%{term: target.term, relevance: target.relevance, loading_more: false})
        end

      socket |> update(:cultures, &Map.put(&1, provider_slug, state)) |> assign_page_sources()
    else
      socket
    end
  end

  # A slug that names more than one *distinct lemma* is ambiguous, and #74 says
  # so out loud rather than picking. `C++`, `C+` and `c` are three identities
  # that share a slug; the page names them and links each to its canonical
  # address.
  #
  # Distinct **lemma**, not distinct lexeme: `cat` the noun and `cat` the verb
  # are two lexemes and one word, and offering a choice between them would be
  # noise. 28,306 slug groups are the real case.
  #
  # Reached by the canonical route there is nothing to choose — the id already
  # said which one — and a miss has nothing to offer.
  defp choices(_slug, object_id) when not is_nil(object_id), do: []

  defp choices(slug, _object_id) do
    case Lexicon.list_by_slug(slug) do
      lexemes when length(lexemes) > 1 ->
        case distinct_words(lexemes, slug) do
          [_one] -> []
          words -> words
        end

      _ ->
        []
    end
  end

  # One row per *word*, and `LoVe` is not a word beside `Love` (#133 R6). A
  # case-only variant is a Wiktionary spelling of the same identity, and
  # offering it as a choice asks the reader to pick between two of the same
  # thing — the noise #133 §5 measured on `love`.
  #
  # Which of a case-group survives is decided, not incidental: the enriched row
  # first, because it is the one with a page worth reaching, then the spelling
  # closest to the address the reader typed — `love`, then `Love`, then
  # whatever else — then the lemma itself so the answer never depends on the
  # query's collation.
  defp distinct_words(lexemes, slug) do
    lexemes
    |> Enum.sort_by(&{is_nil(&1.enriched_at), case_rank(&1.lemma, slug), &1.lemma})
    |> Enum.uniq_by(&String.downcase(&1.lemma))
  end

  defp case_rank(lemma, slug) do
    cond do
      lemma == slug -> 0
      lemma == String.capitalize(slug) -> 1
      true -> 2
    end
  end

  # The canonical address names one word, so it renders that word — not
  # whatever else shares its slug. `/words/<C++>/c` is a page about `C++`;
  # `/on/c` is a page about everything the slug reaches. That difference is
  # the whole reason there are two routes.
  defp lookup(%{exact: :missing}, _slug), do: %{lexemes: [], via: :none, matched: nil}

  defp lookup(%{object_id: object_id}, _slug) when is_integer(object_id) do
    case Lexicon.by_object_id(object_id) do
      nil -> %{lexemes: [], via: :none, matched: nil}
      lexeme -> %{lexemes: [lexeme], via: :lemma, matched: lexeme.lemma}
    end
  end

  defp lookup(_assigns, slug), do: Lexicon.lookup(slug)

  # Only a miss pays for suggestions: on every other page the trigram would be
  # answering a question nobody asked.
  defp suggestions(_page, ""), do: []

  defp suggestions(%{headword: %{lexemes: []}}, slug) do
    slug
    |> Lexicon.search(limit: @suggestions)
    |> Enum.uniq_by(& &1.slug)
  end

  defp suggestions(_page, _slug), do: []

  # The trail is user input arriving in a URL, so it is parsed rather than
  # trusted: slugs only, deduplicated, and the most recent twelve. #71 §10
  # keeps it here instead of in socket state so a walk survives a reload and
  # can be pasted to someone else.
  defp parse_trail(nil), do: []

  defp parse_trail(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[a-z0-9-]{1,120}\z/, &1))
    |> Enum.uniq()
    |> Enum.take(-@trail_cap)
  end

  # "On Mars" for the aggregate, the lemma for an exact word, the overview's
  # own title for an overview with no words behind it.
  defp title(%{headword: %{lemma: nil}}, _slug, %{overview: %{revision: revision}}),
    do: revision.title

  defp title(%{headword: %{lemma: nil}}, slug, _assigns), do: "#{slug} — no such word"
  defp title(%{headword: %{lemma: lemma}}, _slug, %{live_action: :on}), do: "On #{lemma}"
  defp title(%{headword: %{lemma: lemma}}, _slug, _assigns), do: lemma

  # "5 sources · 9 entries": a source that filed a noun and a verb is one
  # source, and the entries are counted as what they are.
  # *4 dictionaries · 8 entries*. The word is `Word.dictionaries/1`'s, for the
  # reason given there: *sources* is the stack's word and the stack's number.
  defp count_label(sources, cards) do
    s = length(sources)
    e = length(cards)
    base = Word.dictionaries(sources)
    if e > s, do: "#{base} · #{e} entries", else: base
  end

  # A row continues the one above when they are the same source — the tiers
  # sort a source's parts of speech together, so Johnson's verb follows his
  # noun and needs no second name.
  defp continues?(cards, i) when i > 0 do
    Enum.at(cards, i - 1).source.slug == Enum.at(cards, i).source.slug
  end

  defp continues?(_cards, _i), do: false

  # Which source the page opens on.
  #
  # The first *reference* source, not the first card. A page that opens on its
  # oldest source is a historically-ordered dictionary, and that is the
  # worst-scoring pattern in the literature — McCreary 2008 scored one at 3.96
  # against a sense-ordered dictionary's 7.04, and on one word its readers did
  # worse than readers with no dictionary at all. Johnson and Bierce keep their
  # place at the top of the list, where the tiers put them and where a reader
  # can see them; what they do not get is the open row, because whatever is
  # open is what gets read (#131, `docs/discovery/issue-131-how-others-do-it.md`).
  #
  # A page whose every source is authored — `logomachy` before WordNet reached
  # it — opens on the first one it has rather than on nothing.
  defp default_open(cards) do
    Enum.find_index(cards, &(&1.tier != :aristocracy)) || 0
  end

  defp word_path(%{headword: %{lemma: lemma, lexemes: [lexeme | _]}}),
    do: ~p"/words/#{lexeme.id}/#{DevilsDictionary.Registry.Lexeme.slug(lemma)}"

  defp word_path(_page), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.container class="py-10">
        <Demo.demo_banner :if={@demo} />

        <Word.trail
          trail={@page.trail}
          current={@page.headword.lemma || @slug}
          demo={@demo}
        />

        <%= cond do %>
          <% @page.headword.lexemes == [] and @overview -> %>
            <%!-- An authored overview with no words behind it (#219 B2):
                 the page is the overview, and its chosen subjects. --%>
            <div class="flex max-w-4xl flex-col gap-8">
              <Subjects.overview overview={@overview} heading="h1" />
              <Subjects.section :if={@subjects} subjects={@subjects} members={@overview.members} />
            </div>
          <% @page.headword.lexemes == [] -> %>
            <.miss slug={@slug} suggestions={@suggestions} demo={@demo} exact={@exact} />
          <% true -> %>
            <%!-- #131 Phase 2. What the page knows the size of goes in the rail;
               what a source decides the size of goes in the column beside it.
               The rail is not sticky: it carries facts rather than navigation,
               and the field pins a rail only when the rail is navigation. --%>
            <%!-- A grid, so the document order can be the reading order while the
               rail still sits beside the definitions.
               
               The related words belong *under* the rail on a desktop and
               *after* the definitions everywhere — they are the way out of the
               word, not part of it. In the source they come last; the grid
               puts them back in the first column. Placement, not a second
               copy: two copies is two of every chip id, which LiveView
               refuses outright. --%>
            <%!-- `grid-rows-[auto_1fr]` is load-bearing. The column beside the rail
               spans both rows, and a spanning item's height is shared *equally*
               between `auto` rows — so without it row one stretched to half the
               stream and the related words sat a screen below the rail. Row
               one is the rail's height; the rest is row two's. --%>
            <%!-- The curated opening (#156) changes the reading order, so it
               has its own layout, and only when there is one — without it the
               grid below is exactly what it was.

               On a phone the document order *is* the visual and keyboard
               order: the headword, the opening, the rest of the rail, the
               definitions, the way out. On a desktop the same order is placed
               into two columns with floats rather than the grid, because a
               grid couples its rows across columns: with the opening between
               the headword and the rest of the rail in the source, row one
               would be as tall as the opening and leave a gap under the
               headword. Every block floats — left for the rail's three,
               right for the opening and the definitions — and `clear` stacks
               each column on itself, so neither column's height moves the
               other. (An in-flow block would pin every later float below it.)
               The way out can start no higher than the definitions do, so on
               a word whose opening is taller than its rail it sits a little
               lower under the rail than it does without an opening. No
               `order`, no `display: contents`, no second copy of anything. --%>
            <div :if={@opening} class="lg:flow-root">
              <Word.headword
                headword={@page.headword}
                choices={@choices}
                thing={@page.thing}
                thing_info={@page.thing && Word.info_path(@base, @page.trail, "thing", @demo)}
                demo={@demo}
                class="lg:float-left lg:clear-left lg:w-[22.5rem]"
              />

              <%!-- Nothing in it is fetched and nothing in it changes after the
                 first render for this word; `nil` on every public page in
                 Phase 1 (the development fixture is the only reader). --%>
              <Opening.section
                opening={@opening}
                mode={@reading_mode}
                class="mt-8 lg:float-right lg:mt-0 lg:mb-4 lg:w-[calc(100%-25.5rem)]"
              />

              <Word.rail
                page={@page}
                sources={@card_sources}
                choices={@choices}
                headword={false}
                class="lg:float-left lg:clear-left lg:w-[22.5rem]"
                demo={@demo}
                subjects={@subjects}
              />

              <div class="min-w-0 max-lg:mt-8 lg:float-right lg:clear-right lg:w-[calc(100%-25.5rem)]">
                <.column
                  page={@page}
                  card_sources={@card_sources}
                  object_id={@object_id}
                  slug={@slug}
                  demo={@demo}
                  evidence={@evidence}
                  urban_dictionary={@urban_dictionary}
                  cultures={@cultures}
                  culture_notes={@culture_notes}
                  browsers={@browsers}
                  contributor={@contributor}
                  base={@base}
                  mode={@reading_mode}
                  overview={@overview}
                  choice_overview={@choice_overview}
                  choice_paths={@choice_paths}
                  linked_overviews={@linked_overviews}
                  subjects={@subjects}
                />
              </div>

              <.way_out
                :if={@page.related || @page_sources != []}
                page={@page}
                page_sources={@page_sources}
                demo={@demo}
                class="mt-8 lg:float-left lg:clear-left lg:mt-5 lg:w-[22.5rem] lg:border-t lg:border-mist-950/10 lg:pt-4 dark:lg:border-white/10"
              />
            </div>

            <div
              :if={is_nil(@opening)}
              class="lg:grid lg:grid-cols-[22.5rem_minmax(0,1fr)] lg:grid-rows-[auto_1fr] lg:gap-x-12"
            >
              <Word.rail
                page={@page}
                sources={@card_sources}
                choices={@choices}
                thing_info={@page.thing && Word.info_path(@base, @page.trail, "thing", @demo)}
                class="lg:col-start-1 lg:row-start-1"
                demo={@demo}
                subjects={@subjects}
              />

              <div class="min-w-0 max-lg:mt-8 lg:col-start-2 lg:row-span-2 lg:row-start-1">
                <.column
                  page={@page}
                  card_sources={@card_sources}
                  object_id={@object_id}
                  slug={@slug}
                  demo={@demo}
                  evidence={@evidence}
                  urban_dictionary={@urban_dictionary}
                  cultures={@cultures}
                  culture_notes={@culture_notes}
                  browsers={@browsers}
                  contributor={@contributor}
                  base={@base}
                  mode={@reading_mode}
                  overview={@overview}
                  choice_overview={@choice_overview}
                  choice_paths={@choice_paths}
                  linked_overviews={@linked_overviews}
                  subjects={@subjects}
                />
              </div>

              <.way_out
                :if={@page.related || @page_sources != []}
                page={@page}
                page_sources={@page_sources}
                demo={@demo}
                class="mt-8 lg:col-start-1 lg:row-start-2 lg:mt-5 lg:border-t lg:border-mist-950/10 lg:pt-4 dark:lg:border-white/10"
              />
            </div>
        <% end %>
      </.container>
    </Layouts.app>

    <%!--
      Outside `Layouts.app` on purpose. The kit's `<main>` carries
      `overflow-clip`, which — unlike `overflow: hidden` — clips fixed-position
      descendants too, so a drawer rendered inside the container is trimmed to
      the article column and scrolled out of its own header.
    --%>
    <Provenance.provenance
      :if={@provenance}
      provenance={@provenance}
      close={Word.info_path(@base, @page.trail, nil, @demo)}
      record_path={&Word.info_path(@base, @page.trail, "#{@provenance.ref}:#{&1}", @demo)}
    />
    """
  end

  # Everything a source decides the size of, in the column beside the rail:
  # one function so both layouts in `render/1` render the same elements.
  defp column(assigns) do
    ~H"""
    <%!-- The authored overview this address holds, when it names these
         words, heads them (#219 B1); one that names other words is shown
         apart, as something else that shares the spelling. --%>
    <Subjects.overview :if={@overview} overview={@overview} />
    <Subjects.overview
      :if={@choice_overview}
      overview={@choice_overview}
      as={:choice}
      subject_paths={@choice_paths}
    />
    <Subjects.linked_overviews overviews={@linked_overviews} />

    <%!-- `phx-update="ignore"` because `open` is DOM state the reader
         owns: without it, a discovery result arriving would re-render
         these rows and snap the reader's open source shut. Nothing
         here changes after the first render *for this word in this
         mode*, which is exactly what the id says — so a different
         word, or the demo banner going up, replaces the element
         rather than patching it. The `object_id` is in the id because
         a slug is not an identity: `/on/c` and `/words/<C++>/c`
         are two words under one slug, and the id has to tell them
         apart or the ignored rows would outlive the word. `any` is
         what `/on/:slug` means — every word the slug reaches —
         and it is a segment rather than a gap so the id reads. --%>
    <.slab
      :if={@page.cards != []}
      id={"definitions-#{@object_id || "any"}-#{@slug}-#{@demo}"}
      phx-update="ignore"
      title="Definitions"
      class="mt-2"
    >
      <:meta>{count_label(@card_sources, @page.cards)} · one open at a time</:meta>
      <div class="divide-y divide-mist-950/10 dark:divide-white/10">
        <Word.source_row
          :for={{card, i} <- Enum.with_index(@page.cards)}
          card={card}
          open={i == default_open(@page.cards)}
          continues={continues?(@page.cards, i)}
          trail={trail_here(@page)}
          info={Word.info_path(@base, @page.trail, "card:" <> card.id, @demo)}
          demo={@demo}
          mode={@mode}
        />
      </div>
    </.slab>

    <Word.bare_row :if={@page.cards == []} lemma={@page.headword.lemma} />

    <%!-- The named things the sources file under this word's
         meanings (#181): asserted, so after the definitions and
         before anything searched for. Absent when nothing names
         any — a section, not a shelf, so there is no empty state
         to hold open while something loads. --%>
    <Examples.section
      :if={@page.examples}
      examples={@page.examples}
      lemma={@page.headword.lemma}
      trail={trail_here(@page)}
      demo={@demo}
      mode={@mode}
    />

    <%!-- The 📱 Crowd card (#136): after the real cards and before the
         culture shelves, which is exactly where the demo's sample sat
         from U3 until this replaced it. `nil` unless the environment
         switch and the source row both say yes, and then the hook
         removes the element on an empty answer or any failure — so
         the states are *card* and *absent*, never an empty card. The
         source line above counts server-known cards and does not know
         about this one, on purpose: it is a claim about what has been
         absorbed, and nothing here is. --%>
    <CrowdCard.urban_dictionary :if={@urban_dictionary} config={@urban_dictionary} />

    <%!-- One block for everything found rather than written, the GIFs
         among it (#111 L6 — the one piece of #109 K10 that never
         landed). The GIF shelf keeps its own hook and transport;
         what it loses is the second chrome 400 px below the first. --%>
    <Culture.section
      :if={@cultures != %{} or @browsers != [] or @culture_notes != []}
      states={@cultures}
      notes={@culture_notes}
      browsers={@browsers}
      return_path={@base || word_path(@page)}
      contributor={@contributor}
      mode={@mode}
    />

    <%!-- The subjects this page reaches (#219 B3): the overview's chosen
         ones in its order, then what the sources and names find, each at
         its address in the reading mode or at its exact identity. --%>
    <Subjects.section
      :if={@subjects}
      subjects={@subjects}
      members={(@overview && @overview.members) || []}
    />

    <Thing.thing_panel
      :if={@page.thing}
      thing={@page.thing}
      trail={trail_here(@page)}
      info={Word.info_path(@base, @page.trail, "thing", @demo)}
      demo={@demo}
      mode={@mode}
    />

    <Demo.evidence_wall :if={@demo} evidence={@evidence} />
    """
  end

  # The way out of the word: the related words, then every source on the page.
  defp way_out(assigns) do
    ~H"""
    <div class={@class}>
      <Word.related_block
        :if={@page.related}
        related={@page.related}
        trail={trail_here(@page)}
        demo={@demo}
      />
      <%!-- The one place that lists every source on the page (#152
           rule 3), under the related words because both are the way
           out of the word. It is composed from assigns the page
           already holds and grows as a shelf's live results arrive;
           a source whose shelf is still loading is not on the page
           yet, and is not in the stack yet. --%>
      <SourceBadge.stack
        id="page-sources"
        sources={@page_sources}
        class={[
          "mt-8",
          @page.related && "border-t border-mist-950/10 pt-4 dark:border-white/10"
        ]}
      />
    </div>
    """
  end

  attr :slug, :string, required: true
  attr :suggestions, :list, default: []
  attr :demo, :boolean, default: false
  attr :exact, :atom, default: nil

  defp miss(assigns) do
    ~H"""
    <div :if={@exact == :invalid} id="not-an-address" class="py-12">
      <.heading>Not an address</.heading>
      <.text class="mt-4">
        This address is not readable text, so it names no word.
      </.text>
      <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
    </div>
    <div :if={@exact != :invalid} id="no-such-word" class="py-12">
      <.heading>“{@slug}”</.heading>
      <.text :if={@exact == :missing} id="no-such-word-identity" class="mt-4">
        No word with that identity. An exact address names one word by its id, and this id names
        none — the words spelled “{@slug}” are not substituted for it.
      </.text>
      <.text :if={@exact != :missing} class="mt-4">
        No such word. Nothing in the index — not as a headword, not as a spelling, not as an
        inflected form of anything else.
      </.text>
      <Word.did_you_mean suggestions={@suggestions} demo={@demo} />
      <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
    </div>
    """
  end

  # A chip leaves this word, so the trail it writes is the one that arrived
  # plus this word. Capping here as well as in the parser keeps a long walk
  # from growing a long URL.
  defp trail_here(%{trail: trail, headword: %{lemma: nil}}), do: trail

  defp trail_here(%{trail: trail, headword: headword}) do
    (trail ++ [%{slug: headword.slug, lemma: headword.lemma}])
    |> Enum.uniq_by(& &1.slug)
    |> Enum.take(-@trail_cap)
  end
end
