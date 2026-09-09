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
    * **connections** — everything else, both directions, so nothing a curator
      asserted is invisible merely because this page did not anticipate it

  That last one matters. A page that renders only the predicates it knows about
  is a page that silently hides a claim, and #73 is explicit that a claim must
  appear from either endpoint. The named sections are presentation; the
  connections list is the guarantee.

  ## Reads are public reads

  Everything here goes through `Claims.incoming/2` and `outgoing/2`, so a claim
  a reviewer rejected is absent from the sections *and* from the counts. The
  review queue is a different reader and says so.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
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
            counts: %{}

  @section_cap 50

  @doc """
  Builds the page for an object id, or nil when it is not an entity.

  Nil rather than a raise: `/entities/999/x` is a page that says so, the same
  way `/define/zzzz` is.
  """
  def build(object_id) when is_integer(object_id) do
    case Repo.get(Entity, object_id) do
      nil -> nil
      entity -> assemble(entity)
    end
  end

  def build(_), do: nil

  defp assemble(%Entity{} = entity) do
    id = entity.object_id

    biography = Encyclopedia.content_about(id, limit: @section_cap)
    authored = Claims.incoming(id, predicate: "authored_by", limit: @section_cap)
    editions = Claims.incoming(id, predicate: "edition_of", limit: @section_cap)

    {work_ids, content_ids} = split_authored(authored)

    %__MODULE__{
      entity: Encyclopedia.view(entity),
      details: details(entity),
      biography: content_views(Enum.map(biography, & &1.subject_object_id)),
      works: entity_views(work_ids),
      definitions: definition_views(content_ids),
      editions: entity_views(Enum.map(editions, & &1.subject_object_id)),
      contents: contents_of(entity, id),
      connections: %{
        incoming: Claims.incoming(id, limit: @section_cap),
        outgoing: Claims.outgoing(id, limit: @section_cap)
      },
      counts: %{
        incoming: Claims.count_incoming(id),
        outgoing: Claims.count_outgoing(id)
      }
    }
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

  # `authored_by` reaches this person from two kinds of subject: a work entity
  # and a piece of content. They are different sections on the page and one
  # query in the database.
  defp split_authored(revisions) do
    Enum.reduce(revisions, {[], []}, fn revision, {works, contents} ->
      case revision.subject_kind do
        "entity" -> {[revision.subject_object_id | works], contents}
        "content" -> {works, [revision.subject_object_id | contents]}
        _ -> {works, contents}
      end
    end)
  end

  defp entity_views([]), do: []

  defp entity_views(ids) do
    Entity
    |> where([e], e.object_id in ^ids)
    |> order_by([e], e.preferred_label)
    |> Repo.all()
    |> Enum.map(&Encyclopedia.view/1)
  end

  defp content_views([]), do: []

  defp content_views(ids) do
    Repo.all(
      from c in ContentItem,
        join: r in ContentRevision,
        on: r.content_id == c.object_id and r.is_current,
        where: c.object_id in ^ids and r.lifecycle_state == :active,
        order_by: [asc: r.position, asc: c.object_id],
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
    end)
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
  defp contents_of(%Entity{entity_kind: :edition}, id) do
    id
    |> Claims.incoming(predicate: "published_in", limit: @section_cap)
    |> Enum.map(& &1.subject_object_id)
    |> definition_views()
  end

  defp contents_of(%Entity{}, _id), do: []
end
