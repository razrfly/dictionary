defmodule DevilsDictionary.Claims.AssertionReview do
  @moduledoc """
  An editorial decision about one revision of one claim. Append-only.

  Nothing updates a review; a change of mind is another row, and the effective
  state is derived from the sequence. That is what makes an importer unable to
  undo a human — the audit found a `rejected` link returning to `auto` on the
  next run of its linking rung, because the decision lived in a column the
  importer also wrote.

  Editorial review and source support are separate dimensions. A source
  withdrawing its record does not reject the claim, and a reviewer rejecting a
  claim does not un-publish the source.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Sources.Actor

  @decisions [:accepted, :disputed, :rejected, :withdrawn, :needs_review]

  schema "assertion_reviews" do
    belongs_to :assertion_revision, AssertionRevision
    field :review_context_id, :id
    belongs_to :reviewer_actor, Actor
    field :decision, Ecto.Enum, values: @decisions
    field :reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def decisions, do: @decisions

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :assertion_revision_id,
      :review_context_id,
      :reviewer_actor_id,
      :decision,
      :reason
    ])
    |> validate_required([:assertion_revision_id, :decision])
    |> foreign_key_constraint(:review_context_id,
      name: :assertion_reviews_context_fkey,
      message: "belongs to a different assertion revision"
    )
  end
end
