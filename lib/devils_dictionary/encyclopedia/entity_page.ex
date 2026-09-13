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
  alias DevilsDictionary.Claims.{AssertionRevision, Connection, Visibility}
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Entity, Lexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Display
  alias DevilsDictionary.Sources.{MaterializedOutput, Source, SourceRecord}

  defstruct entity: nil,
            identity: %{state: :active, requested_id: nil, canonical_id: nil, outputs: []},
            details: %{},
            biography: [],
            works: [],
            definitions: [],
            editions: [],
            contents: [],
            meaning_connections: [],
            discovery_appearances: [],
            sources: [],
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
    case Registry.resolve(object_id) do
      nil ->
        nil

      {:merged, canonical_id} ->
        case Repo.get(Entity, canonical_id) do
          nil -> nil
          entity -> assemble(entity, opts, :merged, object_id, [canonical_id])
        end

      {:split, output_ids} ->
        case Repo.get(Entity, object_id) do
          nil -> nil
          entity -> assemble(entity, opts, :split, object_id, output_ids)
        end

      {:cycle, _ids} ->
        nil

      :itself ->
        case Repo.get(Entity, object_id) do
          nil -> nil
          entity -> assemble(entity, opts, :active, object_id, [])
        end
    end
  end

  def build(_, _opts), do: nil

  defp assemble(%Entity{} = entity, opts, identity_state, requested_id, outputs) do
    id = entity.object_id
    entity_details = details(entity)

    {biography, biography_page} =
      incoming_page(id, "about", "content", opts[:biography_after])

    {works, works_page} =
      incoming_page(id, "authored_by", "entity", opts[:works_after])

    {definitions, definitions_page} =
      incoming_page(id, "authored_by", "content", opts[:definitions_after])

    {editions, editions_page} =
      incoming_page(id, "edition_of", "entity", opts[:editions_after])

    {contents, contents_page} = contents_of(entity, id, opts[:contents_after])

    {meaning_connections, meaning_connections_page} =
      meaning_connections(id, opts[:meaning_connections_after])

    {discovery_appearances, discovery_appearances_page} =
      discovery_appearances(id, opts[:discovery_appearances_after])

    {connections_in, connections_in_page} =
      other_connections(:incoming, id, opts[:connections_in_after])

    {connections_out, connections_out_page} =
      other_connections(:outgoing, id, opts[:connections_out_after], entity_details)

    %__MODULE__{
      entity: Encyclopedia.view(entity),
      identity: %{
        state: identity_state,
        requested_id: requested_id,
        canonical_id: entity.object_id,
        outputs: entity_views(outputs)
      },
      details: entity_details,
      biography: content_views(Enum.map(biography, & &1.subject_object_id)),
      works: entity_views(Enum.map(works, & &1.subject_object_id)),
      definitions: definition_views(Enum.map(definitions, & &1.subject_object_id)),
      editions: entity_views(Enum.map(editions, & &1.subject_object_id)),
      contents: definition_views(Enum.map(contents, & &1.subject_object_id)),
      meaning_connections: meaning_connections,
      discovery_appearances: discovery_appearances,
      sources: source_views(id),
      connections: %{incoming: connections_in, outgoing: connections_out},
      pagination: %{
        biography: biography_page,
        works: works_page,
        definitions: definitions_page,
        editions: editions_page,
        contents: contents_page,
        meaning_connections: meaning_connections_page,
        discovery_appearances: discovery_appearances_page,
        connections_in: connections_in_page,
        connections_out: connections_out_page
      }
    }
  end

  defp other_connections(direction, object_id, after_cursor, details \\ %{}) do
    # The named sections above are all reverse-role sections: biography,
    # authored works/definitions, editions, and edition contents are incoming
    # claims. Suppressing the same predicates while walking *out* erased the
    # only visible work -> author and edition -> work paths. Outgoing role
    # claims are not duplicated anywhere else on this page, so they belong in
    # the connection section.
    filters =
      case direction do
        :incoming ->
          [exclude_predicates: @presented_predicates]

        :outgoing ->
          exclusions =
            if details[:work_kind] == "artwork",
              do: ["illustrates", "authored_by"],
              else: ["illustrates"]

          [exclude_predicates: exclusions]
      end

    opts = filters ++ [after: after_cursor, limit: @section_cap + 1]

    {visible, page} = semantic_claim_page(direction, object_id, opts)

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

  defp meaning_connections(object_id, after_cursor) do
    {rows, page} =
      semantic_claim_page(:outgoing, object_id,
        predicate: "illustrates",
        after: after_cursor,
        limit: @section_cap + 1
      )

    endpoints = Connection.endpoint_summaries(Enum.map(rows, & &1.object_object_id))
    review_states = Claims.display_review_states(Enum.map(rows, & &1.id))

    views =
      Enum.map(rows, fn row ->
        row
        |> Map.from_struct()
        |> Map.merge(Map.fetch!(endpoints, row.object_object_id))
        |> Map.put(:review_state, Map.fetch!(review_states, row.id))
      end)

    {views, page}
  end

  defp discovery_appearances(object_id, after_cursor) do
    family = Registry.canonical_family(object_id)

    base = discovery_appearance_query(family)

    count =
      base
      |> distinct([_result, _run, mapping, source, _record], [
        mapping.target_object_id,
        source.slug
      ])
      |> select([_result, _run, mapping, source, _record], %{
        target_object_id: mapping.target_object_id,
        provider_slug: source.slug
      })
      |> subquery()
      |> Repo.aggregate(:count)

    all_rows =
      base
      |> after_discovery_appearance(after_cursor)
      |> distinct([_result, _run, mapping, source, _record], [
        mapping.target_object_id,
        source.slug
      ])
      |> order_by([_result, run, mapping, source, _record],
        asc: mapping.target_object_id,
        asc: source.slug,
        desc: run.completed_at,
        desc: run.id
      )
      |> limit(^(@section_cap + 1))
      |> select([_result, _run, mapping, source, _record], %{
        target_object_id: mapping.target_object_id,
        provider: source.name,
        provider_slug: source.slug,
        term: mapping.parameters["term"]
      })
      |> Repo.all()

    rows = Enum.take(all_rows, @section_cap)

    endpoints = Connection.endpoint_summaries(Enum.map(rows, & &1.target_object_id))

    views =
      Enum.map(rows, fn row ->
        Map.merge(row, Map.fetch!(endpoints, row.target_object_id))
      end)

    next =
      if length(all_rows) > @section_cap do
        row = List.last(rows)
        "#{row.target_object_id}:#{row.provider_slug}"
      end

    {views, %{count: count, next: next}}
  end

  defp discovery_appearance_query(family) do
    from result in Result,
      join: run in Run,
      on: run.id == result.run_id,
      join: mapping in Mapping,
      on: mapping.id == run.mapping_id,
      join: source in Source,
      on: source.id == mapping.source_id,
      left_join: record in SourceRecord,
      on: record.id == result.source_record_id,
      where:
        result.object_id in ^family and result.display_allowed and run.display_allowed and
          run.status == :succeeded and mapping.enabled and source.active and
          (is_nil(record.id) or record.display_allowed)
  end

  defp after_discovery_appearance(query, nil), do: query

  defp after_discovery_appearance(query, cursor) when is_binary(cursor) do
    with [target, source_slug] <- String.split(cursor, ":", parts: 2),
         {target_object_id, ""} when target_object_id > 0 <- Integer.parse(target),
         true <- source_slug != "" do
      where(
        query,
        [_result, _run, mapping, source, _record],
        mapping.target_object_id > ^target_object_id or
          (mapping.target_object_id == ^target_object_id and source.slug > ^source_slug)
      )
    else
      _ -> query
    end
  end

  defp after_discovery_appearance(query, _cursor), do: query

  defp source_views(object_id) do
    family = Registry.canonical_family(object_id)

    Repo.all(
      from output in MaterializedOutput,
        join: record in assoc(output, :source_record),
        join: source in assoc(record, :source),
        where:
          output.output_object_id in ^family and is_nil(output.retired_at) and
            record.display_allowed and source.active,
        distinct: [source.slug, record.url],
        order_by: [asc: source.slug, asc: record.url],
        select: %{
          slug: source.slug,
          name: source.name,
          attribution: source.attribution,
          url: record.url
        }
    )
  end

  defp incoming_page(object_id, predicate, subject_kind, after_cursor) do
    semantic_claim_page(:incoming, object_id,
      predicate: predicate,
      subject_kind: subject_kind,
      after: after_cursor,
      limit: @section_cap + 1
    )
  end

  defp semantic_claim_page(direction, object_id, opts) do
    family = Registry.canonical_family(object_id)

    query =
      case direction do
        :incoming ->
          where(
            AssertionRevision,
            [revision],
            revision.object_object_id in ^family and revision.is_current and
              revision.lifecycle_state == :active
          )

        :outgoing ->
          where(
            AssertionRevision,
            [revision],
            revision.subject_object_id in ^family and revision.is_current and
              revision.lifecycle_state == :active
          )
      end

    grouped =
      query
      |> join(:inner, [revision], predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id,
        as: :semantic_predicate
      )
      |> semantic_predicate(opts[:predicate])
      |> semantic_exclusions(opts[:exclude_predicates])
      |> semantic_subject_kind(opts[:subject_kind])
      |> Claims.visible(:public)
      |> group_by([revision], [
        revision.subject_object_id,
        revision.predicate_id,
        revision.object_object_id,
        revision.context_object_id,
        revision.jurisdiction_entity_id,
        revision.language_tag,
        revision.valid_from,
        revision.valid_to
      ])
      |> select([revision], %{id: min(revision.id)})

    count = grouped |> subquery() |> Repo.aggregate(:count)

    grouped =
      case opts[:after] do
        id when is_integer(id) -> having(grouped, [revision], min(revision.id) > ^id)
        _ -> grouped
      end

    representative_ids =
      grouped
      |> order_by([revision], asc: min(revision.id))
      |> limit(^(opts[:limit] || @section_cap + 1))
      |> Repo.all()
      |> Enum.map(& &1.id)

    by_id =
      Repo.all(
        from revision in AssertionRevision,
          where: revision.id in ^representative_ids,
          preload: :predicate
      )
      |> Map.new(&{&1.id, &1})

    rows = representative_ids |> Enum.map(&Map.fetch!(by_id, &1)) |> Enum.take(@section_cap)

    {rows,
     %{
       count: count,
       next:
         if(length(representative_ids) > @section_cap,
           do: List.last(rows).id,
           else: nil
         )
     }}
  end

  defp semantic_predicate(query, nil), do: query

  defp semantic_predicate(query, key),
    do: where(query, [semantic_predicate: predicate], predicate.key == ^key)

  defp semantic_exclusions(query, nil), do: query
  defp semantic_exclusions(query, []), do: query

  defp semantic_exclusions(query, keys),
    do: where(query, [semantic_predicate: predicate], predicate.key not in ^keys)

  defp semantic_subject_kind(query, nil), do: query

  defp semantic_subject_kind(query, kind),
    do: where(query, [revision], revision.subject_kind == ^kind)

  # A person's subtype row, a work's, an edition's — whichever this entity has.
  # One query, and nil for a kind that has no detail table.
  defp details(%Entity{entity_kind: :person, object_id: id}),
    do: detail_fields(Repo.get(Registry.PersonDetails, id), [:birth_date, :death_date])

  defp details(%Entity{entity_kind: :work, object_id: id}),
    do:
      detail_fields(Repo.get(Registry.WorkDetails, id), [
        :work_kind,
        :original_language,
        :first_published_year
      ])

  defp details(%Entity{entity_kind: :edition, object_id: id}),
    do:
      detail_fields(Repo.get(Registry.EditionDetails, id), [
        :work_id,
        :edition_label,
        :publication_year,
        :language_tag
      ])

  defp details(%Entity{}), do: %{}

  defp detail_fields(nil, _fields), do: %{}
  defp detail_fields(details, fields), do: Map.take(details, fields)

  defp entity_views([]), do: []

  defp entity_views(ids) do
    canonical = Registry.canonical_ids(ids)
    canonical_ids = Enum.map(ids, &Map.fetch!(canonical, &1))

    entities =
      Entity
      |> where([e], e.object_id in ^canonical_ids)
      |> Repo.all()

    image_evidence = Display.preload(entities)
    by_id = Map.new(entities, &{&1.object_id, Encyclopedia.view(&1, image_evidence)})

    canonical_ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  defp content_views([]), do: []

  defp content_views(ids) do
    canonical = Registry.canonical_ids(ids)
    canonical_ids = Enum.map(ids, &Map.fetch!(canonical, &1))

    by_id =
      Repo.all(
        from c in ContentItem,
          join: r in ContentRevision,
          on: r.content_id == c.object_id and r.is_current,
          where: c.object_id in ^canonical_ids and r.lifecycle_state == :active,
          select: %{
            object_id: c.object_id,
            kind: c.content_kind,
            source_id: c.source_id,
            headword: r.headword,
            body: r.body,
            body_format: r.body_format,
            url: r.canonical_url,
            year: r.year,
            rights_metadata: r.rights_metadata
          }
      )
      |> Map.new(&{&1.object_id, &1})

    canonical_ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Visibility.restrict_content/1)
  end

  # A definition is only half a row on a person's page: the reader wants the
  # *word* it defines and the *edition* it was printed in, which is two more
  # predicates off the same content item. One query each, over the whole
  # section rather than per definition.
  defp definition_views([]), do: []

  defp definition_views(ids) do
    canonical = Registry.canonical_ids(ids)
    ids = Enum.map(ids, &Map.fetch!(canonical, &1))
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
    Claims.AssertionRevision
    |> join(:inner, [r], p in assoc(r, :predicate))
    |> where([r, p], r.subject_object_id in ^subject_ids and r.is_current)
    |> where([r, p], r.lifecycle_state == :active and p.key == ^predicate)
    |> Claims.visible(:public)
    |> select([r], {r.subject_object_id, r.object_object_id})
    |> Repo.all()
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
