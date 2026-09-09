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
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision}
  alias DevilsDictionary.Encyclopedia

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
         %AssertionRevision{} = revision <- revision_for(assertion_id, opts[:revision]) do
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
        review: Claims.review_state(revision.id),
        reviews: Claims.reviews(revision.id),
        score: Claims.score(revision.id),
        history: Claims.history(assertion_id),
        claimant: actor(assertion.origin_actor_id),
        submitted_by: actor(assertion.submitted_by_actor_id)
      }
    else
      _ -> nil
    end
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
    lexeme(object_id) || sense(object_id) || entity(object_id) || content(object_id) ||
      %{kind: :unknown, object_id: object_id, label: "##{object_id}", path: nil}
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
    Repo.one(
      from c in ContentItem,
        join: r in ContentRevision,
        on: r.content_id == c.object_id and r.is_current,
        left_join: src in assoc(c, :source),
        where: c.object_id == ^id,
        select: %{
          kind: :content,
          object_id: c.object_id,
          content_kind: c.content_kind,
          label: coalesce(r.headword, fragment("left(?, 80)", r.body)),
          detail: r.body,
          source: src.name,
          path: nil
        }
    )
  end

  defp actor(nil), do: nil
  defp actor(id), do: Repo.get(DevilsDictionary.Sources.Actor, id)

  @doc "A readable URL segment for a label. Cosmetic, never identity."
  def slugify(nil), do: "-"
  def slugify(label), do: Slug.slugify(label) || "-"
end
