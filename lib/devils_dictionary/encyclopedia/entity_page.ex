defmodule DevilsDictionary.Encyclopedia.EntityPage do
  @moduledoc """
  Everything `/entities/:id/:slug` renders, assembled in one round of queries.

  The page #74 §F draws, and the reason the whole rebuild happened:

      PERSON PAGE /entities/101/ambrose-bierce
      Ambrose Bierce · Person
      BIOGRAPHY            Article content…                 [106]
      WORKS AUTHORED       The Devil's Dictionary →         [102]
      DEFINITIONS AUTHORED nepotism →                       [105]
                             Published in selected edition → [103]

  In MVP-0 that page could not exist. `people` held authors, `concepts` held
  encyclopedia subjects, and no foreign key joined them — so Bierce was two
  rows, and "his definitions" and "his biography" were two populations that
  could not be shown as one person's. Here **every section is the same object
  id asked a different question**, which is the whole of #74's goal 2.

  ## The sections are predicates, not columns

    * **biography** — `about` content pointing at this entity
    * **works** — `authored_by` from a work entity
    * **definitions** — `authored_by` from definition content, with the word it
      `defines` and the edition it was `published_in`
    * **editions** — `edition_of` pointing at this work
    * **contents** — what an edition's definitions define
  Each role is paged independently. In particular, `authored_by` is queried
  once for work subjects and once for content subjects before either cursor is
  applied, so hundreds of definitions cannot crowd a person's works out of the
  reachable result set.

  ## Reads are public reads

  Everything here goes through `Claims.incoming/2` and `outgoing/2`, so a claim
  a reviewer rejected is absent from the sections *and* from the counts. The
  review queue is a different reader and says so.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Entity, Lexeme, Sense}
  alias DevilsDictionary.Repo

  defstruct entity: nil,
            details: %{},
            biography: [],
            works: [],
            definitions: [],
            editions: [],
            contents: [],
            connections: %{incoming: [], outgoing: []},
            pagination: %{}

  @section_cap 24
  @presented_predicates ~w(about authored_by edition_of published_in)
  @summary_limit 120

  @doc """
  Builds the page for an object id, or nil when it is not an entity.

  Nil rather than a raise: `/entities/999/x` is a page that says so, the same
  way `/define/zzzz` is.
  """
  def build(object_id, opts \\ [])

  def build(object_id, opts) when is_integer(object_id) do
    case Repo.get(Entity, object_id) do
      nil -> nil
      entity -> assemble(entity, opts)
    end
  end

  def build(_, _opts), do: nil

  defp assemble(%Entity{} = entity, opts) do
    id = entity.object_id

    {biography, biography_page} =
      incoming_page(id, "about", "content", opts[:biography_after])

    {works, works_page} =
      incoming_page(id, "authored_by", "entity", opts[:works_after])

    {definitions, definitions_page} =
      incoming_page(id, "authored_by", "content", opts[:definitions_after])

    {editions, editions_page} =
      incoming_page(id, "edition_of", "entity", opts[:editions_after])

    {contents, contents_page} = contents_of(entity, id, opts[:contents_after])

    {connections_in, connections_in_page} =
      other_connections(:incoming, id, opts[:connections_in_after])

    {connections_out, connections_out_page} =
      other_connections(:outgoing, id, opts[:connections_out_after])

    %__MODULE__{
      entity: Encyclopedia.view(entity),
      details: details(entity),
      biography: content_views(Enum.map(biography, & &1.subject_object_id)),
      works: entity_views(Enum.map(works, & &1.subject_object_id)),
      definitions: definition_views(Enum.map(definitions, & &1.subject_object_id)),
      editions: entity_views(Enum.map(editions, & &1.subject_object_id)),
      contents: definition_views(Enum.map(contents, & &1.subject_object_id)),
      connections: %{incoming: connections_in, outgoing: connections_out},
      pagination: %{
        biography: biography_page,
        works: works_page,
        definitions: definitions_page,
        editions: editions_page,
        contents: contents_page,
        connections_in: connections_in_page,
        connections_out: connections_out_page
      }
    }
  end

  defp other_connections(direction, object_id, after_cursor) do
    # The named sections above are all reverse-role sections: biography,
    # authored works/definitions, editions, and edition contents are incoming
    # claims. Suppressing the same predicates while walking *out* erased the
    # only visible work -> author and edition -> work paths. Outgoing role
    # claims are not duplicated anywhere else on this page, so they belong in
    # the connection section.
    filters =
      case direction do
        :incoming -> [exclude_predicates: @presented_predicates]
        :outgoing -> []
      end

    opts = filters ++ [after: after_cursor, limit: @section_cap + 1]

    rows =
      case direction do
        :incoming -> Claims.incoming(object_id, opts)
        :outgoing -> Claims.outgoing(object_id, opts)
      end

    visible = Enum.take(rows, @section_cap)

    count =
      case direction do
        :incoming -> Claims.count_incoming(object_id, filters)
        :outgoing -> Claims.count_outgoing(object_id, filters)
      end

    page = %{
      count: count,
      next: if(length(rows) > @section_cap, do: Claims.next_cursor(visible), else: nil)
    }

    endpoint_ids =
      Enum.map(visible, fn row ->
        case direction do
          :incoming -> row.subject_object_id
          :outgoing -> row.object_object_id
        end
      end)

    endpoints = Connection.endpoint_summaries(endpoint_ids)

    connection_rows =
      Enum.map(visible, fn row ->
        endpoint_id =
          case direction do
            :incoming -> row.subject_object_id
            :outgoing -> row.object_object_id
          end

        row
        |> Map.from_struct()
        |> Map.merge(Map.fetch!(endpoints, endpoint_id))
      end)

    {connection_rows, page}
  end

  defp incoming_page(object_id, predicate, subject_kind, after_cursor) do
    filters = [predicate: predicate, subject_kind: subject_kind]

    rows =
      Claims.incoming(
        object_id,
        filters ++ [after: after_cursor, limit: @section_cap + 1]
      )

    visible = Enum.take(rows, @section_cap)

    page = %{
      count: Claims.count_incoming(object_id, filters),
      next: if(length(rows) > @section_cap, do: Claims.next_cursor(visible), else: nil)
    }

    {visible, page}
  end

  # A person's subtype row, a work's, an edition's — whichever this entity has.
  # One query, and nil for a kind that has no detail table.
  defp details(%Entity{entity_kind: :person, object_id: id}),
    do: Repo.get(Registry.PersonDetails, id) |> Map.take([:birth_date, :death_date])

  defp details(%Entity{entity_kind: :work, object_id: id}),
    do:
      Repo.get(Registry.WorkDetails, id)
      |> Map.take([:work_kind, :original_language, :first_published_year])

  defp details(%Entity{entity_kind: :edition, object_id: id}),
    do:
      Repo.get(Registry.EditionDetails, id)
      |> Map.take([:work_id, :edition_label, :publication_year, :language_tag])

  defp details(%Entity{}), do: %{}

  defp entity_views([]), do: []

  defp entity_views(ids) do
    by_id =
      Entity
      |> where([e], e.object_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.object_id, Encyclopedia.view(&1)})

    Enum.map(ids, &Map.fetch!(by_id, &1))
  end

  defp content_views([]), do: []

  defp content_views(ids) do
    by_id =
      Repo.all(
        from c in ContentItem,
          join: r in ContentRevision,
          on: r.content_id == c.object_id and r.is_current,
          where: c.object_id in ^ids and r.lifecycle_state == :active,
          select: %{
            object_id: c.object_id,
            kind: c.content_kind,
            source_id: c.source_id,
            headword: r.headword,
            body: r.body,
            body_format: r.body_format,
            url: r.canonical_url,
            year: r.year
          }
      )
      |> Map.new(&{&1.object_id, &1})

    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  # A definition is only half a row on a person's page: the reader wants the
  # *word* it defines and the *edition* it was printed in, which is two more
  # predicates off the same content item. One query each, over the whole
  # section rather than per definition.
  defp definition_views([]), do: []

  defp definition_views(ids) do
    defines = targets(ids, "defines")
    published = targets(ids, "published_in")

    words = words_for(Map.values(defines))
    editions = Map.new(entity_views(Map.values(published)), &{&1.object_id, &1})

    ids
    |> content_views()
    |> Enum.map(fn content ->
      content
      |> Map.put(:defines, Map.get(words, Map.get(defines, content.object_id)))
      |> Map.put(:published_in, Map.get(editions, Map.get(published, content.object_id)))
      |> Map.put(:summary, excerpt(content.body))
    end)
  end

  defp excerpt(nil), do: nil

  defp excerpt(body) do
    body
    |> plain_text()
    |> truncate_excerpt()
  end

  # Definition bodies are preserved verbatim in `content_revisions`; this is a
  # presentation-only projection for dense entity pages. It handles the small
  # Markdown vocabulary found in source definitions without allowing markup,
  # long one-paragraph prose, or verse line breaks to turn one list row into a
  # miniature document.
  defp plain_text(body) do
    body
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^\s{0,3}(?:\#{1,6}|>|[-+*]|\d+\.)\s+/mu, "")
    |> String.replace(~r/[`*_~]+/u, "")
    |> String.replace(~r/<[^>]+>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate_excerpt(text) do
    graphemes = String.graphemes(text)

    if length(graphemes) <= @summary_limit do
      text
    else
      candidate = graphemes |> Enum.take(@summary_limit) |> Enum.join()

      candidate =
        case Regex.run(~r/^(.*)\s+\S*$/u, candidate, capture: :all_but_first) do
          [at_boundary] when at_boundary != "" -> at_boundary
          _ -> candidate
        end

      String.trim_trailing(candidate) <> "…"
    end
  end

  defp targets(subject_ids, predicate) do
    Repo.all(
      from r in Claims.AssertionRevision,
        join: p in assoc(r, :predicate),
        where: r.subject_object_id in ^subject_ids and r.is_current,
        where: r.lifecycle_state == :active and p.key == ^predicate,
        select: {r.subject_object_id, r.object_object_id}
    )
    |> Map.new()
  end

  # `defines` names a lexeme *or* a source sense (§C allows both), so a sense
  # target resolves to the word it is a meaning of — the reader wants the word
  # either way.
  defp words_for([]), do: %{}

  defp words_for(ids) do
    # Two bounded primary-key lookups. An OR across word and sense targets scanned the
    # entire lexicon, and coalesce lost the direct word when both a word and
    # one of its senses were requested together.
    words =
      Repo.all(
        from l in Lexeme,
          where: l.object_id in ^ids,
          select:
            {l.object_id,
             %{object_id: l.object_id, lemma: l.lemma, slug: l.slug, pos: l.part_of_speech}}
      )

    meanings =
      Repo.all(
        from s in Sense,
          join: l in Lexeme,
          on: l.object_id == s.lexeme_id,
          where: s.object_id in ^ids,
          select:
            {s.object_id,
             %{object_id: l.object_id, lemma: l.lemma, slug: l.slug, pos: l.part_of_speech}}
      )

    Map.new(words ++ meanings)
  end

  # An edition's contents: the definitions printed in it, and what each defines.
  defp contents_of(%Entity{entity_kind: :edition}, id, after_cursor),
    do: incoming_page(id, "published_in", "content", after_cursor)

  defp contents_of(%Entity{}, _id, _after_cursor),
    do: {[], %{count: 0, next: nil}}
end
