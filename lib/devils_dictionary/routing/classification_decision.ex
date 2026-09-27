defmodule DevilsDictionary.Routing.ClassificationDecision do
  @moduledoc """
  A versioned classification of one entity: the evaluator's result, or a human
  reviewer's override of it.

  Rows are immutable apart from losing currency, and history is kept by
  superseding. There is no foreign key between a decision and any path: a new
  decision can put an entity into review, but it cannot move an address.

  A family is selected only when `status` is `mapped`. Review, excluded source
  pages and identity review keep their candidate families visible and select
  none, so an unknown subject never falls through to Subjects.
  """
  use Ecto.Schema

  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Sources.Actor

  @statuses [:mapped, :needs_review, :excluded_source_page, :identity_review]
  @families [:people, :organizations, :places, :events, :works, :concepts, :nature, :subjects]

  schema "classification_decisions" do
    belongs_to :object, Entity, references: :object_id
    field :origin, Ecto.Enum, values: [:evaluator, :override]
    field :status, Ecto.Enum, values: @statuses
    field :family, Ecto.Enum, values: @families
    field :candidate_families, {:array, :string}, default: []
    field :rule_ids, {:array, :string}, default: []
    field :reasons, {:array, :string}, default: []
    field :warnings, {:array, :string}, default: []
    field :policy_version, :string
    field :evidence_fingerprint, :string
    field :source_pins, {:array, :map}, default: []
    belongs_to :reviewer_actor, Actor
    field :reason, :string
    belongs_to :supersedes, __MODULE__
    field :is_current, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def statuses, do: @statuses
  def families, do: @families
end
