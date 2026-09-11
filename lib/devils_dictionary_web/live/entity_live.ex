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
    do: {:ok, assign(socket, page: nil, id: nil, cursors: %{}, entity_slug: nil)}

  @impl true
  def handle_params(%{"id" => id, "slug" => slug} = params, _uri, socket) do
    case Integer.parse(id) do
      {object_id, ""} -> load(socket, object_id, slug, params)
      _ -> {:noreply, missing(socket, id)}
    end
  end

  defp load(socket, object_id, slug, params) do
    cursors = cursor_params(params)

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
           |> assign(:page_title, page.entity.label)}
        else
          # The slug is cosmetic, so a wrong one is not an error — it is a
          # redirect to the readable form of the identity that was asked for.
          {:noreply, push_navigate(socket, to: ~p"/entities/#{object_id}/#{canonical}")}
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
          <header id="entity-header">
            <.eyebrow>{@page.entity.kind}</.eyebrow>
            <.heading>{@page.entity.label}</.heading>
            <.text :if={@page.entity.description} class="mt-2">
              {@page.entity.description}
            </.text>
            <p
              :if={@page.details != %{} and @page.details != nil}
              class="mt-2 text-sm/7 text-mist-500"
            >
              {detail_line(@page.details)}
            </p>
            <p :if={@page.entity.qid} class="mt-2 text-sm/7">
              <.a href={"https://www.wikidata.org/wiki/#{@page.entity.qid}"}>
                {@page.entity.qid} ↗
              </.a>
            </p>
          </header>

          <.panel
            :if={@page.biography != []}
            id="entity-biography"
            label="biography"
            count={@page.pagination.biography.count}
          >
            <article
              :for={article <- @page.biography}
              id={"biography-#{article.object_id}"}
              class="prose prose-mist max-w-none dark:prose-invert"
            >
              {Phoenix.HTML.raw(Markdown.to_html(article.body, article.body_format))}
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
                  <p class="text-pretty text-base/7 text-mist-700 sm:text-sm/6 dark:text-mist-400">
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
                <.a navigate={~p"/connections/#{claim.assertion_id}"}>
                  {endpoint_label(claim.subject_object_id)}
                </.a>
                <span class="text-mist-500">{claim.predicate.forward_label} → this</span>
              </li>
              <li
                :for={claim <- @page.connections.outgoing}
                id={"connection-out-#{claim.assertion_id}"}
                class="flex flex-wrap items-baseline gap-x-2 py-3"
              >
                <span class="text-mist-500">this → {claim.predicate.forward_label}</span>
                <.a navigate={~p"/connections/#{claim.assertion_id}"}>
                  {endpoint_label(claim.object_object_id)}
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

  defp endpoint_label(object_id) do
    case Connection.endpoint(object_id) do
      nil -> "##{object_id}"
      endpoint -> endpoint.label
    end
  end

  defp detail_line(details) do
    details
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join(" · ", fn {key, value} ->
      "#{key |> to_string() |> String.replace("_", " ")}: #{value}"
    end)
  end
end
