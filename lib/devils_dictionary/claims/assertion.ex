defmodule DevilsDictionary.Claims.Assertion do
  @moduledoc """
  A claim's stable identity. What it says lives in `assertion_revisions`.

  The split exists so that changing what a claim asserts cannot inherit the
  approval of what it used to assert. A review and a vote both cite a
  *revision*, not this row.

  `origin_key` is the source's own identifier for the claim, where it has one,
  and `(source_id, origin_key)` is unique — which is what makes re-importing
  idempotent instead of duplicating. #74: derive it from a stable source-native
  identifier where available, and where not, specify and test an adapter's
  matching policy.

  Attribution is three separate questions and MVP-0 could express none of them:
  `origin_actor_id` is who made the claim (possibly unknown, possibly long
  dead), `submitted_by_actor_id` is the account or process that put it here.
  A curator quoting someone else's classification is not making it their own.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Sources.{Actor, Source}

  schema "assertions" do
    belongs_to :source, Source
    field :origin_key, :string
    belongs_to :origin_actor, Actor
    belongs_to :submitted_by_actor, Actor

    has_many :revisions, AssertionRevision

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(assertion, attrs) do
    assertion
    |> cast(attrs, [:source_id, :origin_key, :origin_actor_id, :submitted_by_actor_id])
    |> unique_constraint([:source_id, :origin_key], name: :assertions_origin_index)
  end
end
