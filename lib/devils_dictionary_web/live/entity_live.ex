defmodule DevilsDictionaryWeb.EntityLive do
  @moduledoc """
  `/entities/:id/:slug` — the thing page, and the other half of #74's goal 2.

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
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Markdown

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page: nil, id: nil, cursors: %{}, entity_slug: nil, back_path: nil)}

  @impl true
  def handle_params(%{"id" => id, "slug" => slug} = params, _uri, socket) do
    case Integer.parse(id) do
      {object_id, ""} -> load(socket, object_id, slug, params)
      _ -> {:noreply, missing(socket, id)}
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
          {:noreply,
           socket
           |> assign(:page, page)
           |> assign(:id, object_id)
           |> assign(:cursors, cursors)
           |> assign(:entity_slug, canonical)
           |> assign(:back_path, back_path)
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
    |> assign(:id, id)
    |> assign(:page_title, "no such thing")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.container class="py-10">
        <%= if @page == nil do %>
          <div id="no-such-entity" class="py-12">
            <.heading>Nothing here</.heading>
            <.text class="mt-4">
              No thing with that identity. An identity is retired rather than deleted, so a
              link that once worked still resolves — this one never named anything.
            </.text>
            <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
          </div>
        <% else %>
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
                  ~p"/entities/#{@page.entity.object_id}/#{Connection.slugify(@page.entity.label)}"
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
                <.a navigate={~p"/entities/#{output.object_id}/#{Connection.slugify(output.label)}"}>
                  {output.label}
                </.a>
              </li>
            </ul>
          </section>

          <header
            id="entity-header"
            class="grid items-start gap-6 sm:grid-cols-[8rem_minmax(0,1fr)] sm:gap-8"
          >
            <div
              :if={@page.entity.image_url || @page.details[:work_kind] == "film"}
              id="entity-artwork"
              class="aspect-[2/3] w-28 overflow-hidden rounded-sm bg-mist-950/5 sm:w-32 dark:bg-white/5"
            >
              <img
                :if={@page.entity.image_url}
                src={@page.entity.image_url}
                alt={"Poster for #{@page.entity.label}"}
                referrerpolicy="no-referrer"
                class="size-full object-cover"
              />
              <div
                :if={!@page.entity.image_url}
                id="entity-artwork-fallback"
                class="flex size-full items-center justify-center text-mist-400"
              >
                <.icon name="hero-film" class="size-7 stroke-current" />
              </div>
            </div>
            <div class="min-w-0">
              <.eyebrow>{@page.entity.kind}</.eyebrow>
              <.heading>{@page.entity.label}</.heading>
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
                <.a :if={claim.path} navigate={claim.path} class="font-medium">{claim.label}</.a>
                <span :if={is_nil(claim.path)} class="font-medium">{claim.label}</span>
                <div class="min-w-0">
                  <p :if={claim.detail} class="text-sm/6 text-pretty text-mist-700 dark:text-mist-300">
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
          </.panel>

          <.panel
            :if={@page.discovery_appearances != []}
            id="entity-discovery-appearances"
            label="also appeared in discovery for"
            count={length(@page.discovery_appearances)}
          >
            <ul role="list" class="divide-y divide-mist-950/5 dark:divide-white/10">
              <li
                :for={appearance <- @page.discovery_appearances}
                id={"discovery-appearance-#{appearance.target_object_id}"}
                class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-3"
              >
                <.a :if={appearance.path} navigate={appearance.path} class="font-medium">
                  {appearance.label}
                </.a>
                <span :if={is_nil(appearance.path)} class="font-medium">{appearance.term}</span>
                <span class="text-sm text-mist-500">
                  Automatic match · {appearance.provider}
                </span>
              </li>
            </ul>
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
                next_path(@id, @entity_slug, @cursors, :biography, @page.pagination.biography.next)
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
                  navigate={~p"/entities/#{work.object_id}/#{Connection.slugify(work.label)}"}
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
              path={next_path(@id, @entity_slug, @cursors, :works, @page.pagination.works.next)}
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
                      ~p"/entities/#{definition.published_in.object_id}/#{Connection.slugify(definition.published_in.label)}"
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
                  @id,
                  @entity_slug,
                  @cursors,
                  :definitions,
                  @page.pagination.definitions.next
                )
              }
              label="More definitions"
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
                <.a navigate={~p"/entities/#{edition.object_id}/#{Connection.slugify(edition.label)}"}>
                  {edition.label}
                </.a>
              </li>
            </ul>
            <.pager
              :if={@page.pagination.editions.next}
              id="editions-next"
              path={next_path(@id, @entity_slug, @cursors, :editions, @page.pagination.editions.next)}
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
              path={next_path(@id, @entity_slug, @cursors, :contents, @page.pagination.contents.next)}
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
                <.a :if={claim.path} navigate={claim.path}>{claim.label}</.a>
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
                <.a :if={claim.path} navigate={claim.path}>{claim.label}</.a>
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
                    @id,
                    @entity_slug,
                    @cursors,
                    :connections_in,
                    @page.pagination.connections_in.next
                  )
                }
                label="More incoming connections"
              />
              <.pager
                :if={@page.pagination.connections_out.next}
                id="connections-out-next"
                path={
                  next_path(
                    @id,
                    @entity_slug,
                    @cursors,
                    :connections_out,
                    @page.pagination.connections_out.next
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

  @cursor_keys ~w(biography works definitions editions contents connections_in connections_out)a

  defp cursor_params(params) do
    Map.new(@cursor_keys, fn key ->
      param = "#{key}_after"

      value =
        case Integer.parse(params[param] || "") do
          {cursor, ""} when cursor > 0 -> cursor
          _ -> nil
        end

      {key, value}
    end)
  end

  defp page_opts(cursors),
    do: Enum.map(cursors, fn {key, value} -> {String.to_atom("#{key}_after"), value} end)

  defp next_path(id, slug, cursors, section, cursor) do
    query =
      cursors
      |> Map.put(section, cursor)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {"#{key}_after", value} end)

    ~p"/entities/#{id}/#{slug}?#{query}"
  end

  defp safe_back_path(path) when is_binary(path) do
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and
         (String.starts_with?(uri.path || "", "/words/") or
            String.starts_with?(uri.path || "", "/define/")),
       do: path,
       else: nil
  end

  defp safe_back_path(_path), do: nil

  defp review_label(:accepted), do: "Reviewed connection"
  defp review_label(:disputed), do: "Disputed connection"
  defp review_label(:changed_since_review), do: "Changed since review"
  defp review_label(_state), do: "Awaiting review"

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
