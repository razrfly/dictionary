defmodule DevilsDictionary.Claims.AssertionVote do
  @moduledoc """
  Relevance, and only relevance.

  A vote says "this example is a good one", not "this is true" and not "this is
  well-sourced". #73 lists four dimensions that must not collapse into one
  score: editorial review state, source support, matching confidence and
  relevance votes. This is the fourth, alone.

  The target is an `assertion_revisions` row, not an assertion — so changing
  what a claim says does not carry its old votes forward. The community sketch
  had `votable_type`/`votable_id` with no foreign key at all, which permitted
  votes on rows that did not exist.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Sources.Actor

  schema "assertion_votes" do
    belongs_to :assertion_revision, AssertionRevision
    field :review_context_id, :id
    belongs_to :actor, Actor
    field :value, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:assertion_revision_id, :review_context_id, :actor_id, :value])
    |> validate_required([:assertion_revision_id, :actor_id, :value])
    |> validate_inclusion(:value, [-1, 1], message: "a vote is +1 or -1")
    |> unique_constraint([:assertion_revision_id, :actor_id])
    |> foreign_key_constraint(:review_context_id,
      name: :assertion_votes_context_fkey,
      message: "belongs to a different assertion revision"
    )
  end
end
