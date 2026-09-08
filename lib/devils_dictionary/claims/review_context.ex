defmodule DevilsDictionary.Claims.ReviewContext do
  @moduledoc """
  An immutable record of the endpoint revisions a reviewer actually saw.

  Without it, "accepted" is a claim about text that can change afterwards. A
  curator approves *"Money; profit."* as an illustration of a concept; the
  source rewords the gloss; the approval silently now applies to different
  words. #74 requires the manifest of what was displayed, and requires that a
  later revision **must not rewrite it**.

  `assertion_reviews` and `assertion_votes` reference this through a composite
  foreign key on `(assertion_revision_id, id)`, so "the context belongs to the
  revision being reviewed" is a foreign key rather than an application check.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.{AssertionRevision, ReviewContextItem}

  schema "review_contexts" do
    belongs_to :assertion_revision, AssertionRevision
    has_many :items, ReviewContextItem, foreign_key: :context_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(context, attrs) do
    context
    |> cast(attrs, [:assertion_revision_id])
    |> validate_required([:assertion_revision_id])
  end
end
