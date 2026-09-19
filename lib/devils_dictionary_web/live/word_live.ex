defmodule DevilsDictionaryWeb.WordLive do
  @moduledoc """
  `/define/:slug` — a page for every word in the index (#71 §8a).

  The whole page is one round of queries in `handle_params/3`, well under the
  150 ms #71 §7 budgets and nowhere near the 2.5 s long-poll fallback the S4
  audit drew the line at: `mount/3` runs three times over a page's life (dead
  render, connected mount, and again on every reconnect), so anything slow
  there is slow three times and can abandon its own websocket.

  For the same reason the page is rebuilt only when the word or the walk
  changes. Opening the ⓘ drawer is a patch to the same word, so it re-runs
  `handle_params/3`; without the guard every ⓘ click would re-run ten queries
  to render the page it is already on.

  Nothing here raises. `/define/zzzz` is a page that says *no such word* and
  offers the nearest words the trigram can find; a bare index row is a page with
  a headword and a promise. X1 renders 200 random index lexemes and most of the
  index is bare.

  ## Two ways in, and only one of them is identity

  ADR decision 10. `/words/:id/:slug` is **canonical**: the id is the word's
  `object_id`, and the slug is a readable tail nothing reads back. `/define/:slug`
  is a **resolver**, kept because a slug is what a reader types and what an old
  link holds — but a slug is lossy. 28,306 slug groups hold more than one
  distinct lemma, which is how searching for `C++` came to land on `/define/c`
  headed `-c-`. So when a slug resolves to several distinct lemmas this page
  offers the choice instead of silently picking one, and every word it lists
  links to its canonical address.
  """

  use DevilsDictionaryWeb, :live_view

  # Read-only: it tells the page whether the reader may carry an artwork
  # candidate into the review composer. It grants nothing; `/connect` is still
  # gated on the server by `:require_internal_contributor`.
  on_mount {DevilsDictionaryWeb.UserAuth, :mount_current_scope}

  alias DevilsDictionary.Demo, as: Samples
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.ContentTypes
  alias DevilsDictionary.Discovery.Providers
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionaryWeb.{Culture, Demo, Provenance, Thing, Word}

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
       cultures: %{}
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

    case Lexicon.by_object_id(id) do
      nil ->
        handle_params(resolver, uri, assign(socket, :object_id, nil))

      lexeme ->
        if slug == lexeme.slug do
          handle_params(resolver, uri, assign(socket, :object_id, lexeme.object_id))
        else
          {:noreply, push_navigate(socket, to: ~p"/words/#{id}/#{lexeme.slug}")}
        end
    end
  end

  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    trail = parse_trail(params["trail"])
    demo = Samples.on?(params)

    socket =
      if slug == socket.assigns.slug and trail == socket.assigns.trail and
           demo == socket.assigns.demo do
        socket
      else
        load(socket, slug, trail, demo)
      end

    {:noreply, assign(socket, :provenance, provenance(socket.assigns.page, params["provenance"]))}
  end

  # A sample card's drawer is invented too. Falling through to
  # `WordPage.provenance/2` would put the word's real concept links under a
  # card that does not exist, which is the one dishonest thing the mode could
  # do.
  defp provenance(page, ref) do
    Samples.provenance(page, ref || "") || WordPage.provenance(page, ref)
  end

  defp load(socket, slug, trail, demo) do
    page = socket.assigns.object_id |> lookup(slug) |> WordPage.build(trail: trail)

    samples =
      if demo, do: Samples.samples(page.headword.lemma || slug), else: %{cards: [], evidence: []}

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
      |> assign(:page_title, title(page, slug))
      |> assign(:card_sources, card_sources)
      |> assign(:suggestions, suggestions(page, slug))
      |> assign(:choices, choices(slug, socket.assigns.object_id))

    prepare_discovery(socket, page, demo)
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

    socket
    |> assign(:discovery_target, target)
    |> assign(:cultures, Map.merge(cultures, catalog_shelf(page, target)))
    |> assign(:giphy, DevilsDictionary.Discovery.Providers.Giphy.browser_config(target))
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
            content_types: [:artwork],
            mapping_id: nil,
            term: page.headword.lemma,
            relevance: if(length(page.headword.lexemes) > 1, do: "term_unverified", else: "term")
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

        {:noreply, update(socket, :cultures, &Map.put(&1, provider_slug, state))}

      is_nil(current.mapping_id) ->
        {:noreply, update(socket, :cultures, &Map.delete(&1, provider_slug))}

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

      update(socket, :cultures, &Map.put(&1, provider_slug, state))
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
        if lexemes |> Enum.map(& &1.lemma) |> Enum.uniq() |> length() > 1,
          do: Enum.uniq_by(lexemes, & &1.lemma),
          else: []

      _ ->
        []
    end
  end

  # The canonical address names one word, so it renders that word — not
  # whatever else shares its slug. `/words/<C++>/c` is a page about `C++`;
  # `/define/c` is a page about everything the slug reaches. That difference is
  # the whole reason there are two routes.
  defp lookup(nil, slug), do: Lexicon.lookup(slug)

  defp lookup(object_id, slug) do
    case Lexicon.by_object_id(object_id) do
      nil -> Lexicon.lookup(slug)
      lexeme -> %{lexemes: [lexeme], via: :lemma, matched: lexeme.lemma}
    end
  end

  # Only a miss pays for suggestions: on every other page the trigram would be
  # answering a question nobody asked.
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

  defp title(%{headword: %{lemma: nil}}, slug), do: "#{slug} — no such word"
  defp title(%{headword: %{lemma: lemma}}, _slug), do: lemma

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

        <%= if @page.headword.lexemes == [] do %>
          <.miss slug={@slug} suggestions={@suggestions} demo={@demo} />
        <% else %>
          <.disambiguation :if={@choices != []} slug={@slug} choices={@choices} />

          <Word.headword headword={@page.headword} demo={@demo} />

          <Word.source_line sources={@card_sources} />

          <div :if={@page.cards != []} class="mt-8 space-y-6">
            <Word.source_card
              :for={card <- @page.cards}
              card={card}
              trail={trail_here(@page)}
              info={Word.info_path(@slug, @page.trail, "card:" <> card.id, @demo)}
              demo={@demo}
            />
          </div>

          <Word.bare_row :if={@page.cards == []} lemma={@page.headword.lemma} />

          <Culture.section
            :if={@cultures != %{}}
            states={@cultures}
            return_path={word_path(@page)}
            contributor={@contributor}
          />

          <DevilsDictionaryWeb.GiphyShelf.section :if={@giphy} config={@giphy} />

          <Word.related_block
            :for={related <- @page.related}
            related={related}
            trail={trail_here(@page)}
            demo={@demo}
          />

          <Thing.thing_panel
            :if={@page.thing}
            thing={@page.thing}
            trail={trail_here(@page)}
            info={Word.info_path(@slug, @page.trail, "thing", @demo)}
            demo={@demo}
          />

          <Demo.evidence_wall :if={@demo} evidence={@evidence} />
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
      close={Word.info_path(@slug, @page.trail, nil, @demo)}
      record_path={&Word.info_path(@slug, @page.trail, "#{@provenance.ref}:#{&1}", @demo)}
    />
    """
  end

  attr :slug, :string, required: true
  attr :choices, :list, required: true

  # A slug is a label, not an identity. When one names more than one distinct
  # lemma the page says so and offers the canonical address of each, rather than
  # picking the first and heading the page with the wrong word — which is what
  # `/define/c` did to `C++`.
  defp disambiguation(assigns) do
    ~H"""
    <aside
      id="disambiguation"
      class="mb-8 rounded-lg border border-mist-950/10 p-4 text-sm/7 dark:border-white/10"
    >
      <p class="text-mist-500">
        “{@slug}” is the slug of more than one word. This page shows them together; each
        has an address of its own.
      </p>
      <ul class="mt-2 space-y-1">
        <li :for={lexeme <- @choices} id={"disambiguation-#{lexeme.object_id}"}>
          <.a navigate={~p"/words/#{lexeme.object_id}/#{@slug}"}>{lexeme.lemma}</.a>
          <span class="text-mist-500">· {lexeme.part_of_speech}</span>
        </li>
      </ul>
    </aside>
    """
  end

  attr :slug, :string, required: true
  attr :suggestions, :list, default: []
  attr :demo, :boolean, default: false

  defp miss(assigns) do
    ~H"""
    <div id="no-such-word" class="py-12">
      <.heading>“{@slug}”</.heading>
      <.text class="mt-4">
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
