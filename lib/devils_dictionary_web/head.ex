defmodule DevilsDictionaryWeb.Head do
  @moduledoc """
  What a reader page's `<head>` says about it (#237 C4, ADR 0004 §6 and
  §7), on the initial response and after live navigation.

  Each reader LiveView sets `:head` in `handle_params/3`, from one of the
  builders here, so a `push_navigate` or a `push_patch` computes it again:

    * `title`: per role. A subject: its label and family (`Voltaire ·
      People`). On: the word (`On mars`). A word: its lemma and part of
      speech (`oyster · noun`). Evidence: the revision.
    * `canonical`: the page's canonical absolute URL on the published host
      (`Routing.PublicRouting.origin/0`): a subject's allocated address; the
      exact-identity route's is the subject's address where one is served
      publicly; `/on/:slug` is its own, spelled as the headword's slug; a
      query string never changes it. A page that is not there (404, 410,
      400) names none.
    * `indexable?`, and so the robots instruction (`DevilsDictionaryWeb.
      Indexing`): `noindex` on everything but a published subject page at
      its canonical and a lexical entry of the launch manifest, served
      publicly with no query string. An indexable page carries no robots
      meta.
    * `description`: the page's first displayable sentence
      (`Routing.PageMetadata`).
    * `json_ld`: the structured data of D4 (`Routing.JsonLd`).

  `tags/1` renders them in the root layout for the initial response.
  `hook/1` renders them as data on an element inside the LiveView, whose
  `PageHead` hook (`assets/js/page_head.mjs`) keeps `document.title`, the
  canonical, the robots and description metas and the JSON-LD in step on
  live navigation. A LiveView that sets no head is noindex with no
  canonical, from both.
  """

  use Phoenix.Component

  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Routing.{Address, JsonLd, Links, Page, PageMetadata, PublicRouting}
  alias DevilsDictionary.Routing.Sitemaps
  alias DevilsDictionaryWeb.Indexing

  @suffix " · wordhoard"
  @default_title "Every word, every source"

  @doc "The site's title suffix."
  def suffix, do: @suffix

  @doc "The title of a page that names none."
  def default_title, do: @default_title

  @doc "The head of a page that is not there: noindex, no canonical."
  def unresolved(title), do: build(title: title)

  @doc """
  The head of a subject or edition page served at `canonical_path` (stored
  form) with the resolver's `outcome`, in reading `mode`, for a request with
  `query` (its query string, or nil).
  """
  def subject(%Page{} = page, %EntityPage{} = entity_page, canonical_path, outcome, mode, query)
      when is_binary(canonical_path) do
    meta = PageMetadata.subject(entity_page, canonical_path)
    canonical = absolute(canonical_path)
    title = Enum.join(Enum.reject([meta.title, meta.family_label], &is_nil/1), " · ")

    graph =
      JsonLd.subject_graph(
        canonical,
        %{title: title, description: meta.description, modified: Sitemaps.lastmod(page.id)},
        %{
          object_id: entity_page.entity.object_id,
          label: entity_page.entity.label,
          description: entity_page.entity.description,
          family: meta.family
        }
      )

    build(
      title: title,
      canonical: canonical,
      indexable?: Indexing.subject?(page, outcome, mode, query),
      description: meta.description,
      json_ld: JsonLd.encode(graph)
    )
  end

  @doc "The head of a split page's choice at its own address: noindex."
  def choice(path) when is_binary(path) do
    canonical = absolute(path)
    title = "Several subjects"

    build(
      title: title,
      canonical: canonical,
      json_ld: JsonLd.encode(JsonLd.page_graph(canonical, %{title: title}))
    )
  end

  @doc """
  The head of the exact-identity route, `/entities/:id/:slug`: noindex,
  and canonical at the subject's address where the public is served one,
  else at the route's own path. That is the page's own URL, not a link, so
  it stays when the published host links no fallback (#237 D2).
  """
  def entity(%EntityPage{} = entity_page, object_id) do
    label = entity_page.entity.label

    canonical =
      PublicRouting.origin() <>
        (Links.path(object_id, label, :public) || Links.entity_path(object_id, label))

    description = PageMetadata.description(entity_page)

    build(
      title: label,
      canonical: canonical,
      description: description,
      json_ld:
        JsonLd.encode(JsonLd.page_graph(canonical, %{title: label, description: description}))
    )
  end

  @doc """
  The head of `/on/:slug`: `title` as the page names itself, the canonical
  spelled as the headword's slug (`/on/mars` for `/on/Mars`), indexable only
  as a lexical entry of the launch manifest, in `mode`, with no `query`.
  `overview` is the authored overview that is the page when no word is
  behind it.
  """
  def on(page, title, slug, overview, mode, query) do
    cond do
      page.headword.lexemes != [] ->
        canonical = absolute("/on/" <> page.headword.slug)

        description =
          first_sentence(page.cards |> Enum.map(& &1[:opening]) |> Enum.find(&is_binary/1))

        build(
          title: title,
          canonical: canonical,
          indexable?: slug == page.headword.slug and Indexing.lexical?(slug, mode, query),
          description: description,
          json_ld:
            JsonLd.encode(JsonLd.page_graph(canonical, %{title: title, description: description}))
        )

      overview ->
        canonical = absolute("/on/" <> slug)
        description = first_sentence(overview.revision.body)

        build(
          title: title,
          canonical: canonical,
          description: description,
          json_ld:
            JsonLd.encode(JsonLd.page_graph(canonical, %{title: title, description: description}))
        )

      true ->
        unresolved(title)
    end
  end

  @doc """
  The head of one exact word, `/words/:id/:slug`: its lemma and part of
  speech, its own canonical, noindex (D1).
  """
  def word(page, lexeme_id) do
    lexeme = Enum.find(page.headword.lexemes, &(&1.id == lexeme_id))

    title =
      [page.headword.lemma, lexeme && lexeme.pos]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" · ")

    # The slug the route keeps and redirects to: the stored lexeme's own
    # (`WordLive.handle_params/3` reads it the same way).
    slug =
      case DevilsDictionary.Lexicon.by_object_id(lexeme_id) do
        %{slug: slug} when is_binary(slug) and slug != "" -> slug
        _ -> DevilsDictionary.Registry.Lexeme.slug(page.headword.lemma)
      end

    canonical = absolute("/words/#{lexeme_id}/#{slug}")

    description =
      first_sentence(page.cards |> Enum.map(& &1[:opening]) |> Enum.find(&is_binary/1))

    build(
      title: title,
      canonical: canonical,
      description: description,
      json_ld:
        JsonLd.encode(JsonLd.page_graph(canonical, %{title: title, description: description}))
    )
  end

  @doc """
  The head of a cited revision, `/evidence/<kind>/:id`: the revision, its own
  canonical, noindex.
  """
  def evidence(nil, _kind, _id), do: unresolved("No such evidence revision")

  def evidence(evidence, kind, id) when kind in ~w(content sense source-record) do
    canonical = absolute("/evidence/#{kind}/#{id}")

    title =
      "#{evidence.label || "Source record #{evidence.object_id}"} · revision #{evidence.revision_id}"

    description =
      if evidence[:display_restricted?] != true and is_binary(evidence[:body]),
        do: first_sentence(evidence.body)

    build(
      title: title,
      canonical: canonical,
      description: description,
      json_ld:
        JsonLd.encode(JsonLd.page_graph(canonical, %{title: title, description: description}))
    )
  end

  @doc "The head of the way in, `/`: its own canonical, noindex (search)."
  def search(description) do
    canonical = absolute("/")

    build(
      canonical: canonical,
      description: description,
      json_ld:
        JsonLd.encode(
          JsonLd.page_graph(canonical, %{title: @default_title, description: description})
        )
    )
  end

  defp build(fields) do
    indexable? = Keyword.get(fields, :indexable?, false) == true

    %{
      title: fields[:title],
      canonical: fields[:canonical],
      indexable?: indexable?,
      robots: Indexing.robots(indexable?),
      description: fields[:description],
      json_ld: fields[:json_ld]
    }
  end

  defp absolute(path), do: PublicRouting.origin() <> Address.encode(path)

  defp first_sentence(text) when is_binary(text), do: PageMetadata.first_sentence(text)
  defp first_sentence(_text), do: nil

  @doc "`document.title` for a head: its title, or the default, with the suffix."
  def document_title(head), do: ((head && head.title) || @default_title) <> @suffix

  @doc "The robots instruction of a head, or of none: `noindex` unless indexable."
  def robots(%{indexable?: true}), do: nil
  def robots(_head), do: Indexing.robots(false)

  attr :head, :map, default: nil, doc: "a built head, or nil for a page that sets none"

  @doc "The head elements of the initial response, for the root layout."
  def tags(assigns) do
    assigns = assign(assigns, :robots, robots(assigns.head))

    ~H"""
    <link :if={@head && @head.canonical} rel="canonical" href={@head.canonical} />
    <meta :if={@robots} name="robots" content={@robots} />
    <meta :if={@head && @head.description} name="description" content={@head.description} />
    <script :if={@head && @head.json_ld} type="application/ld+json" id="json-ld">
      <%= Phoenix.HTML.raw(@head.json_ld) %>
    </script>
    """
  end

  attr :head, :map, default: nil, doc: "a built head, or nil for a page that sets none"

  @doc """
  The same facts as data on a hidden element inside the LiveView, for the
  `PageHead` hook to apply after live navigation.
  """
  def hook(assigns) do
    assigns =
      assigns
      |> assign(:robots, robots(assigns.head))
      |> assign(:title, document_title(assigns.head))

    ~H"""
    <div
      id="page-head"
      phx-hook="PageHead"
      hidden
      data-title={@title}
      data-canonical={@head && @head.canonical}
      data-robots={@robots}
      data-description={@head && @head.description}
      data-json-ld={@head && @head.json_ld}
    >
    </div>
    """
  end
end
