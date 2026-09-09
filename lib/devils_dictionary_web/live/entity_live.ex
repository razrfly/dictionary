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
  from the sections and from the counts. The connections list at the foot is the
  guarantee that nothing a curator asserted is invisible merely because this
  page has no section for its predicate.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Markdown

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page: nil, id: nil)}

  @impl true
  def handle_params(%{"id" => id, "slug" => slug}, _uri, socket) do
    case Integer.parse(id) do
      {object_id, ""} -> load(socket, object_id, slug)
      _ -> {:noreply, missing(socket, id)}
    end
  end

  defp load(socket, object_id, slug) do
    case EntityPage.build(object_id) do
      nil ->
        {:noreply, missing(socket, object_id)}

      page ->
        canonical = Connection.slugify(page.entity.label)

        if slug == canonical do
          {:noreply,
           socket
           |> assign(:page, page)
           |> assign(:id, object_id)
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

          <.panel :if={@page.biography != []} id="entity-biography" label="biography">
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
          </.panel>

          <.panel :if={@page.works != []} id="entity-works" label="works authored">
            <ul class="space-y-1">
              <li :for={work <- @page.works} id={"work-#{work.object_id}"}>
                <.a navigate={~p"/entities/#{work.object_id}/#{Connection.slugify(work.label)}"}>
                  {work.label}
                </.a>
                <span :if={work.description} class="text-mist-500">— {work.description}</span>
              </li>
            </ul>
          </.panel>

          <.panel :if={@page.definitions != []} id="entity-definitions" label="definitions authored">
            <ul class="space-y-3">
              <li :for={definition <- @page.definitions} id={"definition-#{definition.object_id}"}>
                <.a
                  :if={definition.defines}
                  navigate={~p"/words/#{definition.defines.object_id}/#{definition.defines.slug}"}
                >
                  {definition.defines.lemma}
                </.a>
                <span :if={is_nil(definition.defines)} class="text-mist-500">
                  {definition.headword}
                </span>
                <div class="prose prose-sm prose-mist max-w-none dark:prose-invert">
                  {Phoenix.HTML.raw(Markdown.to_html(definition.body, definition.body_format))}
                </div>
                <p :if={definition.published_in} class="mt-1 text-sm/7 text-mist-500">
                  Published in
                  <.a navigate={
                    ~p"/entities/#{definition.published_in.object_id}/#{Connection.slugify(definition.published_in.label)}"
                  }>
                    {definition.published_in.label}
                  </.a>
                </p>
              </li>
            </ul>
          </.panel>

          <.panel :if={@page.editions != []} id="entity-editions" label="editions">
            <ul class="space-y-1">
              <li :for={edition <- @page.editions} id={"edition-#{edition.object_id}"}>
                <.a navigate={~p"/entities/#{edition.object_id}/#{Connection.slugify(edition.label)}"}>
                  {edition.label}
                </.a>
              </li>
            </ul>
          </.panel>

          <.panel :if={@page.contents != []} id="entity-contents" label="contents">
            <ul class="space-y-1">
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
          </.panel>

          <.panel id="entity-connections" label="connections">
            <p class="text-sm/7 text-mist-500">
              {@page.counts.incoming} in, {@page.counts.outgoing} out
            </p>
            <ul class="mt-2 space-y-1">
              <li
                :for={claim <- @page.connections.incoming}
                id={"connection-in-#{claim.assertion_id}"}
              >
                <.a navigate={~p"/connections/#{claim.assertion_id}"}>
                  {endpoint_label(claim.subject_object_id)}
                </.a>
                <span class="text-mist-500">— {claim.predicate.forward_label} →</span>
                <span>this</span>
              </li>
              <li
                :for={claim <- @page.connections.outgoing}
                id={"connection-out-#{claim.assertion_id}"}
              >
                <span>this</span>
                <span class="text-mist-500">— {claim.predicate.forward_label} →</span>
                <.a navigate={~p"/connections/#{claim.assertion_id}"}>
                  {endpoint_label(claim.object_object_id)}
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
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="mt-10 border-t border-mist-950/10 pt-8 dark:border-white/10">
      <.eyebrow>{@label}</.eyebrow>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # One lookup per row. A connections list is capped at fifty, and the
  # alternative — a join per endpoint kind in the page query — would be four
  # left joins to save a handful of gets on a page nobody paginates.
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
