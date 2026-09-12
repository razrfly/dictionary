defmodule DevilsDictionary.Claims.Connection do
  @moduledoc """
  One claim, as the connection-detail page shows it — #74 §F's fifth wireframe.

      CONNECTION DETAIL
      Illustrative meme [108] — illustrates → concept [107]
      Claim #… · revision 2
      Original claimant: curator A
      Submitted by: account B
      Context: …                  Review: Disputed
      Rationale: …
      Evidence: [source record/revision] [passage locator]
      Counterevidence: …
      [Open meme] [Open concept] [History] [Challenge]

  The line under it — *"the same claim revision appears from either endpoint"* —
  is not something this module has to arrange. There is one directional row and
  the inverse is derived for display, so the two ends cannot disagree; #73 is
  explicit that an independently editable mirror edge is how the two halves of
  one fact come apart. This just labels the row correctly from whichever side
  the reader arrived at.

  Everything the page shows about editorial state is **derived**: the review
  decision from the append-only `assertion_reviews`, the score from the votes on
  *this revision*. Neither is a column an importer could write.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Visibility
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision}
  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    ExternalIdentifier,
    Lexeme,
    Object,
    Sense,
    SenseRevision
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  defstruct assertion: nil,
            revision: nil,
            predicate: nil,
            subject: nil,
            object: nil,
            context: nil,
            evidence: [],
            counterevidence: [],
            review: :needs_review,
            reviews: [],
            score: 0,
            history: [],
            claimant: nil,
            submitted_by: nil

  @doc """
  Builds the page for an assertion id, or nil.

  `opts[:revision]` shows a historical revision instead of the current one —
  which is what the History link is for, and the reason the reviews and votes
  are read per revision rather than per claim.
  """
  def build(assertion_id, opts \\ []) do
    with %Assertion{} = assertion <- Repo.get(Assertion, assertion_id),
         %AssertionRevision{} = current <- Claims.current_revision(assertion_id),
         true <- visible_revision?(current, opts),
         %AssertionRevision{} = revision <- revision_for(assertion_id, opts[:revision], current),
         true <- current.id == revision.id or visible_revision?(revision, opts) do
      evidence = Claims.evidence(revision.id)
      {supports, contradicts} = Enum.split_with(evidence, &(&1.evidence_role != :contradicts))
      endpoints = endpoints(endpoint_ids(revision))

      %__MODULE__{
        assertion: assertion,
        revision: revision,
        predicate: Repo.preload(revision, :predicate).predicate,
        subject: Map.get(endpoints, revision.subject_object_id),
        object: Map.get(endpoints, revision.object_object_id),
        context: Map.get(endpoints, revision.context_object_id),
        evidence: supports,
        counterevidence: contradicts,
        review: Claims.display_review_state(revision.id),
        reviews: Claims.reviews(revision.id) |> Repo.preload(:reviewer_actor),
        score: Claims.score(revision.id),
        history: visible_history(assertion_id, opts),
        claimant: actor(assertion.origin_actor_id),
        submitted_by: actor(assertion.submitted_by_actor_id)
      }
    else
      _ -> nil
    end
  end

  defp visible_revision?(revision, opts) do
    opts[:visibility] == :internal or Claims.publicly_visible_revision?(revision)
  end

  defp visible_history(assertion_id, opts) do
    history = Claims.history(assertion_id)

    if opts[:visibility] == :internal do
      history
    else
      visible_ids = Claims.publicly_visible_revision_ids(Enum.map(history, & &1.id))
      Enum.filter(history, &MapSet.member?(visible_ids, &1.id))
    end
  end

  defp revision_for(_assertion_id, nil, current), do: current

  defp revision_for(assertion_id, number, _current) do
    Repo.one(
      from r in AssertionRevision,
        where: r.assertion_id == ^assertion_id and r.revision_number == ^number
    )
  end

  @doc """
  What an endpoint *is*, whichever of the four kinds it turns out to be.

  A page cannot ask "is this a word or a thing" of an assertion — the whole
  point of the registry is that the endpoint is an object and the claim does not
  care. So this asks the database, and returns a shape with a label and a path
  either way.
  """
  def endpoint(nil), do: nil

  def endpoint(object_id) do
    object_id
    |> List.wrap()
    |> endpoints()
    |> Map.get(object_id)
  end

  @doc "Resolves full display projections for many endpoints in one subtype query."
  def endpoints(object_ids) do
    ids = object_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    canonical = Map.new(ids, &{&1, Registry.canonical_id(&1)})
    canonical_ids = canonical |> Map.values() |> Enum.uniq()

    rows = endpoint_rows(canonical_ids)

    Map.new(canonical, fn {original_id, canonical_id} ->
      endpoint =
        rows
        |> Map.get(canonical_id)
        |> endpoint_from_row(canonical_id)

      endpoint =
        if canonical_id == original_id,
          do: endpoint,
          else: Map.put(endpoint, :merged_from, original_id)

      {original_id, endpoint}
    end)
  end

  defp endpoint_ids(revision) do
    [revision.subject_object_id, revision.object_object_id, revision.context_object_id]
  end

  defp endpoint_rows([]), do: %{}

  defp endpoint_rows(ids) do
    Repo.all(
      from object in Object,
        left_join: lexeme in Lexeme,
        on: lexeme.object_id == object.id,
        left_join: sense in Sense,
        on: sense.object_id == object.id,
        left_join: sense_revision in SenseRevision,
        on: sense_revision.sense_id == sense.object_id and sense_revision.is_current,
        left_join: sense_lexeme in Lexeme,
        on: sense_lexeme.object_id == sense.lexeme_id,
        left_join: sense_source in Source,
        on: sense_source.id == sense.source_id,
        left_join: entity in Entity,
        on: entity.object_id == object.id,
        left_join: qid in ExternalIdentifier,
        on:
          qid.object_id == entity.object_id and qid.namespace == "wikidata" and
            qid.status == :verified,
        left_join: content in ContentItem,
        on: content.object_id == object.id,
        left_join: content_revision in ContentRevision,
        on: content_revision.content_id == content.object_id and content_revision.is_current,
        left_join: content_source in Source,
        on: content_source.id == content.source_id,
        where: object.id in ^ids,
        select:
          {object.id,
           %{
             kind: object.kind,
             lexeme: lexeme,
             sense: sense,
             sense_revision: sense_revision,
             sense_lexeme: sense_lexeme,
             sense_source: sense_source,
             entity: entity,
             qid: qid.external_id,
             content: content,
             content_revision: content_revision,
             content_source: content_source
           }}
    )
    |> Map.new()
  end

  defp endpoint_from_row(%{kind: :lexeme, lexeme: lexeme}, id) when not is_nil(lexeme) do
    %{
      kind: :lexeme,
      object_id: id,
      label: lexeme.lemma,
      detail: lexeme.part_of_speech,
      path: "/words/#{id}/#{lexeme.slug}"
    }
  end

  defp endpoint_from_row(
         %{
           kind: :sense,
           sense_revision: revision,
           sense_lexeme: lexeme,
           sense_source: source
         },
         id
       )
       when not is_nil(revision) and not is_nil(lexeme) do
    %{
      kind: :sense,
      object_id: id,
      label: lexeme.lemma,
      detail: revision.gloss,
      source: source && source.name,
      path: "/words/#{lexeme.object_id}/#{lexeme.slug}"
    }
  end

  defp endpoint_from_row(%{kind: :entity, entity: entity, qid: qid}, id)
       when not is_nil(entity) do
    %{
      kind: :entity,
      object_id: id,
      label: entity.preferred_label || "##{id}",
      detail: entity.description || to_string(entity.entity_kind),
      entity_kind: entity.entity_kind,
      qid: qid,
      path: "/entities/#{id}/#{slugify(entity.preferred_label)}"
    }
  end

  defp endpoint_from_row(
         %{kind: :content, content: content, content_revision: revision, content_source: source},
         id
       )
       when not is_nil(content) and not is_nil(revision) do
    endpoint = %{
      kind: :content,
      object_id: id,
      content_kind: content.content_kind,
      label: revision.headword,
      detail: revision.body,
      body: revision.body,
      source: source && source.name,
      path: nil,
      rights_metadata: revision.rights_metadata,
      lifecycle_state: revision.lifecycle_state
    }

    endpoint
    |> Map.put(
      :label,
      Visibility.content_label(endpoint.label, endpoint.body, id, endpoint.rights_metadata)
    )
    |> Visibility.restrict_content()
    |> Map.put(:detail, nil)
    |> then(fn restricted ->
      if restricted.display_restricted?,
        do: Map.put(restricted, :detail, "Text withheld by rights metadata"),
        else: Map.put(restricted, :detail, endpoint.body)
    end)
  end

  defp endpoint_from_row(_row, id),
    do: %{kind: :unknown, object_id: id, label: "##{id}", path: nil}

  @doc """
  Resolves labels and canonical paths for many endpoints in a bounded set of queries.

  The returned map is keyed by object id. Unknown ids keep the same fallback
  label and nil path as `endpoint/1`.
  """
  def endpoint_summaries(object_ids) do
    ids = object_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    canonical = Map.new(ids, &{&1, Registry.canonical_id(&1)})
    canonical_ids = canonical |> Map.values() |> Enum.uniq()

    summaries =
      canonical_ids
      |> Map.new(&{&1, %{label: "##{&1}", path: nil}})
      |> Map.merge(content_summaries(canonical_ids))
      |> Map.merge(entity_summaries(canonical_ids))
      |> Map.merge(sense_summaries(canonical_ids))
      |> Map.merge(lexeme_summaries(canonical_ids))

    Map.new(canonical, fn {original_id, canonical_id} ->
      {original_id, Map.fetch!(summaries, canonical_id)}
    end)
  end

  defp lexeme_summaries([]), do: %{}

  defp lexeme_summaries(ids) do
    Repo.all(
      from l in Lexeme,
        where: l.object_id in ^ids,
        select:
          {l.object_id,
           %{
             label: l.lemma,
             path: fragment("'/words/' || ? || '/' || ?", l.object_id, l.slug)
           }}
    )
    |> Map.new()
  end

  defp sense_summaries([]), do: %{}

  defp sense_summaries(ids) do
    Repo.all(
      from s in Sense,
        join: r in SenseRevision,
        on: r.sense_id == s.object_id and r.is_current,
        join: l in Lexeme,
        on: l.object_id == s.lexeme_id,
        where: s.object_id in ^ids,
        select:
          {s.object_id,
           %{
             label: l.lemma,
             path: fragment("'/words/' || ? || '/' || ?", l.object_id, l.slug)
           }}
    )
    |> Map.new()
  end

  defp entity_summaries([]), do: %{}

  defp entity_summaries(ids) do
    Entity
    |> where([e], e.object_id in ^ids)
    |> select([e], {e.object_id, e.preferred_label})
    |> Repo.all()
    |> Map.new(fn {id, label} ->
      %{label: label || "##{id}", path: "/entities/#{id}/#{slugify(label)}"}
      |> then(&{id, &1})
    end)
  end

  defp content_summaries([]), do: %{}

  defp content_summaries(ids) do
    Repo.all(
      from c in ContentItem,
        join: r in ContentRevision,
        on: r.content_id == c.object_id and r.is_current,
        where: c.object_id in ^ids,
        select:
          {c.object_id,
           %{
             headword: r.headword,
             body: r.body,
             rights_metadata: r.rights_metadata
           }}
    )
    |> Map.new(fn {id, revision} ->
      {id,
       %{
         label:
           Visibility.content_label(
             revision.headword,
             revision.body,
             id,
             revision.rights_metadata
           ),
         path: nil
       }}
    end)
  end

  defp actor(nil), do: nil
  defp actor(id), do: Repo.get(DevilsDictionary.Sources.Actor, id)

  @doc "A readable URL segment for a label. Cosmetic, never identity."
  def slugify(nil), do: "-"
  def slugify(label), do: Slug.slugify(label) || "-"
end
