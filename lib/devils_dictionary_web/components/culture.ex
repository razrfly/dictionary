defmodule DevilsDictionaryWeb.Culture do
  @moduledoc """
  The one reader surface for automatic cultural discovery.

  K2 of #109: every result renders here, live or from a corpus, and a shelf is
  keyed by **content type** rather than by provider. A page had three chromes
  for one content type before this — the Met's compact shelf, the tall
  `#artwork-candidates` cards and `/artworks` — and `/define/soldier` showed two
  of them at once. Now the Met's live results and the committed catalog's
  candidates share one *Artworks* shelf, live results first, each item carrying
  the reason it is there.

  A provider ships zero components. What a content type looks like is a row in
  `DevilsDictionary.Discovery.ContentTypes`; why an item matched is a
  `DevilsDictionary.Discovery.MatchReason`; nothing here knows which providers
  exist.

  A shelf with several sources on it is one rail, not one rail per source
  (#116): the order across sources and the duplicates between them are
  `DevilsDictionary.Discovery.Shelf`'s two rules, applied here at read time
  and never to a provider's persisted results. What a card owes its maker,
  and which reasons a shelf may show at all, are two more columns of the
  content-type table, read here rather than remembered.
  """
  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Discovery.ContentTypes
  alias DevilsDictionary.Discovery.MatchReason
  alias DevilsDictionary.Discovery.Shelf

  attr :states, :map, required: true
  attr :return_path, :string, default: nil

  attr :giphy, :map,
    default: nil,
    doc: "the browser-side GIF shelf's config, or nil when there is no key or no target"

  attr :tab, :string,
    default: nil,
    doc: "the shelf the reader chose, or nil for the page's own default"

  attr :contributor, :boolean,
    default: false,
    doc: "whether the reader may carry a corpus candidate into the review composer"

  def section(assigns) do
    states = assigns.states |> Map.values() |> Enum.sort_by(&{archetype_rank(&1), &1.provider})
    shelves = shelves(states)
    tabs = tabs(shelves, assigns.giphy)

    assigns =
      assigns
      |> assign(:shelves, shelves)
      |> assign(:provider_count, length(states))
      |> assign(:tabs, tabs)
      |> assign(:selected, selected(tabs, assigns.tab))

    ~H"""
    <.compact_section
      :if={@tabs != []}
      shelves={@shelves}
      tabs={@tabs}
      selected={@selected}
      giphy={@giphy}
      provider_count={@provider_count}
      return_path={@return_path}
      contributor={@contributor}
    />
    """
  end

  # One chip per shelf, in shelf order, and one for the GIFs when the page has
  # a key for them. A shelf keeps its chip whether or not it has anything on
  # it: its status line — still looking, nothing found, unavailable — is the
  # page being honest about a source it asked, and a chip is how the reader
  # reaches it. The count is on the chip because that is the one thing a
  # reader wants to know before choosing (#131: never *Show more*).
  defp tabs(shelves, giphy) do
    for shelf <- shelves do
      %{
        key: Atom.to_string(shelf.type),
        label: shelf_heading(shelf.type),
        count: if(shelf.entries == [], do: nil, else: length(shelf.entries))
      }
    end ++ if(giphy, do: [%{key: "gif", label: "GIFs", count: nil}], else: [])
  end

  @doc "Every key `handle_event(\"culture_tab\", ...)` may accept: the content types, and the GIFs."
  def tab_keys, do: Enum.map(ContentTypes.known(), &Atom.to_string/1) ++ ["gif"]

  # The reader's choice if it names a chip on this page; otherwise the first
  # shelf that actually has something, so the block opens on a picture rather
  # than on *still looking*; otherwise whatever comes first.
  defp selected(tabs, choice) do
    keys = Enum.map(tabs, & &1.key)

    cond do
      choice in keys -> choice
      true -> Enum.find_value(tabs, List.first(keys), &(&1.count && &1.key))
    end
  end

  # One shelf per content type, in the table's order: film · artwork · image ·
  # text · gif. A provider that declares a type nobody can present is not a
  # shelf.
  #
  # The entries are every contributing state's items, composed by the shelf's
  # two rules (#116 M2, M3): live before corpus, then one item from each
  # source in turn — sources by tier and then slug — with one item per
  # identity and one per media URL, the better-tiered source's copy kept.
  # Before this the rail was one provider's items and then the next's, which
  # is the sectioned grid a many-source shelf exists to avoid.
  defp shelves(states) do
    for type <- ContentTypes.known(),
        group = Enum.filter(states, &(content_type(&1) == type)),
        group != [] do
      entries =
        group
        |> Enum.flat_map(fn state -> Enum.map(state.items, &%{state: state, item: &1}) end)
        |> Shelf.compose(&archetype_rank(&1.state), &source/1, &Shelf.keys(&1.item))

      # D1 of #126. A shelf nothing identified and nothing attested is a
      # search's ranking and says so on every card; it still shows — M6's
      # honesty is the whole point of the label — but it is not allowed to
      # take a page per source. Measured on `/define/nepotism` 2026-09-19:
      # three keyword sources declining nothing made thirty-six stock
      # photographs, which is a results page. One page across the searches
      # in turn instead, with *Load more* to go on.
      #
      # Read from the entries' own reasons rather than from the row: the
      # `:image` row admits both classes, and whether *this* page got an
      # identity out of it is a fact about what arrived. An empty shelf is
      # not demoted — there is nothing to demote, and a shelf still loading
      # would otherwise jump down the page and back.
      searched? = entries != [] and not Enum.any?(entries, &attested?/1)
      # What the cap leaves out is a number the page knows, so it is shown
      # (IMDb's shape: the size in the heading, the remainder in a last tile)
      # rather than left for the reader to discover by pressing *Load more*.
      overflow = if searched?, do: max(length(entries) - page_cap(group), 0), else: 0
      entries = if searched?, do: Enum.take(entries, page_cap(group)), else: entries

      %{type: type, states: group, entries: entries, searched?: searched?, overflow: overflow}
      |> then(fn shelf ->
        # What each state actually put on the rail, after the fold: the byline
        # credits and the About note describes these, not `state.items`. A
        # state whose every item was a duplicate of a better-tiered source's
        # is not a contributor, and a note listing a card the rail folded
        # would be the page contradicting itself (CodeRabbit on #122).
        Map.put(shelf, :shown, Enum.group_by(shelf.entries, & &1.state.provider, & &1.item))
      end)
    end
    # A demoted shelf renders after every shelf that identified or attested
    # something (D1). `Enum.sort_by/2` is stable and `false < true`, so the
    # content-type table's order survives inside each of the two groups.
    |> Enum.sort_by(& &1.searched?)
  end

  # One page of a shelf that only searched: twelve items across its sources
  # in turn, and one more page for every page its sources have loaded, so
  # *Load more* still goes on. Twelve because that is the shelf's page
  # everywhere else — `Artworks`' own limit, and a rail of twelve is what
  # every other shelf on the page opens with.
  @searched_page 12

  defp page_cap(states) do
    pages = states |> Enum.map(&(Map.get(&1, :page) || 0)) |> Enum.max(fn -> 0 end)
    @searched_page * (pages + 1)
  end

  # Did anything on this rail arrive by identity or attestation? One entry is
  # enough: an Images shelf with one Commons depiction on it is not a results
  # page, and the searches that follow it are labelled either way.
  defp attested?(%{state: state, item: item}) do
    item
    |> reasons(Map.get(state, :term))
    |> Enum.any?(&(MatchReason.evidence(&1) != :query))
  end

  # A corpus candidate sorts after every live result on its shelf. It is the
  # same content type and the same identity rule, but it was not asked for on
  # this visit, and a shelf that opened with the catalog would bury the answer
  # the page actually went and got.
  defp archetype_rank(state), do: if(Map.get(state, :archetype) == :corpus, do: 1, else: 0)

  # Where an entry's source sorts on its shelf: tier, then slug. A live state
  # is one provider and carries its tier; the catalog state carries several
  # corpora, and each of its items names its own source, so the corpus group
  # takes turns between the Met and Wikidata rather than treating "the
  # catalog" as one source. `Map.get/2`, not access: a persisted item is a
  # `Result` struct.
  defp source(%{state: state, item: item}) do
    {Shelf.tier_rank(Map.get(item, :source_tier) || Map.get(state, :tier)),
     Map.get(item, :source_slug) || state.provider}
  end

  attr :shelves, :list, required: true
  attr :tabs, :list, required: true
  attr :selected, :string, required: true
  attr :giphy, :map, default: nil
  attr :provider_count, :integer, required: true
  attr :return_path, :string, default: nil
  attr :contributor, :boolean, default: false

  # One rail at a time, chosen by a row of counted chips, in place of every
  # shelf stacked (#131 Phase 2). Five stacked rails were 2,278 px of a phone
  # page and the single biggest lever on it; measured against the same page
  # this is 578. Nothing is hidden that the chips do not name and count.
  #
  # Every panel stays in the DOM and the unchosen ones carry `hidden`, rather
  # than rendering only the chosen one: the GIF shelf is a hook that spends a
  # request against a shared hourly key every time it mounts, and a shelf that
  # unmounted on every chip would spend that key on the reader's browsing.
  # The chips are `phx-click` because the choice is server state, like every
  # other control on this page, and a radio's `checked` would be reset by the
  # next discovery result to arrive.
  defp compact_section(assigns) do
    assigns =
      assigns
      |> assign(:shelf_count, length(assigns.shelves))
      |> assign(:total, assigns.tabs |> Enum.map(&(&1.count || 0)) |> Enum.sum())

    ~H"""
    <.slab id="in-culture" aria-label="Related discoveries" title="Out in the world">
      <:meta>
        <span :if={@total > 0}>{@total} things · </span>every match says why it is here
      </:meta>

      <div
        role="tablist"
        aria-label="Kinds of thing"
        class="-mx-5 flex gap-2 overflow-x-auto px-5 py-3 whitespace-nowrap"
      >
        <button
          :for={tab <- @tabs}
          type="button"
          role="tab"
          id={"culture-tab-#{tab.key}"}
          aria-selected={to_string(tab.key == @selected)}
          aria-controls={"culture-panel-#{tab.key}"}
          phx-click="culture_tab"
          phx-value-type={tab.key}
          class={[
            "cursor-pointer rounded-full px-3 py-1 text-base/7 sm:text-sm/7",
            tab.key == @selected &&
              "bg-mist-950 text-white dark:bg-mist-300 dark:text-mist-950",
            tab.key != @selected &&
              "bg-mist-950/5 text-mist-700 hover:bg-mist-950/10 dark:bg-white/10 dark:text-mist-400 dark:hover:bg-white/15"
          ]}
        >
          {tab.label}
          <span :if={tab.count} class="tabular-nums opacity-70">{tab.count}</span>
        </button>
      </div>

      <div
        :for={shelf <- @shelves}
        id={"culture-panel-#{shelf.type}"}
        role="tabpanel"
        aria-labelledby={"culture-tab-#{shelf.type}"}
        hidden={Atom.to_string(shelf.type) != @selected}
        class="pb-4"
      >
        <div id={"culture-shelf-#{shelf.type}"} class="space-y-3">
          <%= if shelf.entries != [] do %>
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h3
                id={"culture-filter-#{shelf.type}"}
                class="font-display text-xl text-balance text-mist-950 dark:text-white"
              >
                {shelf_heading(shelf.type)}
              </h3>
              <%!-- D4 of #126: the byline is names. Each provider's own
                   qualifier — *depicts: Wikidata*, *search: CC and public
                   domain* — is a sentence about how that source matched, which
                   is what the About section is for; four of them in the header
                   wrapped to four lines above the rail at 375 px, measured on
                   `/define/war` 2026-09-19. --%>
              <p class="text-base text-mist-500 sm:text-sm">
                <span :for={{state, index} <- Enum.with_index(contributing(shelf))}>
                  <span :if={index > 0} aria-hidden="true">·</span>
                  <span id={"culture-provider-#{state.provider}"}>{state.provider_name}</span>
                </span>
              </p>
            </div>
            <%!-- No scroll snapping on this rail, deliberately. A shelf's corpus
                 items paint on the first, synchronous render and its live results
                 are prepended when they arrive; CSS scroll snap re-snaps a
                 container to its previously snapped box after a layout change, so
                 the rail opened 1,584 px in — past every result the page had just
                 gone and fetched. Measured on `/define/soldier`. --%>
            <ul
              role="list"
              tabindex="0"
              aria-label={"#{shelf_heading(shelf.type)} matches; scroll for more"}
              id={shelf_id("culture-results", shelf, @shelf_count)}
              class="flex gap-5 overflow-x-auto overscroll-x-contain pb-3 focus-visible:outline-2 focus-visible:outline-offset-2"
            >
              <li
                :for={entry <- shelf.entries}
                id={"culture-result-#{entry.item.external_namespace}-#{entry.item.external_id}"}
                class={["shrink-0", ContentTypes.column(shelf.type)]}
              >
                <.culture_thumbnail
                  item={entry.item}
                  type={shelf.type}
                  return_path={@return_path}
                />
              </li>
              <%!-- The remainder the page cap dropped, as the rail's last tile.
                   It does what *Load more* does, from where the reader's eye
                   already is. --%>
              <li
                :if={shelf.overflow > 0 and advancing(shelf) != ""}
                id={"culture-overflow-#{shelf.type}"}
                class={["shrink-0", ContentTypes.column(shelf.type)]}
              >
                <button
                  type="button"
                  phx-click="discovery_more"
                  phx-value-providers={advancing(shelf)}
                  class="flex aspect-square w-full cursor-pointer items-center justify-center rounded-sm bg-mist-950/5 text-base font-medium tabular-nums text-mist-700 hover:bg-mist-950/10 sm:text-sm dark:bg-white/10 dark:text-mist-300 dark:hover:bg-white/15"
                >
                  +{shelf.overflow}
                </button>
              </li>
            </ul>
            <%!-- A shelf can be one provider's answer and another's silence. The
                 items are not a reason to stop saying that the other is still
                 looking, or has failed — but they are a reason to name the
                 provider rather than the content type, which is not empty. --%>
            <p
              :for={state <- pending(shelf)}
              id={status_id(status_base(state.status), state, @provider_count)}
              role="status"
              class="text-base text-mist-500 sm:text-sm"
            >
              <%= case state.status do %>
                <% :failed -> %>
                  {state.provider_name} is temporarily unavailable.
                <% status when status in [:deferred, :expired, :withdrawn] -> %>
                  {state.provider_name} will retry when available.
                <% _ -> %>
                  Still looking at {state.provider_name}…
              <% end %>
            </p>
            <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
              <.compact_note shelf={shelf} contributor={@contributor} />
              <.compact_more shelf={shelf} />
            </div>
          <% else %>
            <h3 class="font-display text-xl text-mist-950 dark:text-white">
              In {shelf_label(shelf.type)}
            </h3>
            <p
              :for={state <- shelf.states}
              id={status_id(status_base(state.status), state, @provider_count)}
              role="status"
              class="text-base text-mist-500 sm:text-sm"
            >
              <%= case state.status do %>
                <% :empty -> %>
                  No matching {shelf_label(shelf.type)} for this term yet.
                <% :failed -> %>
                  {shelf_heading(shelf.type)} discovery is temporarily unavailable.
                <% status when status in [:deferred, :expired, :withdrawn] -> %>
                  {shelf_heading(shelf.type)} discovery will retry when available.
                <% _ -> %>
                  Looking for matching {shelf_label(shelf.type)}…
              <% end %>
            </p>
          <% end %>
        </div>
      </div>

      <div
        :if={@giphy}
        id="culture-panel-gif"
        role="tabpanel"
        aria-labelledby="culture-tab-gif"
        hidden={@selected != "gif"}
        class="pb-4"
      >
        <DevilsDictionaryWeb.GiphyShelf.section config={@giphy} />
      </div>
    </.slab>
    """
  end

  # The providers a shelf's *Load more* advances, as the event's value. Every
  # source with a cursor, not only the ones on the rail (D3 of #126).
  defp advancing(shelf) do
    shelf.states |> Enum.filter(& &1[:next_cursor]) |> Enum.map_join(",", & &1.provider)
  end

  # A shelf credits the providers that actually put something on it — on the
  # rail, after the fold. A provider whose own request failed while another's
  # succeeded is reported in its note, not in a byline for results it did not
  # supply; one whose every item the shelf folded into another source's copy
  # is in the same position.
  # Tier, then slug (D3): the order the rail itself takes its turns in, so the
  # byline and the About sections read down in the order the cards read
  # across. The catalog state names no tier of its own — its items each carry
  # their corpus's — and an unnamed tier sorts after every named one, which
  # is where a corpus belongs anyway.
  defp contributing(shelf) do
    shelf.states
    |> Enum.filter(&Map.has_key?(shelf.shown, &1.provider))
    |> Enum.sort_by(&{Shelf.tier_rank(Map.get(&1, :tier)), &1.provider})
  end

  # Worth reporting beside a shelf that is not empty. A provider whose own
  # answer was *nothing* is not: "no matching artwork for this term" under six
  # artworks would be the page contradicting itself.
  defp pending(shelf),
    do: Enum.filter(shelf.states, &(&1.items == [] and &1.status != :empty))

  attr :item, :map, required: true
  attr :type, :atom, required: true
  attr :return_path, :string, default: nil

  defp culture_thumbnail(assigns) do
    presentation = ContentTypes.get(assigns.type)
    metadata = assigns.item.preview_metadata
    attribution = attribution_line(presentation.attribution, metadata)

    assigns =
      assigns
      |> assign(:image, ContentTypes.thumbnail_url(assigns.type, metadata))
      |> assign(:entry_path, entry_path(assigns.item, assigns.return_path))
      |> assign(:aspect, presentation.aspect)
      |> assign(:badge, presentation.badge)
      |> assign(:year, year(metadata))
      |> assign(:attribution, attribution)
      |> assign(:credit, credit_parts(attribution, metadata))
      # Every href on this card comes out of a provider response. Phoenix
      # escapes the attribute but applies no scheme allowlist, so a
      # `javascript:` URL in an upstream record would run in this origin on a
      # click (CodeRabbit on #125). Only an absolute http(s) URL is a link.
      |> assign(:source_url, external_href(metadata["source_url"]))
      # A credit a licence *requires* is not clamped. At the `:image` row's
      # 112 px column a two-line clamp cut every one of the forty-two credits
      # on `/define/war` — including, on all twelve Unsplash cards, the word
      # *Unsplash* and the link D3 puts on it. "Beneath the thumbnail, always
      # visible" (M4, promise 4) is not satisfied by a sentence whose second
      # half is display:none. On a `:credited` row the line is a nicety
      # rather than a condition, and it keeps the clamp.
      |> assign(
        :credit_clamp,
        if(presentation.attribution == :required, do: nil, else: "line-clamp-2")
      )
      # A required credit names the creator by construction, so on a shelf
      # that requires one the credit *is* the creator line; anywhere else the
      # two are different facts and both are shown.
      |> assign(
        :artist,
        if(presentation.attribution == :required and attribution,
          do: nil,
          else: metadata["artist"]
        )
      )

    ~H"""
    <div class="group flex min-w-0 flex-col gap-2 rounded-sm">
      <.link
        :if={@entry_path && @aspect}
        navigate={@entry_path}
        id={"culture-entry-image-#{@item.external_id}"}
        aria-label={"Open #{@item.preview_metadata["title"]} in Dictionary"}
        class="rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <.culture_image item={@item} image={@image} type={@type} />
      </.link>
      <a
        :if={is_nil(@entry_path) && @aspect && @source_url}
        href={@source_url}
        target="_blank"
        rel="noreferrer"
        aria-label={"Open source for #{@item.preview_metadata["title"]}"}
        class="rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <.culture_image item={@item} image={@image} type={@type} />
      </a>
      <div class="min-w-0 space-y-1">
        <h3 class={[
          "text-base font-medium text-balance text-mist-950 sm:text-sm dark:text-white",
          ContentTypes.title_clamp(@type)
        ]}>
          <.link
            :if={@entry_path}
            navigate={@entry_path}
            id={"culture-entry-title-#{@item.external_id}"}
            class="rounded-sm group-hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            {@item.preview_metadata["title"]}
          </.link>
          <a
            :if={is_nil(@entry_path)}
            href={@source_url}
            target="_blank"
            rel="noreferrer"
            class="rounded-sm group-hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            {@item.preview_metadata["title"]}
          </a>
        </h3>
        <%!-- D5 of #126: a card shows a year only when it has one. A stock
             photograph publishes no date, so *Year unknown* was printed on
             every Pexels card and on most Unsplash and Openverse ones —
             noise in the position a fact would hold. The badge stands alone
             when there is no year, and the line is not rendered at all when
             the row has no badge either. --%>
        <p :if={@year || @badge} class="text-base tabular-nums text-mist-500 sm:text-sm">
          <span :if={@year}>{@year}</span>
          <span :if={@year && @badge} aria-hidden="true">·</span>
          <span :if={@badge}>{@badge}</span>
        </p>
        <%!-- Whoever made it, when the provider or the catalog named them. It
             is a metadata key and not a content type's business: a film's
             director and an artwork's painter arrive under the same one. --%>
        <p :if={@artist} class="line-clamp-2 text-sm text-mist-500 text-pretty">
          {@artist}
        </p>
        <%!-- The credit, beneath the thumbnail and always visible (#116 M4),
             and linked where the item named a URL (#116 Phase 3, D3). A
             required credit hidden behind a hover is the sister project's
             mistake; a CC licence's one condition is that this line be seen.
             `phx-no-format`, because the runs of a sentence are inline and
             adjacent: a newline the formatter put between a link and the
             text after it would render as a space before a full stop.
             `break-words`, because a credit carries names no soft break
             fits — and, before D2 of #126, URLs: Openverse forwarded
             *…To view a copy of this license, visit
             https://creativecommons.org/licenses/by-sa/2.0/.* and that
             unbreakable token ran straight out of the 112 px column and
             over the next card.

             `text-xs`, and that is the card's whole type scale doing its
             job: the title is `text-base sm:text-sm`, the year and badge
             the same, the artist `text-sm`, and the credit — the one line
             here that is an obligation rather than reading matter — a step
             below them. Measured on the 131 real image credits this
             database holds for `war` and `soldier` (Commons, Openverse,
             Pexels, Unsplash), rendered through this component at the
             `:image` row's own column:

               at 375 (96 px column): text-sm → median 4 rows, longest 10,
                 85 of 131 over three rows;  text-xs → median 3, longest 8,
                 59 over three
               at 1280 (112 px): text-sm → 59 over three;  text-xs → 42

             Three rows for *every* credit is not reachable here and the
             number says why: at this size a credit has to be about 46
             characters to fit three rows in 96 px, and `{author}, {licence},
             via Wikimedia Commons` spends 23 of them on its tail before it
             names anybody. Reaching it would take either a clamp — which
             the `:required` rule forbids, for the reason two comments up —
             or a wider column, which is D6 and wants a crop measurement
             this session does not have. Recorded in #126 rather than
             solved by making the licence smaller still. --%>
        <p
          :if={@attribution}
          id={"culture-attribution-#{@item.external_namespace}-#{@item.external_id}"}
          class={["text-xs break-words text-mist-500 text-pretty", @credit_clamp]}
          phx-no-format
        >
          <%= for part <- @credit do %><a :if={part.url} href={part.url} target="_blank" rel="noreferrer" class="underline underline-offset-4 transition-colors hover:text-mist-950 dark:hover:text-white">{part.text}</a><span :if={is_nil(part.url)}>{part.text}</span><% end %>
        </p>
        <a
          :if={@source_url}
          href={@source_url}
          target="_blank"
          rel="noreferrer"
          id={"culture-source-#{@item.external_id}"}
          class="inline-flex rounded-sm text-sm text-mist-500 underline-offset-4 transition-colors hover:text-mist-950 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 dark:hover:text-white"
        >
          Source ↗
        </a>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :image, :string, default: nil
  attr :type, :atom, required: true

  defp culture_image(assigns) do
    presentation = ContentTypes.get(assigns.type)

    assigns =
      assigns
      |> assign(:aspect, presentation.aspect)
      |> assign(:icon, presentation.icon)

    ~H"""
    <div class={[
      "w-full shrink-0 overflow-hidden rounded-sm bg-mist-950/5 transition-transform duration-200 group-hover:-translate-y-0.5 dark:bg-white/5",
      @aspect
    ]}>
      <img
        :if={@image}
        src={@image}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="size-full object-cover"
      />
      <div
        :if={!@image}
        id={"culture-missing-poster-#{@item.external_id}"}
        class="flex size-full items-center justify-center text-mist-400"
      >
        <.icon name={@icon} class="size-5" />
      </div>
    </div>
    """
  end

  @doc """
  The credit line broken into the runs the card renders, links first (D3).

  Unsplash's terms require the photographer's name and *Unsplash* to be
  links; #116 Phase 3 made a linked credit the rule for every provider on a
  shelf rather than one provider's special case. The line itself is still the
  provider's, shown verbatim (M4) — this only finds the two things the item
  named a URL for inside it, `creator` and `license`, and turns those runs
  into links. An item that carries no URL renders the same sentence as plain
  text, which is what Commons's public-domain files do.

  The needle is matched case-insensitively with hyphens and spaces treated
  alike, because a provider spells its licence one way in a field and another
  way in prose: Openverse writes `CC-BY-SA-2.0` in `license` and *CC BY-SA
  2.0* in the line it composed, and they are the same licence. Overlapping
  runs are dropped in first-position order, so a creator whose name contains
  the licence text cannot produce a link inside a link.

  Returns a list of `%{text: binary, url: binary | nil}`, in order, whose
  texts concatenate back to the line exactly.
  """
  def credit_parts(line, metadata)

  def credit_parts(nil, _metadata), do: []

  def credit_parts(line, metadata) when is_binary(line) and is_map(metadata) do
    [
      {presence(metadata["creator"]), external_href(metadata["creator_url"])},
      {presence(metadata["license"]), external_href(metadata["license_url"])}
    ]
    |> Enum.reduce([], fn
      {needle, url}, kept when is_binary(needle) and is_binary(url) ->
        # The first occurrence that does not overlap a run already kept —
        # the creator's, since it comes first — so a licence named inside the
        # creator's name is still linked where it appears on its own later
        # in the line (CodeRabbit on #125).
        case Enum.find(occurrences(line, needle), &(not overlaps?(&1, kept))) do
          nil -> kept
          {start, length} -> [%{start: start, length: length, url: url} | kept]
        end

      _pair, kept ->
        kept
    end)
    |> Enum.sort_by(& &1.start)
    |> runs(line)
  end

  def credit_parts(line, _metadata) when is_binary(line), do: [%{text: line, url: nil}]

  # Every place `needle` sits in `line`, as `{start, length}` in bytes, in
  # order. Hyphens and spaces in the needle match any run of either, which is
  # what makes `CC-BY-SA-2.0` find *CC BY-SA 2.0*.
  defp occurrences(line, needle) do
    pattern =
      needle
      |> String.split(~r/[-\s]+/u, trim: true)
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("[-\\s]+")

    with false <- pattern == "",
         {:ok, regex} <- Regex.compile(pattern, "iu") do
      regex |> Regex.scan(line, return: :index) |> Enum.map(&hd/1)
    else
      _ -> []
    end
  end

  defp overlaps?({start, length}, kept) do
    Enum.any?(kept, fn %{start: s, length: l} -> start < s + l and s < start + length end)
  end

  # An absolute `http(s)` URL with a host, or nil: the one shape a card may
  # put in an `href`. Provider data is never trusted with a scheme.
  defp external_href(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.trim(url)

      _uri ->
        nil
    end
  end

  defp external_href(_url), do: nil

  defp runs(anchors, line) do
    {parts, cursor} =
      Enum.reduce(anchors, {[], 0}, fn %{start: start, length: length, url: url},
                                       {parts, cursor} ->
        parts = prepend(parts, binary_part(line, cursor, start - cursor), nil)
        {prepend(parts, binary_part(line, start, length), url), start + length}
      end)

    parts
    |> prepend(binary_part(line, cursor, byte_size(line) - cursor), nil)
    |> Enum.reverse()
  end

  defp prepend(parts, "", _url), do: parts
  defp prepend(parts, text, url), do: [%{text: text, url: url} | parts]

  # What the card shows for the item's maker, by the row's `attribution`:
  # nothing on a `:none` row, and otherwise the ready-made `attribution` line
  # when the provider wrote one, the `credit_line` when it did not.
  defp attribution_line(:none, _metadata), do: nil

  defp attribution_line(_mode, metadata) when is_map(metadata),
    do: presence(metadata["attribution"]) || presence(metadata["credit_line"])

  defp attribution_line(_mode, _metadata), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # The year a card prints, or nothing. A manifest records it as a string and a
  # provider may hand back a number; neither an empty string nor an absent key
  # is a year, and D5 says an absent year is printed as nothing at all.
  defp year(metadata) when is_map(metadata) do
    case metadata["year"] do
      value when is_binary(value) -> presence(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp year(_metadata), do: nil

  defp entry_path(%{object_id: object_id, preview_metadata: metadata}, return_path)
       when is_integer(object_id) do
    slug = DevilsDictionary.Claims.Connection.slugify(metadata["title"])
    query = if return_path, do: %{from: return_path}, else: %{}
    ~p"/entities/#{object_id}/#{slug}?#{query}"
  end

  defp entry_path(_item, _return_path), do: nil

  attr :shelf, :map, required: true
  attr :contributor, :boolean, default: false

  # D3 of #126: one About per shelf. Four contributing sources meant four
  # disclosures and four *Load more* controls under one rail of images; the
  # shelf is one thing, so its note is one thing, with a section per source
  # inside it in the rail's own order.
  defp compact_note(assigns) do
    contributors = contributing(assigns.shelf)

    assigns =
      assigns
      |> assign(:contributors, contributors)
      |> assign(:term, contributors |> Enum.find_value(& &1[:term]))
      |> assign(:admits, ContentTypes.evidence(assigns.shelf.type))

    ~H"""
    <details :if={@contributors != []} id={"culture-about-#{@shelf.type}"} class="min-w-0">
      <%!-- `dark:hover:text-mist-200`: the light-mode hover darkens toward the
           ink, and without a dark counterpart hovering in dark mode moved the
           summary *towards* its background. The same shape as the credit
           links' `dark:hover:text-white` two components down. --%>
      <summary class="w-fit cursor-pointer text-base text-mist-500 hover:text-mist-700 focus-visible:outline-2 focus-visible:outline-offset-2 sm:text-sm dark:text-mist-400 dark:hover:text-mist-200">
        Matches for “{@term}” · About these results
      </summary>
      <div class="space-y-3 pt-2">
        <section
          :for={state <- @contributors}
          id={"culture-about-#{@shelf.type}-#{state.provider}"}
          class="space-y-2 text-base text-mist-600 sm:text-sm dark:text-mist-300"
        >
          <%!-- The source's name and its own qualifier, which D4 moved off the
               byline and onto the section that explains what the qualifier
               means. --%>
          <p class="font-medium text-mist-950 dark:text-white">
            {state.provider_name}{provider_detail(state)}
          </p>
          <p :if={Map.get(state, :archetype) == :corpus} class="text-pretty">
            Catalog matches from {Map.get(state, :corpora, state.provider_name)}, held locally
            rather than searched for on this visit. None is an accepted interpretation: a
            contributor connects an exact meaning and reviewers decide the claim.
            <.link navigate={~p"/artworks"} class="underline underline-offset-4">
              Browse saved artworks
            </.link>
          </p>
          <p :if={Map.get(state, :archetype) != :corpus} class="text-pretty">
            Search matches from {state.provider_name}. These are provider results, not curated examples or dictionary interpretations.
          </p>
          <%!-- Not "keyword relevance": one shelf now carries keyword matches,
               tag identities and depicted QIDs, and the caveat is about the page
               resolving to several meanings, not about how a match was made.
               Sense-level relevance is #101's. --%>
          <p :if={state.relevance == "term_unverified"} class="text-pretty">
            Relevance to this particular meaning is unverified.
          </p>
          <%!-- Each reason as one sentence, read against the shelf's own
               `evidence` row (#116 M6): a search result on the one shelf that
               admits one is called a search result; anywhere else a reason with
               nothing in it keeps the sentence that prompts someone to fix it. --%>
          <ul role="list" class="space-y-1">
            <li :for={item <- @shelf.shown[state.provider] || []}>
              {item.preview_metadata["title"]}: {MatchReason.describe_all(
                reasons(item, state.term),
                @admits
              )}{review_note(item)}
              <.link
                :if={@contributor && connect_path(item)}
                navigate={connect_path(item)}
                id={"culture-connect-#{item.external_id}"}
                class="underline underline-offset-4"
              >
                Connect to a meaning
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </details>
    """
  end

  # A corpus item arrives with its reasons already built from the manifest and
  # the encyclopedia; a persisted or transient provider result carries the
  # `match_details` its provider wrote. Both end up as the same struct.
  defp reasons(%{match_reasons: reasons}, _term) when is_list(reasons), do: reasons
  defp reasons(item, term), do: MatchReason.from_result(item.match_details, term)

  defp review_note(%{review_state: :not_yet_reviewed}), do: " · not yet reviewed"
  defp review_note(_item), do: ""

  # The composer link a contributor had on the tall candidate cards, kept when
  # they left. Only a corpus candidate has a meaning and an evidence revision to
  # preselect; `/connect` is still gated on the server.
  defp connect_path(%{object_id: object_id, sense_id: sense_id} = item)
       when is_integer(object_id) and is_integer(sense_id) do
    reason = item.match_reasons |> List.first() || %MatchReason{}

    params =
      %{
        subject: object_id,
        object: sense_id,
        predicate: "illustrates",
        evidence_revision: item[:source_record_revision_id],
        evidence_locator: reason.locator,
        rationale: reason.note
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/connect?#{params}"
  end

  defp connect_path(_item), do: nil

  attr :shelf, :map, required: true

  # D3 of #126: one *Load more* per shelf, advancing every source on it that
  # has another page. Per-source controls made the counts drift — one click on
  # Pexels put 24 of its photographs on a rail where the other three held 12
  # each, measured on `/define/war` 2026-09-19 — and the interleave's turns
  # only read as turns while the sources are level.
  #
  # Every source with a cursor, not only the ones currently on the rail: a
  # source whose whole page folded into a better-tiered copy contributes
  # nothing to the byline, and leaving it behind here would keep it off the
  # shelf for good.
  defp compact_more(assigns) do
    assigns =
      assigns
      |> assign(:providers, advancing(assigns.shelf))
      |> assign(
        :loading,
        Enum.any?(assigns.shelf.states, &(&1[:next_cursor] && &1[:loading_more] == true))
      )

    ~H"""
    <button
      :if={@providers != ""}
      id={"culture-more-#{@shelf.type}"}
      type="button"
      phx-click="discovery_more"
      phx-value-providers={@providers}
      disabled={@loading}
      class="relative rounded-sm py-1 text-base text-mist-600 underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 sm:text-sm dark:text-mist-300 dark:hover:text-white"
    ><%!-- The shelf's one control, so it is worth being able to hit. At 375 it
           is 32 px tall, under the 48 px a thumb needs; the span is the touch
           target and is not there for a mouse. --%><span
      class="pointer-fine:hidden absolute top-1/2 left-1/2 size-[max(100%,3rem)] -translate-1/2"
      aria-hidden="true"
    ></span>{if @loading, do: "Loading…", else: "Load more"}</button>
    """
  end

  # A status paragraph is one provider's, so it is keyed by provider as it
  # always was; the results list is the shelf's, so it is keyed by content type.
  # Both drop the suffix when there is only one of them on the page.
  defp status_id(base, _state, 1), do: base
  defp status_id(base, state, _count), do: "#{base}-#{state.provider}"

  defp shelf_id(base, _shelf, 1), do: base
  defp shelf_id(base, shelf, _count), do: "#{base}-#{shelf.type}"

  defp status_base(:empty), do: "culture-empty"
  defp status_base(:failed), do: "culture-failed"

  defp status_base(status) when status in [:deferred, :expired, :withdrawn],
    do: "culture-deferred"

  defp status_base(_), do: "culture-loading"

  defp content_type(%{content_types: [_ | _] = types}) do
    Enum.find(types, :film, &(&1 in ContentTypes.known()))
  end

  defp content_type(_state), do: :film

  defp shelf_heading(type), do: type |> ContentTypes.fetch!() |> Map.fetch!(:heading)
  defp shelf_label(type), do: type |> ContentTypes.fetch!() |> Map.fetch!(:label)

  defp provider_detail(%{provider_detail: detail}) when is_binary(detail) and detail != "",
    do: " · " <> detail

  defp provider_detail(_state), do: ""
end
