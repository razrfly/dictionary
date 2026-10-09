defmodule DevilsDictionaryWeb.EntityLive do
  @moduledoc """
  `/entities/:id/:slug` — the thing page, and the other half of #74's goal 2 —
  and the same page at a subject's address, `/<family>/:slug` (#219).

  Bierce's biography, the works he wrote and the definitions he wrote are three
  sections here, and **all three are the same object id asked a different
  question**. In MVP-0 they could not be one page: `people` held authors,
  `concepts` held encyclopedia subjects, and nothing joined them, so he was two
  rows and "his definitions" and "his biography" were two populations.

  Addressed by `object_id`, with the slug as a readable tail that nothing reads
  back — ADR decision 10. A slug that does not match the entity's label is a
  redirect to the one that does, so a stale link keeps working and the address
  bar tells the truth.

  Every read is a **public** read, so a claim a reviewer rejected is missing
  from the sections and from the counts. Each named role has its own cursor;
  paging definitions never moves works, editions or biography.

  ## At a subject's address (#219 B2, B5)

  The eight family routes (`/nature/mars`, `/works/butterfly-novel`) are
  answered only by `Routing.Resolver`, in the reader's mode: the ledger says
  which page the address serves, and the page says which identity. The
  content is this page's, unchanged; the header adds the family, a draft
  mark in internal mode, the way back to On and the external identifier,
  and the address's provenance sits in a drawer. An equivalent spelling or
  an alias follows to the canonical; a choice lists the successors; anything
  else says what the address is (`DevilsDictionaryWeb.ReadingStatus` gives a
  direct request its 301, 404, 410, 400 or 500).
  """

  use DevilsDictionaryWeb, :live_view

  on_mount DevilsDictionaryWeb.ReadingMode

  import Ecto.Query
  import DevilsDictionary.Routing.Input, only: [is_id: 1]

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Routing.{Address, Classifications, Links, Page, Resolver, RouteChange}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Markdown
  alias DevilsDictionaryWeb.{ExampleProvenance, SourceBadge}

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         page: nil,
         artwork: nil,
         id: nil,
         cursors: %{},
         entity_slug: nil,
         back_path: nil,
         base: nil,
         paths: %{},
         subject: nil,
         unresolved: nil,
         choice: nil
       )}

  @impl true
  def handle_params(params, uri, %{assigns: %{live_action: :subject}} = socket) do
    base = URI.parse(uri).path
    socket = assign(socket, base: base, subject: nil, unresolved: nil, choice: nil)

    case Resolver.resolve(base, mode: socket.assigns.reading_mode) do
      %{outcome: :canonical, page: %Page{role: role} = page} when role in [:subject, :edition] ->
        subject(socket, page, params)

      %{outcome: :redirect, location: location} ->
        {:noreply, push_navigate(socket, to: Address.encode(location), replace: true)}

      %{outcome: :choice} = resolution ->
        {:noreply,
         socket
         |> assign(:page, nil)
         |> assign(:choice, successors(resolution, socket.assigns.reading_mode))
         |> assign(:page_title, "Several subjects")}

      resolution ->
        {:noreply,
         socket
         |> assign(:page, nil)
         |> assign(:unresolved, unresolved_outcome(resolution))
         |> assign(:page_title, unresolved_title(unresolved_outcome(resolution)))}
    end
  end

  def handle_params(%{"id" => id, "slug" => slug} = params, uri, socket) do
    socket = assign(socket, :base, URI.parse(uri).path)

    case Integer.parse(id) do
      {object_id, ""} when is_id(object_id) -> load(socket, object_id, slug, params)
      _ -> {:noreply, missing(socket, id)}
    end
  end

  # The page an address serves, and the identity it is about. The address is
  # the ledger's; nothing here compares it with the label.
  defp subject(socket, %Page{} = page, params) do
    cursors = cursor_params(params)

    case EntityPage.build(page.target_object_id, page_opts(cursors)) do
      nil ->
        {:noreply, missing(socket, page.target_object_id)}

      entity_page ->
        artwork = Artworks.get(page.target_object_id)

        {:noreply,
         socket
         |> assign(:page, entity_page)
         |> assign(:artwork, artwork)
         |> assign(:id, page.target_object_id)
         |> assign(:cursors, cursors)
         |> assign(:entity_slug, Connection.slugify(entity_page.entity.label))
         |> assign(:back_path, safe_back_path(params["from"]))
         |> assign(:paths, subject_paths(entity_page, artwork, socket.assigns.reading_mode))
         |> assign(:subject, subject_header(page, entity_page, socket.assigns.base))
         |> assign(:page_title, entity_page.entity.label)}
    end
  end

  defp load(socket, object_id, slug, params) do
    cursors = cursor_params(params)
    back_path = safe_back_path(params["from"])

    case EntityPage.build(object_id, page_opts(cursors)) do
      nil ->
        {:noreply, missing(socket, object_id)}

      page ->
        canonical = Connection.slugify(page.entity.label)

        if slug == canonical do
          artwork = Artworks.get(object_id)

          {:noreply,
           socket
           |> assign(:page, page)
           |> assign(:artwork, artwork)
           |> assign(:id, object_id)
           |> assign(:cursors, cursors)
           |> assign(:entity_slug, canonical)
           |> assign(:back_path, back_path)
           |> assign(:paths, subject_paths(page, artwork, socket.assigns.reading_mode))
           |> assign(:page_title, page.entity.label)}
        else
          # The slug is cosmetic, so a wrong one is not an error — it is a
          # redirect to the readable form of the identity that was asked for.
          query = if back_path, do: %{from: back_path}, else: %{}

          {:noreply, push_navigate(socket, to: ~p"/entities/#{object_id}/#{canonical}?#{query}")}
        end
    end
  end

  defp missing(socket, id) do
    socket
    |> assign(:page, nil)
    |> assign(:artwork, nil)
    |> assign(:id, id)
    |> assign(:page_title, "no such thing")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.container class="py-10">
        <%= cond do %>
          <% @unresolved -> %>
            <.unresolved outcome={@unresolved} address={URI.decode(@base || "")} />
          <% @choice -> %>
            <div id="subject-choice" class="py-12">
              <.heading>Several subjects</.heading>
              <.text class="mt-4 max-w-2xl">
                This address named one subject that has since been split. It chooses none of them
                for you.
              </.text>
              <ul role="list" class="mt-6 flex flex-col gap-2 text-base/7 sm:text-sm/6">
                <li :for={successor <- @choice}>
                  <.a navigate={successor.path}>{successor.label}</.a>
                </li>
              </ul>
            </div>
          <% @page == nil -> %>
            <div id="no-such-entity" class="py-12">
              <.heading>Nothing here</.heading>
              <.text class="mt-4">
                No thing with that identity. An identity is retired rather than deleted, so a
                link that once worked still resolves — this one never named anything.
              </.text>
              <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
            </div>
          <% true -> %>
            <.a
              :if={@back_path}
              id="entity-back-link"
              navigate={@back_path}
              class="mb-7 inline-flex items-center gap-2 text-sm text-mist-500 transition-colors hover:text-mist-950 dark:hover:text-white"
            >
              <.icon name="hero-arrow-left" class="size-4 stroke-current" /> Back to definition
            </.a>

            <section
              :if={@page.identity.state == :merged}
              id="entity-merged-notice"
              class="mb-8 border-y border-mist-950/10 bg-mist-950/3 py-4 dark:border-white/10 dark:bg-white/5"
            >
              <p class="flex min-w-0 items-start gap-2 text-base/7 text-pretty sm:text-sm/6">
                <.icon name="hero-arrow-path" class="size-4 h-lh shrink-0 stroke-mist-500" />
                <span class="min-w-0">
                  This identity was merged into <.a navigate={
                    subject_path(@paths, @page.entity.object_id, @page.entity.label)
                  }>
                  {@page.entity.label}
                </.a>. This old address remains meaningful, and its relationships and identity history are
                  retained.
                </span>
              </p>
            </section>

            <section
              :if={@page.identity.state == :split}
              id="entity-split-notice"
              class="mb-8 border-y border-mist-950/10 bg-mist-950/3 py-4 dark:border-white/10 dark:bg-white/5"
            >
              <p class="text-base/7 text-pretty sm:text-sm/6">
                This identity was split. Attachments remain unresolved until a reviewer deliberately maps
                them.
              </p>
              <ul role="list" class="mt-2 flex flex-wrap gap-3 text-base/7 sm:text-sm/6">
                <li :for={output <- @page.identity.outputs}>
                  <.a navigate={subject_path(@paths, output.object_id, output.label)}>
                    {output.label}
                  </.a>
                </li>
              </ul>
            </section>

            <header
              id="entity-header"
              class={
                [
                  "grid items-start gap-6 sm:gap-8",
                  # The image column only when there is an image: without one,
                  # the name and description fell into the 8rem column.
                  (@page.entity.image_url || @artwork || @page.details[:work_kind] == "film") &&
                    "sm:grid-cols-[8rem_minmax(0,1fr)]"
                ]
              }
            >
              <div
                :if={@page.entity.image_url || @artwork || @page.details[:work_kind] == "film"}
                id="entity-artwork"
                phx-hook="ArtworkImage"
                phx-update="ignore"
                data-image-state={
                  if(@page.entity.image_url || (@artwork && @artwork.image_url),
                    do: "loading",
                    else: "empty"
                  )
                }
                class="aspect-[2/3] w-28 overflow-hidden rounded-sm bg-mist-950/5 sm:w-32 dark:bg-white/5"
              >
                <img
                  :if={@page.entity.image_url || (@artwork && @artwork.image_url)}
                  src={@page.entity.image_url || (@artwork && @artwork.image_url)}
                  alt={if(@artwork, do: @page.entity.label, else: "Poster for #{@page.entity.label}")}
                  referrerpolicy="no-referrer"
                  data-artwork-image
                  class="size-full object-cover"
                />
                <div
                  id="entity-artwork-fallback"
                  data-artwork-fallback
                  hidden={!!(@page.entity.image_url || (@artwork && @artwork.image_url))}
                  class="flex size-full items-center justify-center text-mist-400"
                >
                  <.icon
                    name={if(@artwork, do: "hero-photo", else: "hero-film")}
                    class="size-7 stroke-current"
                  />
                </div>
              </div>
              <div class="min-w-0">
                <div
                  :if={@subject}
                  id="subject-header"
                  class="flex flex-wrap items-center gap-x-3 gap-y-1"
                >
                  <.eyebrow id="subject-family">{@subject.family_label}</.eyebrow>
                  <span
                    :if={@subject.draft?}
                    id="subject-draft"
                    class="rounded-full border border-dashed border-amber-600/60 px-2 py-0.5 text-sm/5 font-medium text-amber-800 dark:border-amber-400/50 dark:text-amber-200"
                  >
                    Draft
                  </span>
                  <span
                    :if={@subject.fixture}
                    id="subject-fixture"
                    title={@subject.fixture}
                    class="rounded-full border border-dashed border-amber-600/60 px-2 py-0.5 text-sm/5 font-medium text-amber-800 dark:border-amber-400/50 dark:text-amber-200"
                  >
                    Fixture
                  </span>
                </div>
                <.eyebrow :if={is_nil(@subject)}>{@page.entity.kind}</.eyebrow>
                <.heading>{@page.entity.label}</.heading>
                <p
                  :if={@subject}
                  class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-base/7 sm:text-sm/6"
                >
                  <.a
                    :if={@subject.on}
                    id="subject-on"
                    navigate={@subject.on}
                    class="inline-flex min-h-11 items-center"
                  >
                    {@subject.on_label}
                  </.a>
                  <a
                    :if={@page.entity.qid}
                    id="subject-qid"
                    href={"https://www.wikidata.org/wiki/#{@page.entity.qid}"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex min-h-11 items-center text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
                  >
                    {@page.entity.qid}<span aria-hidden="true">&nbsp;↗</span>
                  </a>
                </p>
                <p
                  :if={@page.details != %{} and @page.details != nil}
                  class="mt-2 text-sm/7 text-mist-500"
                >
                  {detail_line(@page.details)}
                </p>
                <.text :if={@page.entity.description} class="mt-3 max-w-2xl">
                  {@page.entity.description}
                </.text>
              </div>
            </header>

            <.subject_provenance :if={@subject} subject={@subject} />

            <section
              :if={@artwork}
              id="artwork-metadata"
              class="mt-8 max-w-3xl border-y border-mist-950/10 py-6 dark:border-white/10"
            >
              <.eyebrow>artwork record</.eyebrow>
              <dl class="mt-3 grid gap-x-8 gap-y-3 text-sm/6 sm:grid-cols-2">
                <div :if={@artwork.creators != []}>
                  <dt class="text-mist-500">Creator</dt>
                  <dd>
                    <span :for={{creator, index} <- Enum.with_index(@artwork.creators)}>
                      <span :if={index > 0}>, </span><.a navigate={
                        subject_path(@paths, creator.object_id, creator.label)
                      }>
                        {creator.label}
                      </.a>
                    </span>
                  </dd>
                </div>
                <div :if={@artwork.date}>
                  <dt class="text-mist-500">Date</dt><dd>{@artwork.date}</dd>
                </div>
                <div :if={@artwork.medium}>
                  <dt class="text-mist-500">Medium</dt><dd>{@artwork.medium}</dd>
                </div>
                <div :if={@artwork.collection}>
                  <dt class="text-mist-500">Collection</dt><dd>{@artwork.collection}</dd>
                </div>
                <div :if={@artwork.image_attribution} class="sm:col-span-2">
                  <dt class="text-mist-500">Image credit or rights notice</dt>
                  <dd>{@artwork.image_attribution}</dd>
                </div>
              </dl>
              <div :if={@artwork.source_links != []} class="mt-4 flex flex-wrap gap-4 text-sm/6">
                <a
                  :for={source <- @artwork.source_links}
                  href={source.url}
                  target="_blank"
                  rel="noreferrer"
                  class="underline underline-offset-4"
                >{source.label} ↗</a>
              </div>
              <p :if={@artwork.freshness} class="mt-4 text-xs/5 text-mist-500">
                Artsy fields are a freshness-limited source cache and may become stale. Dictionary keeps
                Wikidata and independently supported identity data when that provider is unavailable.
              </p>
            </section>

            <%!-- The reverse view (#105, #181 wireframe 5): what this person is
               cited for, grouped by word, best first, with both counts on
               every line; then what the record files them under. Public:
               a nomination nobody has accepted is not on their page. --%>
            <.panel
              :if={@page.cited_as != []}
              id="entity-cited-as"
              label="cited as an example of"
              count={Enum.sum(Enum.map(@page.cited_as, &length(&1.items)))}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li
                  :for={group <- @page.cited_as}
                  id={"cited-as-#{group.lexeme.object_id}"}
                  class="grid gap-1 py-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,1fr)] sm:gap-5"
                >
                  <p class="text-base/7 font-medium sm:text-sm/6">
                    <.a navigate={~p"/words/#{group.lexeme.object_id}/#{group.lexeme.slug}"}>
                      {group.lexeme.lemma}
                    </.a>
                  </p>
                  <ul role="list" class="flex min-w-0 flex-col gap-2">
                    <li
                      :for={item <- group.items}
                      id={"cited-as-claim-#{item.claim.assertion_id}"}
                      class="min-w-0 text-base/7 text-pretty sm:text-sm/6"
                    >
                      <p class="text-mist-700 dark:text-mist-300">
                        <span
                          class="tabular-nums text-mist-950 dark:text-white"
                          aria-label={"#{item.signals.human_up} cite, #{item.signals.human_down} object"}
                        >
                          ▲ {item.signals.human_up} ▽ {item.signals.human_down}
                        </span>
                        <span :if={item.target.gloss}> · “{item.target.gloss}”</span>
                      </p>
                      <p class="text-mist-500">
                        <span class="tabular-nums">{item.claim.evidence_count}</span>
                        evidence · {cited_by(item.claim.nominated_by)} · {cited_state(
                          item.claim.review_state
                        )}
                        <.a
                          navigate={~p"/connections/#{item.claim.assertion_id}"}
                          aria-label="Inspect this citation"
                          class="ml-1 inline-flex align-text-bottom text-mist-400 hover:text-mist-950 dark:hover:text-white"
                        >
                          <.icon name="hero-information-circle" class="size-4 stroke-current" />
                        </.a>
                      </p>
                      <%!-- The reverse of selection (#212 decision 3): each
                           published composition of the global default that
                           selects this claim now, from the same provenance the
                           word page's card reads. No page shows an opening
                           yet, and the line says so. --%>
                      <p
                        :for={featured <- featured_in(item)}
                        id={"cited-as-featured-#{item.claim.assertion_id}-#{featured.composition_id}"}
                        class="text-mist-500"
                      >
                        selected for the opening of {Enum.map_join(featured.scope, ", ", & &1.lemma)} since {ExampleProvenance.date(
                          featured.published_at
                        )}<span :if={not featured.shown_on_page}> · not yet shown on its page</span>
                      </p>
                    </li>
                  </ul>
                </li>
              </ul>
            </.panel>

            <.panel
              :if={@page.named_under != []}
              id="entity-named-under"
              label="named by the record under"
              count={length(@page.named_under)}
            >
              <ul role="list" class="flex flex-wrap gap-x-5 gap-y-2 py-3">
                <li
                  :for={named <- @page.named_under}
                  id={"named-under-#{named.kind}-#{named.object_id}-#{named.source.slug}"}
                  class="min-w-0 text-base/7 sm:text-sm/6"
                >
                  <.a
                    :if={named.kind == :lexeme}
                    navigate={~p"/words/#{named.object_id}/#{named.slug}"}
                  >
                    {named.label}
                  </.a>
                  <.a
                    :if={named.kind == :entity}
                    navigate={subject_path(@paths, named.object_id, named.label)}
                  >
                    {named.label}
                  </.a>
                  <span class="text-mist-500"> · {named.source.name}</span>
                </li>
              </ul>
            </.panel>

            <.panel
              :if={@page.meaning_connections != []}
              id="entity-meaning-connections"
              label="connected meanings"
              count={@page.pagination.meaning_connections.count}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li
                  :for={claim <- @page.meaning_connections}
                  id={"connection-out-#{claim.assertion_id}"}
                  class="grid gap-1 py-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,1fr)] sm:gap-5"
                >
                  <.a :if={claim.path} navigate={endpoint_path(@paths, claim)} class="font-medium">
                    {claim.label}
                  </.a>
                  <span :if={is_nil(claim.path)} class="font-medium">{claim.label}</span>
                  <div class="min-w-0">
                    <p
                      :if={claim.detail}
                      class="text-sm/6 text-pretty text-mist-700 dark:text-mist-300"
                    >
                      {claim.detail}
                    </p>
                    <p class="text-sm/6 text-mist-500">
                      {review_label(claim.review_state)}<span :if={claim.rationale}> · {claim.rationale}</span>
                      <.a
                        navigate={~p"/connections/#{claim.assertion_id}"}
                        aria-label="Inspect meaning connection"
                        class="ml-1 inline-flex align-text-bottom text-mist-400 hover:text-mist-950 dark:hover:text-white"
                      >
                        <.icon name="hero-information-circle" class="size-4 stroke-current" />
                      </.a>
                    </p>
                  </div>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.meaning_connections.next}
                id="more-meaning-connections"
                label="More connected meanings"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :meaning_connections,
                    @page.pagination.meaning_connections.next,
                    @back_path
                  )
                }
              />
            </.panel>

            <.panel
              :if={@page.discovery_appearances != []}
              id="entity-discovery-appearances"
              label="also appeared in discovery for"
              count={@page.pagination.discovery_appearances.count}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li
                  :for={appearance <- @page.discovery_appearances}
                  id={"discovery-appearance-#{appearance.target_object_id}-#{appearance.provider_slug}"}
                  class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-3"
                >
                  <.a
                    :if={appearance.path}
                    navigate={endpoint_path(@paths, appearance)}
                    class="font-medium"
                  >
                    {appearance.label}
                  </.a>
                  <span :if={is_nil(appearance.path)} class="font-medium">{appearance.term}</span>
                  <span class="text-sm text-mist-500">
                    Automatic match · {appearance.provider}
                  </span>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.discovery_appearances.next}
                id="discovery-appearances-next"
                label="More discovery appearances"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :discovery_appearances,
                    @page.pagination.discovery_appearances.next,
                    @back_path
                  )
                }
              />
            </.panel>

            <.panel
              :if={@page.biography != []}
              id="entity-biography"
              label={if(@page.entity.kind == :person, do: "biography", else: "about")}
              count={@page.pagination.biography.count}
            >
              <article
                :for={article <- @page.biography}
                id={"biography-#{article.object_id}"}
                class="prose prose-mist max-w-none dark:prose-invert"
              >
                <%= if article.display_restricted? do %>
                  <p id={"biography-#{article.object_id}-restricted"} class="text-mist-500">
                    The source and revision are retained, but rights metadata does not permit displaying this
                    text.
                  </p>
                <% else %>
                  {Phoenix.HTML.raw(Markdown.to_html(article.body, article.body_format))}
                <% end %>
                <p :if={article.url} class="not-prose mt-2 text-sm/7">
                  <.a href={article.url}>source ↗</.a>
                </p>
              </article>
              <.pager
                :if={@page.pagination.biography.next}
                id="biography-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :biography,
                    @page.pagination.biography.next,
                    @back_path
                  )
                }
                label="More biography"
              />
            </.panel>

            <.panel
              :if={@page.works != []}
              id="entity-works"
              label="works authored"
              count={@page.pagination.works.count}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li :for={work <- @page.works} id={"work-#{work.object_id}"}>
                  <.a
                    navigate={subject_path(@paths, work.object_id, work.label)}
                    class="flex min-w-0 items-start justify-between gap-4 py-3"
                  >
                    <span class="min-w-0">
                      <span class="font-medium">{work.label}</span>
                      <span :if={work.description} class="text-mist-500"> — {work.description}</span>
                    </span>
                    <.icon name="hero-arrow-right" class="size-4 h-lh shrink-0 stroke-mist-400" />
                  </.a>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.works.next}
                id="works-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :works,
                    @page.pagination.works.next,
                    @back_path
                  )
                }
                label="More works"
              />
            </.panel>

            <.panel
              :if={@page.definitions != []}
              id="entity-definitions"
              label="definitions authored"
              count={@page.pagination.definitions.count}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li
                  :for={definition <- @page.definitions}
                  id={"definition-#{definition.object_id}"}
                  class="grid gap-1 py-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,1fr)] sm:gap-5"
                >
                  <div class="min-w-0">
                    <.a
                      :if={definition.defines}
                      navigate={~p"/words/#{definition.defines.object_id}/#{definition.defines.slug}"}
                    >
                      {definition.defines.lemma}
                    </.a>
                    <p :if={is_nil(definition.defines)} class="text-base/7 text-mist-500 sm:text-sm/6">
                      {definition.headword}
                    </p>
                  </div>
                  <div class="min-w-0">
                    <p class="line-clamp-2 text-pretty text-base/7 text-mist-700 sm:text-sm/6 dark:text-mist-400">
                      {definition.summary}
                    </p>
                    <p :if={definition.published_in} class="text-base/7 text-mist-500 sm:text-sm/6">
                      Published in
                      <.a navigate={
                        subject_path(
                          @paths,
                          definition.published_in.object_id,
                          definition.published_in.label
                        )
                      }>
                        {definition.published_in.label}
                      </.a>
                    </p>
                  </div>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.definitions.next}
                id="definitions-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :definitions,
                    @page.pagination.definitions.next,
                    @back_path
                  )
                }
                label="More definitions"
              />
            </.panel>

            <%!-- #164 C5: the lines a person is credited with, beside the works
               and definitions and paged on their own. One row per line; the
               badges are every source whose current, public claim says so.
               The line links to its evidence page, never to an entry — a
               quotation is content, not something the encyclopedia is about. --%>
            <.panel
              :if={@page.quotations != []}
              id="entity-quotations"
              label="quotations"
              count={@page.pagination.quotations.count}
            >
              <.line_list id="quotation" lines={@page.quotations} />
              <.pager
                :if={@page.pagination.quotations.next}
                id="quotations-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :quotations,
                    @page.pagination.quotations.next,
                    @back_path
                  )
                }
                label="More quotations"
              />
            </.panel>

            <%!-- #164 C4: never inside the credits above. A register's finding
               that a line circulates under this name and is not theirs. --%>
            <.panel
              :if={@page.misattributed != []}
              id="entity-misattributed"
              label="misattributed"
              count={@page.pagination.misattributed.count}
            >
              <p class="text-pretty text-base/7 text-mist-500 sm:text-sm/6">
                Often credited to {@page.entity.label}; the sources below say these are not theirs.
              </p>
              <.line_list id="misattributed" lines={@page.misattributed} />
              <.pager
                :if={@page.pagination.misattributed.next}
                id="misattributed-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :misattributed,
                    @page.pagination.misattributed.next,
                    @back_path
                  )
                }
                label="More misattributed lines"
              />
            </.panel>

            <.panel
              :if={@page.editions != []}
              id="entity-editions"
              label="editions"
              count={@page.pagination.editions.count}
            >
              <ul role="list" class="space-y-1">
                <li :for={edition <- @page.editions} id={"edition-#{edition.object_id}"}>
                  <.a navigate={subject_path(@paths, edition.object_id, edition.label)}>
                    {edition.label}
                  </.a>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.editions.next}
                id="editions-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :editions,
                    @page.pagination.editions.next,
                    @back_path
                  )
                }
                label="More editions"
              />
            </.panel>

            <.panel
              :if={@page.contents != []}
              id="entity-contents"
              label="contents"
              count={@page.pagination.contents.count}
            >
              <ul role="list" class="space-y-1">
                <li :for={item <- @page.contents} id={"content-#{item.object_id}"}>
                  <.a
                    :if={item.defines}
                    navigate={~p"/words/#{item.defines.object_id}/#{item.defines.slug}"}
                  >
                    {item.defines.lemma}
                  </.a>
                  <span :if={is_nil(item.defines)}>{item.headword}</span>
                </li>
              </ul>
              <.pager
                :if={@page.pagination.contents.next}
                id="contents-next"
                path={
                  next_path(
                    @base,
                    @cursors,
                    :contents,
                    @page.pagination.contents.next,
                    @back_path
                  )
                }
                label="More contents"
              />
            </.panel>

            <.panel
              :if={@page.connections.incoming != [] or @page.connections.outgoing != []}
              id="entity-connections"
              label="other connections"
              count={@page.pagination.connections_in.count + @page.pagination.connections_out.count}
            >
              <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
                <li
                  :for={claim <- @page.connections.incoming}
                  id={"connection-in-#{claim.assertion_id}"}
                  class="flex flex-wrap items-baseline gap-x-2 py-3"
                >
                  <.a :if={claim.path} navigate={endpoint_path(@paths, claim)}>{claim.label}</.a>
                  <span :if={is_nil(claim.path)}>{claim.label}</span>
                  <span class="text-mist-500">{claim.predicate.forward_label} → this</span>
                  <.a
                    navigate={~p"/connections/#{claim.assertion_id}"}
                    aria-label={"Inspect #{claim.predicate.forward_label} relationship"}
                    class="text-mist-400 transition-colors hover:text-mist-950 dark:hover:text-white"
                  >
                    <.icon name="hero-information-circle" class="size-4 h-lh stroke-current" />
                  </.a>
                </li>
                <li
                  :for={claim <- @page.connections.outgoing}
                  id={"connection-out-#{claim.assertion_id}"}
                  class="flex flex-wrap items-baseline gap-x-2 py-3"
                >
                  <span class="text-mist-500">this → {claim.predicate.forward_label}</span>
                  <.a :if={claim.path} navigate={endpoint_path(@paths, claim)}>{claim.label}</.a>
                  <span :if={is_nil(claim.path)}>{claim.label}</span>
                  <.a
                    navigate={~p"/connections/#{claim.assertion_id}"}
                    aria-label={"Inspect #{claim.predicate.forward_label} relationship"}
                    class="text-mist-400 transition-colors hover:text-mist-950 dark:hover:text-white"
                  >
                    <.icon name="hero-information-circle" class="size-4 h-lh stroke-current" />
                  </.a>
                </li>
              </ul>
              <div class="flex flex-wrap justify-end gap-3">
                <.pager
                  :if={@page.pagination.connections_in.next}
                  id="connections-in-next"
                  path={
                    next_path(
                      @base,
                      @cursors,
                      :connections_in,
                      @page.pagination.connections_in.next,
                      @back_path
                    )
                  }
                  label="More incoming connections"
                />
                <.pager
                  :if={@page.pagination.connections_out.next}
                  id="connections-out-next"
                  path={
                    next_path(
                      @base,
                      @cursors,
                      :connections_out,
                      @page.pagination.connections_out.next,
                      @back_path
                    )
                  }
                  label="More outgoing connections"
                />
              </div>
            </.panel>

            <.panel :if={@page.sources != []} id="entity-sources" label="sources">
              <ul role="list" class="flex flex-wrap gap-x-5 gap-y-2">
                <li :for={source <- @page.sources} id={"entity-source-#{source.slug}"}>
                  <.a href={source.url} target="_blank" rel="noreferrer">
                    {source.name} ↗
                  </.a>
                </li>
              </ul>
            </.panel>
        <% end %>
      </.container>
    </Layouts.app>
    """
  end

  attr :subject, :map, required: true

  # Where the address came from (B5): kept in a drawer, because a reader
  # wants the subject and an inspector wants the ledger.
  defp subject_provenance(assigns) do
    ~H"""
    <details
      id="subject-provenance"
      class="mt-6 max-w-3xl text-base/7 text-mist-500 sm:text-sm/6"
    >
      <summary class="w-fit cursor-pointer underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">
        About this address
      </summary>
      <dl class="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-[auto_minmax(0,1fr)]">
        <dt class="font-medium text-mist-700 dark:text-mist-300">Address</dt>
        <dd class="font-mono break-all">{@subject.address}</dd>
        <dt class="font-medium text-mist-700 dark:text-mist-300">Page</dt>
        <dd>
          {@subject.role} page, {if @subject.draft?, do: "a draft: not public", else: "published"}
        </dd>
        <dt :if={@subject.allocation} class="font-medium text-mist-700 dark:text-mist-300">
          Allocated
        </dt>
        <dd :if={@subject.allocation}>
          <span class="tabular-nums">{Calendar.strftime(@subject.allocation.at, "%-d %B %Y")}</span>
          by {@subject.allocation.actor || "an import"}
        </dd>
        <dt :if={@subject.allocation} class="font-medium text-mist-700 dark:text-mist-300">Why</dt>
        <dd :if={@subject.allocation} class="text-pretty">{@subject.allocation.reason}</dd>
        <dt :if={@subject.fixture} class="font-medium text-mist-700 dark:text-mist-300">Fixture</dt>
        <dd :if={@subject.fixture} class="text-pretty">{@subject.fixture}</dd>
        <dt :if={@subject.decision} class="font-medium text-mist-700 dark:text-mist-300">
          Classification
        </dt>
        <dd :if={@subject.decision}>
          {Address.label(to_string(@subject.decision.family)) || @subject.decision.status}, {if @subject.decision.origin ==
                                                                                                  :override,
                                                                                                do:
                                                                                                  "confirmed by #{@subject.reviewer || "a reviewer"}",
                                                                                                else:
                                                                                                  "by the evaluator"} · policy {@subject.decision.policy_version}
        </dd>
        <dt :if={@subject.decision} class="font-medium text-mist-700 dark:text-mist-300">
          Evidence
        </dt>
        <dd :if={@subject.decision} class="font-mono break-all">
          {String.slice(@subject.decision.evidence_fingerprint || "", 0, 16)}…
        </dd>
      </dl>
    </details>
    """
  end

  attr :outcome, :atom, required: true
  attr :address, :string, required: true

  # An address that serves nothing to this reader. Missing and unavailable
  # read the same: a draft is not news to the public.
  defp unresolved(assigns) do
    ~H"""
    <div id="subject-unresolved" data-outcome={@outcome} class="py-12">
      <.heading>{unresolved_title(@outcome)}</.heading>
      <.text class="mt-4 max-w-2xl">{unresolved_text(@outcome)}</.text>
      <p class="mt-2 font-mono text-base/7 break-all text-mist-500 sm:text-sm/6">{@address}</p>
      <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
    </div>
    """
  end

  defp unresolved_title(:gone), do: "Removed"
  defp unresolved_title(:invalid), do: "Not an address"
  defp unresolved_title(:corrupt), do: "This address is broken"
  defp unresolved_title(_missing), do: "Nothing at this address"

  defp unresolved_text(:gone),
    do:
      "What was here was deliberately removed. The address stays reserved and names nothing else."

  defp unresolved_text(:invalid),
    do: "This is not an address this site could hold: its spelling cannot be read."

  defp unresolved_text(:corrupt),
    do:
      "The routing records for this address disagree with each other, so it serves nothing rather than a guess. The problem has been logged."

  defp unresolved_text(_missing),
    do: "No subject has this address. Addresses are never guessed from a name."

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="mt-10 border-t border-mist-950/10 pt-8 dark:border-white/10">
      <div class="flex items-baseline justify-between gap-4">
        <.eyebrow>{@label}</.eyebrow>
        <p :if={@count} class="tabular-nums text-base/7 text-mist-500 sm:text-sm/6">
          {number(@count)} total
        </p>
      </div>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :id, :string, required: true, doc: "the DOM id prefix for each row"
  attr :lines, :list, required: true

  # A line is its words first — the reason the row exists — then who holds it
  # and the way to its cited revision. The badges carry the names beside them
  # in the header's manner (#152): a badge is never the only place a name is.
  defp line_list(assigns) do
    ~H"""
    <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
      <li :for={line <- @lines} id={"#{@id}-#{line.object_id}"} class="flex flex-col gap-1.5 py-3">
        <p
          :if={line.summary}
          class="line-clamp-3 text-pretty text-base/7 text-mist-950 sm:text-sm/6 dark:text-white"
        >
          “{line.summary}”
        </p>
        <p :if={is_nil(line.summary)} class="text-base/7 text-mist-500 sm:text-sm/6">
          {line.headword || "Text withheld by its licence"}
        </p>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-base/7 text-mist-500 sm:text-sm/6">
          <span :if={line.year} class="tabular-nums">{line.year}</span>
          <span :for={source <- line.sources} class="inline-flex items-center gap-1.5">
            <SourceBadge.badge source={source} decorative />
            {source.name}
          </span>
          <.a
            id={"#{@id}-evidence-#{line.object_id}"}
            navigate={~p"/evidence/content/#{line.revision_id}"}
          >
            Evidence
          </.a>
        </div>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  defp pager(assigns) do
    ~H"""
    <nav class="flex justify-end pt-5" aria-label={@label}>
      <.button_link id={@id} patch={@path} variant="soft" size="md">
        {@label}
        <.icon name="hero-arrow-right" class="size-4 h-lh shrink-0 stroke-current" />
      </.button_link>
    </nav>
    """
  end

  @cursor_keys ~w(biography works definitions quotations misattributed editions contents connections_in connections_out meaning_connections discovery_appearances)a

  defp cursor_params(params) do
    Map.new(@cursor_keys, fn key ->
      param = "#{key}_after"

      value = cursor_value(key, params[param])

      {key, value}
    end)
  end

  defp page_opts(cursors),
    do: Enum.map(cursors, fn {key, value} -> {String.to_atom("#{key}_after"), value} end)

  defp cursor_value(:discovery_appearances, value) when is_binary(value) do
    with [target, source_slug] <- String.split(value, ":", parts: 2),
         {target_object_id, ""} when target_object_id > 0 <- Integer.parse(target),
         true <- Regex.match?(~r/\A[a-z0-9_-]+\z/, source_slug) do
      value
    else
      _ -> nil
    end
  end

  defp cursor_value(_key, value) when is_binary(value) do
    case Integer.parse(value) do
      {cursor, ""} when cursor > 0 -> cursor
      _ -> nil
    end
  end

  defp cursor_value(_key, _value), do: nil

  # The next page of a section, on the page's own path — the subject's
  # address, or the exact identity route.
  defp next_path(base, cursors, section, cursor, back_path) do
    query =
      cursors
      |> Map.put(section, cursor)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {"#{key}_after", value} end)
      |> then(fn query -> if back_path, do: Map.put(query, "from", back_path), else: query end)

    base <> "?" <> Plug.Conn.Query.encode(query)
  end

  defp safe_back_path(path) when is_binary(path) do
    uri = URI.parse(path)

    reader = ["/words/", "/on/" | Enum.map(Address.families(), &"/#{&1}/")]

    if is_nil(uri.scheme) and is_nil(uri.host) and
         String.starts_with?(uri.path || "", reader),
       do: path,
       else: nil
  end

  defp safe_back_path(_path), do: nil

  defp review_label(:accepted), do: "Reviewed connection"
  defp review_label(:disputed), do: "Disputed connection"
  defp review_label(:changed_since_review), do: "Changed since review"
  defp review_label(_state), do: "Awaiting review"

  # The record names the nominator, or the page says it does not.
  defp cited_by(%{label: nil}), do: "nominator unknown"
  defp cited_by(%{label: label}), do: "nominated by #{label}"

  defp featured_in(%{provenance: %{featured: featured}}),
    do: Enum.filter(featured, &(&1.scope != []))

  defp featured_in(_item), do: []

  defp cited_state(:accepted), do: "selected by a reviewer"
  defp cited_state(:changed_since_review), do: "changed since review"
  defp cited_state(:disputed), do: "disputed"
  defp cited_state(_state), do: "not yet reviewed"

  # Every identity the page links, through the one link helper in one query
  # (#219): its address in the reading mode, or the exact-identity route.
  defp subject_paths(page, artwork, mode) do
    [
      [{page.entity.object_id, page.entity.label}],
      Enum.map(page.identity.outputs, &{&1.object_id, &1.label}),
      Enum.map((artwork && artwork.creators) || [], &{&1.object_id, &1.label}),
      for(%{kind: :entity} = named <- page.named_under, do: {named.object_id, named.label}),
      Enum.map(page.works, &{&1.object_id, &1.label}),
      for(%{published_in: %{} = p} <- page.definitions, do: {p.object_id, p.label}),
      Enum.map(page.editions, &{&1.object_id, &1.label}),
      # Connection and discovery endpoints that are subjects.
      for(
        rows <- [
          page.connections.incoming,
          page.connections.outgoing,
          page.meaning_connections,
          page.discovery_appearances
        ],
        %{subject_id: id, label: label} <- rows,
        do: {id, label}
      )
    ]
    |> Enum.concat()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Links.paths(mode)
  end

  defp subject_path(paths, object_id, label),
    do: Map.get(paths, object_id) || Links.entity_path(object_id, label)

  # A connection's other end: a subject through the link helper, a word or
  # a content item at its own route.
  defp endpoint_path(paths, %{subject_id: id, label: label}),
    do: subject_path(paths, id, label)

  defp endpoint_path(_paths, endpoint), do: endpoint.path

  # The subject header's facts: the family (from the address), the draft
  # mark, the way back to On, and the provenance drawer's contents.
  defp subject_header(%Page{} = page, entity_page, base) do
    object_id = page.target_object_id
    decision = Classifications.current(object_id)

    allocation =
      page.canonical_path_id &&
        Repo.one(
          from c in RouteChange,
            left_join: a in Actor,
            on: a.id == c.actor_id,
            where: c.path_id == ^page.canonical_path_id and c.after_kind == :canonical,
            order_by: c.id,
            limit: 1,
            select: %{at: c.inserted_at, actor: a.label, reason: c.reason}
        )

    reviewer =
      decision && decision.reviewer_actor_id &&
        Repo.one(from a in Actor, where: a.id == ^decision.reviewer_actor_id, select: a.label)

    # The words spelled like the subject, named as that page names itself
    # ("On c" for C++): a way to the words, not a claim about identity.
    {on, on_label} =
      with %{lexemes: [lexeme | _]} <- Lexicon.lookup(entity_page.entity.label),
           %{lexemes: [headword | _]} <- Lexicon.lookup(lexeme.slug) do
        {~p"/on/#{lexeme.slug}", "On #{headword.lemma}"}
      else
        _none -> {nil, nil}
      end

    family = Address.family(URI.decode(base))

    fixture =
      Repo.one(
        from e in DevilsDictionary.Registry.Entity,
          where: e.object_id == ^object_id,
          select: fragment("?->>'fixture'", e.metadata)
      )

    %{
      family: family,
      fixture: fixture,
      family_label: Address.label(family),
      address: URI.decode(base),
      draft?: page.publication_state == :draft,
      role: page.role,
      on: on,
      on_label: on_label,
      decision: decision,
      reviewer: reviewer,
      allocation: allocation
    }
  end

  defp successors(resolution, mode) do
    ids = Enum.map(resolution.successors, & &1.page_id)

    labels =
      Repo.all(
        from p in Page,
          join: e in DevilsDictionary.Registry.Entity,
          on: e.object_id == p.target_object_id,
          where: p.id in ^ids,
          select: {p.id, {p.target_object_id, e.preferred_label}}
      )
      |> Map.new()

    for %{page_id: id} <- resolution.successors, {object_id, label} <- List.wrap(labels[id]) do
      %{label: label, path: Links.path(object_id, label, mode)}
    end
  end

  defp unresolved_outcome(%{outcome: outcome}) when outcome in [:missing, :unavailable],
    do: :missing

  defp unresolved_outcome(%{outcome: outcome}), do: outcome

  defp detail_line(details) do
    case details do
      %{work_kind: work_kind} when is_binary(work_kind) ->
        [String.capitalize(work_kind), details[:first_published_year]]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      _ ->
        details
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.map_join(" · ", fn {key, value} ->
          "#{key |> to_string() |> String.replace("_", " ")}: #{value}"
        end)
    end
  end
end
