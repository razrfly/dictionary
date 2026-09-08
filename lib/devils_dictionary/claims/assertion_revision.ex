defmodule DevilsDictionary.Claims.AssertionRevision do
  @moduledoc """
  What a claim says, at one point in its history: two endpoints, a predicate,
  and the context that makes it mean something specific.

  ## Currentness is not lifecycle

  `is_current` designates the revision the reader sees. `lifecycle_state` says
  what that revision asserts — and the current revision may perfectly well say
  `withdrawn`, which is how "this claim has been retracted" is expressed without
  deleting the history that shows it was once made. #74 forbids overloading one
  value with both.

  Exactly one revision per assertion is current. A partial unique index proves
  at most one; a deferred constraint trigger proves at least one at commit. The
  write path takes `SELECT … FOR UPDATE` on the assertion row **first** — Gate 0
  showed that without it, an adversarial statement ordering loses a write to a
  duplicate-key error.

  Gate 0 measured this shape against an explicit `current_revision_id` pointer
  and against `DISTINCT ON` over history, on the full 1.16 M-assertion corpus:
  0.256 ms p95 against 2.576 ms and 1.670 ms, touching 41 buffers against 7,957.

  ## Endpoint kinds

  The four `*_kind` / `*_subkind` columns are filled by a `BEFORE INSERT OR
  UPDATE` trigger from the endpoints themselves, and carry a composite foreign
  key into `predicate_endpoint_rules`. They are not settable and not cast — a
  writer that could set them could lie about them.

  ## Confidence

  Nullable, constrained to `[0,1]`, and **heuristic**. The audit is right that
  0.85 is not an 85% probability of anything; a source's own weight is a
  different quantity and stays in `metadata`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.{Assertion, Predicate}
  alias DevilsDictionary.Registry.{Entity, Object}

  @states [:active, :withdrawn, :superseded, :rejected]

  schema "assertion_revisions" do
    belongs_to :assertion, Assertion
    field :revision_number, :integer
    belongs_to :subject_object, Object
    belongs_to :predicate, Predicate
    belongs_to :object_object, Object

    # Written by the database trigger, never cast. Read-only here.
    field :subject_kind, :string
    field :subject_subkind, :string
    field :object_kind, :string
    field :object_subkind, :string

    field :rationale, :string
    field :valid_from, :utc_datetime_usec
    field :valid_to, :utc_datetime_usec
    field :language_tag, :string
    belongs_to :jurisdiction_entity, Entity, references: :object_id
    belongs_to :context_object, Object
    field :method, :string
    field :confidence, :float
    field :lifecycle_state, Ecto.Enum, values: @states, default: :active
    field :is_current, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states

  @castable ~w(assertion_id revision_number subject_object_id predicate_id object_object_id
               rationale valid_from valid_to language_tag jurisdiction_entity_id
               context_object_id method confidence lifecycle_state is_current metadata)a

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @castable)
    |> validate_required([
      :assertion_id,
      :revision_number,
      :subject_object_id,
      :predicate_id,
      :object_object_id
    ])
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_interval()
    |> unique_constraint([:assertion_id, :revision_number])
    |> unique_constraint(:is_current, name: :assertion_revisions_one_current_index)
    |> check_constraint(:predicate_id,
      name: :assertion_revisions_endpoints,
      message: "does not allow these endpoint kinds"
    )
    |> foreign_key_constraint(:predicate_id,
      name: :assertion_revisions_endpoints,
      message: "does not allow these endpoint kinds"
    )
  end

  defp validate_interval(changeset) do
    from = get_field(changeset, :valid_from)
    to = get_field(changeset, :valid_to)

    if from && to && DateTime.compare(from, to) == :gt do
      add_error(changeset, :valid_to, "is before valid_from")
    else
      changeset
    end
  end
end
