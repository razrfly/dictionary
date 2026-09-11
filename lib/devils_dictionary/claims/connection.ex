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
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    Lexeme,
    Sense,
    SenseRevision
  }

  alias DevilsDictionary.Repo

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
         true <- visible_revision?(Claims.current_revision(assertion_id), opts),
         %AssertionRevision{} = revision <- revision_for(assertion_id, opts[:revision]),
         true <- visible_revision?(revision, opts) do
      evidence = Claims.evidence(revision.id)
      {supports, contradicts} = Enum.split_with(evidence, &(&1.evidence_role != :contradicts))

      %__MODULE__{
        assertion: assertion,
        revision: revision,
        predicate: Repo.preload(revision, :predicate).predicate,
        subject: endpoint(revision.subject_object_id),
        object: endpoint(revision.object_object_id),
        context: revision.context_object_id && endpoint(revision.context_object_id),
        evidence: supports,
        counterevidence: contradicts,
        review: Claims.display_review_state(revision.id),
        reviews: Claims.reviews(revision.id) |> Repo.preload(:reviewer_actor),
        score: Claims.score(revision.id),
        history: Enum.filter(Claims.history(assertion_id), &visible_revision?(&1, opts)),
        claimant: actor(assertion.origin_actor_id),
        submitted_by: actor(assertion.submitted_by_actor_id)
      }
    else
      _ -> nil
    end
  end

  defp visible_revision?(nil, _opts), do: false

  defp visible_revision?(revision, opts) do
    opts[:visibility] == :internal or Claims.publicly_visible_revision?(revision)
  end

  defp revision_for(assertion_id, nil), do: Claims.current_revision(assertion_id)

  defp revision_for(assertion_id, number) do
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
    canonical_id = Registry.canonical_id(object_id)

    result =
      lexeme(canonical_id) || sense(canonical_id) || entity(canonical_id) || content(canonical_id) ||
        %{kind: :unknown, object_id: canonical_id, label: "##{canonical_id}", path: nil}

    if canonical_id == object_id, do: result, else: Map.put(result, :merged_from, object_id)
  end

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

  defp lexeme(id) do
    case Repo.get(Lexeme, id) do
      nil ->
        nil

      l ->
        %{
          kind: :lexeme,
          object_id: id,
          label: l.lemma,
          detail: l.part_of_speech,
          path: "/words/#{id}/#{l.slug}"
        }
    end
  end

  # A sense is shown as its word plus its gloss: "the meaning of *bank* that
  # says *Money; profit.*" is what a reader can act on, where a bare object id
  # is not.
  defp sense(id) do
    Repo.one(
      from s in Sense,
        join: r in SenseRevision,
        on: r.sense_id == s.object_id and r.is_current,
        join: l in Lexeme,
        on: l.object_id == s.lexeme_id,
        join: src in assoc(s, :source),
        where: s.object_id == ^id,
        select: %{
          kind: :sense,
          object_id: s.object_id,
          label: l.lemma,
          detail: r.gloss,
          source: src.name,
          path: fragment("'/words/' || ? || '/' || ?", l.object_id, l.slug)
        }
    )
  end

  defp entity(id) do
    case Repo.get(Entity, id) do
      nil ->
        nil

      e ->
        view = Encyclopedia.view(e)

        %{
          kind: :entity,
          object_id: id,
          label: view.label || "##{id}",
          detail: view.description || to_string(e.entity_kind),
          entity_kind: e.entity_kind,
          qid: view.qid,
          path: "/entities/#{id}/#{slugify(view.label)}"
        }
    end
  end

  defp content(id) do
    case Repo.one(
           from c in ContentItem,
             join: r in ContentRevision,
             on: r.content_id == c.object_id and r.is_current,
             left_join: src in assoc(c, :source),
             where: c.object_id == ^id,
             select: %{
               kind: :content,
               object_id: c.object_id,
               content_kind: c.content_kind,
               label: r.headword,
               detail: r.body,
               source: src.name,
               path: nil,
               rights_metadata: r.rights_metadata
             }
         ) do
      nil ->
        nil

      endpoint ->
        endpoint
        |> Map.put(
          :label,
          Visibility.content_label(
            endpoint.label,
            endpoint.detail,
            endpoint.object_id,
            endpoint.rights_metadata
          )
        )
        |> Map.put(:body, endpoint.detail)
        |> Visibility.restrict_content()
        |> Map.put(:detail, nil)
        |> then(fn restricted ->
          if restricted.display_restricted?,
            do: Map.put(restricted, :detail, "Text withheld by rights metadata"),
            else: Map.put(restricted, :detail, endpoint.detail)
        end)
    end
  end

  defp actor(nil), do: nil
  defp actor(id), do: Repo.get(DevilsDictionary.Sources.Actor, id)

  @doc "A readable URL segment for a label. Cosmetic, never identity."
  def slugify(nil), do: "-"
  def slugify(label), do: Slug.slugify(label) || "-"
end
