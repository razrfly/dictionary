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

  attr :browsers, :list,
    default: [],
    doc:
      "one `browser_config/1` map per browser-transport provider that covers this target, " <>
        "in registry order"

  attr :contributor, :boolean,
    default: false,
    doc: "whether the reader may carry a corpus candidate into the review composer"

  def section(assigns) do
    states = assigns.states |> Map.values() |> Enum.sort_by(&{archetype_rank(&1), &1.provider})

    assigns =
      assigns
      |> assign(:shelves, shelves(states))
      |> assign(:provider_count, length(states))

    ~H"""
    <.compact_section
      :if={@shelves != [] or @browsers != []}
      shelves={@shelves}
      browsers={@browsers}
      provider_count={@provider_count}
      return_path={@return_path}
      contributor={@contributor}
    />
    """
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
  attr :browsers, :list, default: []
  attr :provider_count, :integer, required: true
  attr :return_path, :string, default: nil
  attr :contributor, :boolean, default: false

  # Every kind on screen at once, one chrome for the lot (#131 Phase 2, V3).
  #
  # A row per kind: the kind named once in a narrow column on the left — its
  # count and who put it there — and its rail beside. Nothing is behind a
  # chip. What used to repeat per shelf repeats no more: one *About* for the
  # block at its foot, with a section per kind inside it; and each shelf's
  # *Load more* is its rail's last tile, where the reader's eye already is.
  # The GIFs are one more row, the hook and its transport untouched.
  #
  # The cards themselves are unchanged. A credit on a `:required` row is a
  # licence condition — beneath the thumbnail, always visible, never clamped
  # (#116 M4) — so the Images row is taller than the sketch that dropped
  # them, and that is the price of the licence rather than a flaw.
  defp compact_section(assigns) do
    assigns =
      assigns
      |> assign(:shelf_count, length(assigns.shelves))
      |> assign(:total, assigns.shelves |> Enum.map(&length(&1.entries)) |> Enum.sum())
      |> assign(:about, Enum.filter(assigns.shelves, &(contributing(&1) != [])))

    ~H"""
    <.slab id="in-culture" aria-label="Related discoveries" title="Out in the world">
      <:meta>
        <span :if={@total > 0}>{@total} things · </span>every match says why it is here
      </:meta>

      <div class="divide-y divide-mist-950/10 dark:divide-white/10">
        <div :for={shelf <- @shelves} id={"culture-shelf-#{shelf.type}"} class="flex gap-4 py-4">
          <div class="w-20 shrink-0 pt-1">
            <h3
              id={"culture-filter-#{shelf.type}"}
              class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white"
            >
              {if shelf.entries == [],
                do: "In #{shelf_label(shelf.type)}",
                else: shelf_heading(shelf.type)}
            </h3>
            <p :if={shelf.entries != []} class="text-sm/6 tabular-nums text-mist-500">
              {length(shelf.entries)}
            </p>
            <%!-- D4 of #126: the byline is names. Each provider's qualifier is
                 a sentence about how it matched, which is the About's. --%>
            <p :if={shelf.entries != []} class="mt-1 text-xs text-mist-400">
              <span :for={{state, index} <- Enum.with_index(contributing(shelf))}>
                <span :if={index > 0} aria-hidden="true">·</span>
                <span id={"culture-provider-#{state.provider}"}>{state.provider_name}</span>
              </span>
            </p>
            <%!-- A mark a contributing source's licence makes a condition, not
                 a logo a source would like shown (#142). The Guardian's clause
                 6(b)(vi) is the first, and its logos page asks for two things
                 this position gives it: a link back to theguardian.com, and
                 placement "adjacent to our content" — which is the rail
                 immediately to the right of this column. `Culture` still knows
                 no provider by name: what is drawn is whatever the state
                 carried, and a source with no obligation carries nothing. --%>
            <.attribution_mark :for={marked <- marked(shelf)} {marked} />
          </div>

          <div class="min-w-0 flex-1 space-y-2">
            <%!-- No scroll snapping on this rail, deliberately. A shelf's corpus
                 items paint on the first, synchronous render and its live results
                 are prepended when they arrive; CSS scroll snap re-snaps a
                 container to its previously snapped box after a layout change, so
                 the rail opened 1,584 px in — past every result the page had just
                 gone and fetched. Measured on `/define/soldier`. --%>
            <ul
              :if={shelf.entries != []}
              role="list"
              tabindex="0"
              aria-label={"#{shelf_heading(shelf.type)} matches; scroll for more"}
              id={shelf_id("culture-results", shelf, @shelf_count)}
              class="flex gap-4 overflow-x-auto overscroll-x-contain pb-2 focus-visible:outline-2 focus-visible:outline-offset-2"
            >
              <li
                :for={entry <- shelf.entries}
                id={"culture-result-#{entry.item.external_namespace}-#{entry.item.external_id}"}
                class={["shrink-0", ContentTypes.column(shelf.type)]}
              >
                <.culture_thumbnail
                  item={entry.item}
                  type={shelf.type}
                  mark={card_mark(entry.state)}
                  return_path={@return_path}
                />
              </li>
              <li :if={advancing(shelf) != ""} class={["shrink-0", ContentTypes.column(shelf.type)]}>
                <.compact_more shelf={shelf} />
              </li>
            </ul>
            <%!-- How old this shelf is, and when it goes again (#144 Phase 2).
                 A sentence, so it belongs here with the other sentences rather
                 than in the 80 px column of names and counts on the left; and
                 one line for the shelf rather than one per source, because the
                 reader's question is about the rail, not about who filled
                 which part of it. `refresh_due` was computed for every shelf
                 state since #109 and read by one test. --%>
            <p
              :if={freshness(shelf) != []}
              id={"culture-freshness-#{shelf.type}"}
              class="text-base text-mist-500 sm:text-sm"
            >
              <span :for={{clause, index} <- Enum.with_index(freshness(shelf))}>
                <span :if={index > 0} aria-hidden="true">·</span>
                {clause}
              </span>
            </p>
            <%!-- A shelf can be one provider's answer and another's silence. The
                 items are not a reason to stop saying that the other is still
                 looking, or has failed — but they are a reason to name the
                 provider rather than the content type, which is not empty. --%>
            <p
              :for={state <- if(shelf.entries == [], do: shelf.states, else: pending(shelf))}
              id={status_id(status_base(state.status), state, @provider_count)}
              role="status"
              class="text-base text-mist-500 sm:text-sm"
            >
              <%= case {shelf.entries, state.status} do %>
                <% {[], :empty} -> %>
                  No matching {shelf_label(shelf.type)} for this term yet.
                <% {[], :failed} -> %>
                  {shelf_heading(shelf.type)} discovery is temporarily unavailable.
                <% {[], status} when status in [:deferred, :expired, :withdrawn] -> %>
                  {shelf_heading(shelf.type)} discovery will retry when available.
                <% {[], _} -> %>
                  Looking for matching {shelf_label(shelf.type)}…
                <% {_, :failed} -> %>
                  {state.provider_name} is temporarily unavailable.
                <% {_, status} when status in [:deferred, :expired, :withdrawn] -> %>
                  {state.provider_name} will retry when available.
                <% _ -> %>
                  Still looking at {state.provider_name}…
              <% end %>
            </p>
          </div>
        </div>

        <.browser_shelf :for={browser <- @browsers} browser={browser} />
      </div>

      <%!-- One About for the block (D3 of #126, taken one step further): a
           section per kind, and inside each the section per source the shelf
           always had, in the rail's own order. --%>
      <details :if={@about != []} id="culture-about" class="min-w-0 pt-3 pb-4">
        <summary class="w-fit cursor-pointer text-base text-mist-500 hover:text-mist-700 focus-visible:outline-2 focus-visible:outline-offset-2 sm:text-sm dark:text-mist-400 dark:hover:text-mist-200">
          Matches for “{@about |> hd() |> contributing() |> Enum.find_value(& &1[:term])}” · About these results
        </summary>
        <div class="space-y-5 pt-3">
          <.compact_note :for={shelf <- @about} shelf={shelf} contributor={@contributor} />
        </div>
      </details>
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
  attr :browser, :map, required: true

  @doc false
  # One shelf a browser-transport provider fills, through its content-type row
  # like any other (#144 Phase 3).
  #
  # Before this, `DevilsDictionaryWeb.GiphyShelf` was its own component with
  # its own heading, its own card width and GIPHY's mark written into the
  # markup — the one exception to promise 9 of the README, *the reader knows
  # no provider by name*. Everything provider-specific now arrives in the
  # config the provider's own `browser_config/1` returned: the hook that makes
  # the requests, the note that says what its results are, and the mark a
  # licence requires — the same map, read by the same `mark/1`, drawn by the
  # same component as a server shelf's (#144 followups). What the shelf *looks* like comes from
  # `ContentTypes.fetch!/1`, as it does for a server provider.
  #
  # `phx-update="ignore"` because everything inside is the hook's: the items
  # are never persisted and never reach an assign (K10), so LiveView must not
  # patch over them on the next render. The row's card width and title clamp
  # ride along as `data-column` and `data-title-clamp`, because the hook
  # builds the cards and would otherwise have to guess them.
  #
  # The heading id carries the provider as well as the type: two browser
  # providers on one content type are two shelves, and two `<h3>`s with one
  # id is the duplicate LiveView refuses.
  defp browser_shelf(assigns) do
    assigns =
      assigns
      |> assign(:row, ContentTypes.fetch!(assigns.browser.content_type))
      |> assign(:mark, mark(Map.get(assigns.browser, :attribution_mark)))

    ~H"""
    <section
      id={"culture-browser-#{@browser.provider}-#{Base.url_encode64(@browser.term, padding: false)}"}
      phx-hook={@browser.hook}
      phx-update="ignore"
      data-query={@browser.term}
      data-language={@browser.language}
      data-api-key={Map.get(@browser, :api_key)}
      data-column={@row.column}
      data-title-clamp={@row.title_clamp}
      aria-label={"#{@row.heading} discoveries"}
      class="flex gap-4 py-4"
    >
      <div class="w-20 shrink-0 pt-1">
        <h3
          id={"culture-filter-#{@browser.content_type}-#{@browser.provider}"}
          class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white"
        >
          {@row.heading}
        </h3>
        <p id={"culture-provider-#{@browser.provider}"} class="mt-1 text-xs text-mist-400">
          {@browser.provider_name}
        </p>
        <.attribution_mark
          :if={match?(%{placement: :shelf}, @mark)}
          mark={@mark}
          provider={@browser.provider}
        />
      </div>
      <div class="min-w-0 flex-1 space-y-2">
        <p data-status role="status" class="text-base text-mist-500 sm:text-sm">
          Looking for {@row.label}…
        </p>
        <ul
          data-results
          tabindex="0"
          aria-label={"#{@row.heading} matches; scroll for more"}
          class="flex gap-4 overflow-x-auto overscroll-x-contain pb-2 focus-visible:outline-2 focus-visible:outline-offset-2"
        >
        </ul>
        <%!-- The freshness a browser shelf can honestly claim (#144 Phase 4).
             A server shelf reads *fetched* and *refreshes* off its display
             root; this one has no root to read, because the request is the
             reader's own and nothing it returns is stored. That is not a
             reason to say nothing — "every shelf says when it was fetched or
             since when it is held" is the issue's own acceptance line, and
             *now, and not kept* is this shelf's true answer to it. --%>
        <p
          id={"culture-freshness-#{@browser.content_type}-#{@browser.provider}"}
          class="text-base text-mist-500 sm:text-sm"
        >
          Fetched by your browser on this visit; nothing is stored here.
        </p>
        <p class="flex flex-wrap items-baseline justify-between gap-x-6 text-base text-mist-500 sm:text-sm">
          <span>{@browser.note}</span>
          <button
            data-more
            type="button"
            hidden
            class="text-mist-600 underline underline-offset-4 hover:text-mist-950 dark:text-mist-300 dark:hover:text-white"
          >Load more</button>
        </p>
      </div>
    </section>
    """
  end

  # The shelf's age, as clauses a `·` joins.
  #
  # The **live** half reads the contributing states' display roots: the oldest
  # `fetched_at` on the rail, because a shelf is as old as the stalest thing on
  # it, and then what happens next — a run past its `refresh_after` is
  # re-queued by the render that is drawing this, so it says *refreshing now*
  # rather than promising a date that has passed.
  #
  # The **corpus** half says *held since* instead. A corpus never refreshes, by
  # design (K2 of #109): it is a committed, checksummed selection, and its
  # `generated_at` is a fact about the file.
  #
  # A shelf with neither — one still loading, or one whose only state is a
  # browser provider — says nothing, which is why this returns a list.
  defp freshness(shelf) do
    states = contributing(shelf)

    live =
      states
      |> Enum.filter(
        &(Map.get(&1, :archetype) != :corpus and is_struct(&1[:fetched_at], DateTime))
      )

    held =
      states
      |> Enum.map(&Map.get(&1, :held_since))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    fetched =
      case live do
        [] -> []
        _ -> ["Fetched #{ago(Enum.min_by(live, & &1.fetched_at).fetched_at)}"]
      end

    refresh =
      cond do
        live == [] -> []
        Enum.any?(live, &Map.get(&1, :refresh_due)) -> ["refreshing on this visit"]
        true -> ["refreshes on your next visit after #{on(next_refresh(live))}"]
      end

    catalog =
      case held do
        nil ->
          []

        since ->
          [if(live == [], do: "Held since #{on(since)}", else: "catalog held since #{on(since)}")]
      end

    case fetched ++ refresh ++ catalog do
      [] -> []
      clauses -> List.update_at(clauses, -1, &(&1 <> "."))
    end
  end

  defp next_refresh(states) do
    states
    |> Enum.map(& &1[:refresh_after])
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  # Whole units and never a decimal: *3 days ago* is what a reader wants from a
  # shelf, and *2.7 days ago* is a number pretending to be one.
  defp ago(%DateTime{} = then) do
    seconds = max(DateTime.diff(DateTime.utc_now(), then, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> plural(div(seconds, 60), "minute")
      seconds < 86_400 -> plural(div(seconds, 3_600), "hour")
      seconds < 30 * 86_400 -> plural(div(seconds, 86_400), "day")
      true -> "on #{on(then)}"
    end
  end

  defp plural(1, unit), do: "1 #{unit} ago"
  defp plural(count, unit), do: "#{count} #{unit}s ago"

  # `%-d %b %Y`, the same form a card's date line takes, so two dates on one
  # page are one format.
  defp on(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%-d %b %Y")

  defp on(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> on(datetime)
      _error -> value
    end
  end

  defp on(_value), do: ""

  defp contributing(shelf) do
    shelf.states
    |> Enum.filter(&Map.has_key?(shelf.shown, &1.provider))
    |> Enum.sort_by(&{Shelf.tier_rank(Map.get(&1, :tier)), &1.provider})
  end

  # The contributing sources that owe the shelf a mark. A source that put
  # nothing on the rail owes nothing — the obligation is to credit content
  # that is shown, and a mark under an empty turn would be branding rather
  # than compliance.
  #
  # `:shelf` and not every mark: a licence that asks for its mark beside the
  # content gets it on each card instead (`card_mark/1`), and one obligation
  # met twice is a logo the terms did not ask for.
  defp marked(shelf) do
    shelf
    |> contributing()
    |> Enum.map(&%{provider: &1.provider, mark: mark(Map.get(&1, :attribution_mark))})
    |> Enum.filter(&match?(%{placement: :shelf}, &1.mark))
  end

  # The mark the cards of one state carry, or nothing. The state's, not the
  # item's: what a source's licence requires is a fact about the source, and
  # a shelf holding two sources' items gives each card the mark of the source
  # that supplied it.
  defp card_mark(state) do
    case mark(Map.get(state, :attribution_mark)) do
      %{placement: :card} = mark -> mark
      _other -> nil
    end
  end

  attr :mark, :map, required: true
  attr :provider, :string, required: true

  # A required mark is never clamped, hidden behind a pointer or collapsed into
  # a tooltip, for the same reason a `:required` credit is not (#116 Phase 3):
  # a condition of the licence that only some readers see is not met. Both
  # variants ship in the markup and CSS picks one, so the mark is correct in
  # either theme without JavaScript and without a filter over the wrong file.
  defp attribution_mark(assigns) do
    ~H"""
    <a
      id={"culture-mark-#{@provider}"}
      href={@mark.href}
      target="_blank"
      rel="noreferrer"
      aria-label={@mark.alt}
      class="mt-2 block"
    >
      <.mark_images mark={@mark} />
    </a>
    """
  end

  attr :mark, :map, required: true

  # Both variants ship in the markup and CSS picks one, wherever the mark is
  # drawn: the shelf's byline column and the card's credit block are two
  # placements of one mark and not two marks.
  defp mark_images(assigns) do
    ~H"""
    <img
      src={@mark.light}
      alt={@mark.alt}
      width={@mark.width}
      class={["max-w-full", @mark.dark && "dark:hidden"]}
    />
    <img
      :if={@mark.dark}
      src={@mark.dark}
      alt=""
      aria-hidden="true"
      width={@mark.width}
      class="hidden max-w-full dark:block"
    />
    """
  end

  # Worth reporting beside a shelf that is not empty. A provider whose own
  # answer was *nothing* is not: "no matching artwork for this term" under six
  # artworks would be the page contradicting itself.
  defp pending(shelf),
    do: Enum.filter(shelf.states, &(&1.items == [] and &1.status != :empty))

  attr :item, :map, required: true
  attr :type, :atom, required: true
  attr :return_path, :string, default: nil

  attr :mark, :map,
    default: nil,
    doc: "the supplying source's `:card` mark, already read by `mark/1`, or nil"

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
        <%!-- A `:card` mark, under the credit and inside an exclusion zone
             (#143). The width is the provider's — Spotify's Branding
             Guidelines ask partner integrations for the **full** logo, icon
             and wordmark, at no less than 70 px — and the 10 px of isolation
             around it is the clearance this card gives any mark, which is
             half the icon's height at that minimum. It is why the mark is
             under the credit rather than literally beside it: 70 + 20 leaves
             54 px of a 144 px column for an artist's name, and *YoungBoy
             Never Broke Again* does not fit in 54 px. It is the card's credit
             block either way — the credit names who made the track, the mark
             names who supplied it. `-mx-2.5` pulls the exclusion zone back
             out to the card's edge so the logo itself lines up with the text
             above it.

             Two files rather than one with a filter, here as on the shelf:
             Spotify's guidelines allow the green logo only on black or white
             and this card's dark surface is neither, so the black logo takes
             the light theme and the white one the dark. --%>
        <div
          :if={@mark}
          id={"culture-mark-#{@item.external_namespace}-#{@item.external_id}"}
          class="-mx-2.5 p-2.5"
        >
          <.mark_images mark={@mark} />
        </div>
        <a
          :if={@source_url}
          href={@source_url}
          target="_blank"
          rel="noreferrer"
          id={"culture-source-#{@item.external_id}"}
          class="inline-flex rounded-sm text-sm text-mist-500 underline-offset-4 transition-colors hover:text-mist-950 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 dark:hover:text-white"
        >
          {(@mark && @mark.link_text) || "Source"} ↗
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

  @doc """
  The mark a source's licence requires, read off whatever declared it, or nil.

  One shape for one obligation (#144): a server provider's
  `Provider.attribution_mark/0`, a browser provider's `:attribution_mark` key
  in `browser_config/1`, and the state a card is drawn from all carry this
  same map, and it is read here in one place. The keys are the provider's —
  `:light` and `:dark` are the two files, `:alt` what a screen reader is
  owed, `:href` where the mark links, `:link_text` the wording a licence
  dictates for the link back, `:width` the size it is drawn at, and
  `:placement` whether the licence asks for it on the shelf or on the card.

  Anything this cannot read whole is no mark, never a broken image: a bare
  name, a missing key, a placement nobody draws, or a file that is not a
  local path. The last is the rule with teeth — a mark is an asset this app
  ships and not a provider's hotlink, so `/images/x.svg` passes and
  `https://cdn.example/x.svg` does not.

  This component matches on no provider's name anywhere in it, which is what
  promise 9 asks; what it branches on is the licence's own answer.
  """
  def mark(%{light: light, alt: alt, width: width, placement: placement} = mark)
      when is_binary(light) and is_binary(alt) and is_integer(width) and width > 0 and
             placement in [:shelf, :card] do
    dark = Map.get(mark, :dark)
    href = external_href(Map.get(mark, :href))
    link_text = presence(Map.get(mark, :link_text))

    cond do
      not local_asset?(light) ->
        nil

      not is_nil(dark) and not (is_binary(dark) and local_asset?(dark)) ->
        nil

      presence(alt) == nil ->
        nil

      # A shelf mark is a link by licence — the Guardian's logos page asks for
      # one and GIPHY's terms ask for one — so a shelf mark with no href it
      # could link is not the mark the licence described. A card mark may have
      # none: the card already links back through the item's own `source_url`,
      # and two links to the same place is a second obligation nobody wrote.
      placement == :shelf and is_nil(href) ->
        nil

      true ->
        %{
          light: light,
          dark: dark,
          alt: alt,
          href: href,
          width: width,
          link_text: link_text,
          placement: placement
        }
    end
  end

  def mark(_other), do: nil

  # One leading slash and not two: `//cdn.example/mark.svg` is a URL the
  # browser resolves against the page's scheme, which is exactly the hotlink
  # the rule above refuses.
  defp local_asset?(path),
    do: String.starts_with?(path, "/") and not String.starts_with?(path, "//")

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

  # The date a card prints, or nothing. A manifest records a year as a string
  # and a provider may hand back a number; neither an empty string nor an
  # absent key is a year, and D5 says an absent year is printed as nothing at
  # all.
  #
  # An item that knows the *day* prints the day (#135): a 1925 painting is a
  # year and a news article is *15 Sep 2026*, and a News card whose date line
  # said only `2026` would be the shelf failing to say the one thing that makes
  # it news. It is read from `published_at` — an ISO 8601 string — and it is one
  # function rather than a branch per content type, so any text-first type that
  # learns a publication date gets it. `year` stays the fallback, so nothing
  # that does not carry `published_at` changes.
  defp year(metadata) when is_map(metadata),
    do: published_on(metadata) || published_year(metadata)

  defp year(_metadata), do: nil

  defp published_on(metadata) do
    with value when is_binary(value) <- metadata["published_at"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      Calendar.strftime(datetime, "%-d %b %Y")
    else
      _ -> nil
    end
  end

  defp published_year(metadata) do
    case metadata["year"] do
      value when is_binary(value) -> presence(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp entry_path(%{object_id: object_id, preview_metadata: metadata}, return_path)
       when is_integer(object_id) do
    slug = DevilsDictionary.Claims.Connection.slugify(metadata["title"])
    query = if return_path, do: %{from: return_path}, else: %{}
    ~p"/entities/#{object_id}/#{slug}?#{query}"
  end

  defp entry_path(_item, _return_path), do: nil

  attr :shelf, :map, required: true
  attr :contributor, :boolean, default: false

  # One kind's part of the block's About: the kind as a heading, then a
  # section per source in the rail's own order (D3 of #126).
  defp compact_note(assigns) do
    contributors = contributing(assigns.shelf)

    assigns =
      assigns
      |> assign(:contributors, contributors)
      |> assign(:admits, ContentTypes.evidence(assigns.shelf.type))

    ~H"""
    <section :if={@contributors != []} id={"culture-about-#{@shelf.type}"} class="space-y-3">
      <h4 class="text-base font-medium text-mist-950 sm:text-sm dark:text-white">
        {shelf_heading(@shelf.type)}
      </h4>
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
    </section>
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
  # has another page — per-source controls made the counts drift. Now the
  # rail's last tile: `+N` when the page cap dropped a number the page knows
  # (IMDb's shape), *More* when the providers hold an unknown number more.
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
      class={[
        "flex w-full cursor-pointer items-center justify-center rounded-sm bg-mist-950/5 text-base font-medium tabular-nums text-mist-700",
        "hover:bg-mist-950/10 focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 sm:text-sm",
        "dark:bg-white/10 dark:text-mist-300 dark:hover:bg-white/15",
        ContentTypes.get(@shelf.type).aspect || "py-6"
      ]}
    >
      {cond do
        @loading -> "Loading…"
        @shelf.overflow > 0 -> "+#{@shelf.overflow}"
        true -> "More"
      end}
    </button>
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
