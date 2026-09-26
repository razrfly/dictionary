defmodule DevilsDictionary.Routing.RouteChange do
  @moduledoc """
  One row of the append-only route ledger.

  Every row belongs to an operation (`operation_id`, ordered by `sequence`)
  and records one transition: a path's kind and destination, or a page's
  lifecycle, canonical pointer, merge successor and current revision — before
  and after. The database checks each against the row it describes as it
  changes, which is what makes the ledger complete, and the before-states are
  what `Routing.Ledger.rollback/3` restores.

  Allocation may be a batch job's; every other operation is an approved human
  decision, and the database refuses one written by any other actor.
  """
  use Ecto.Schema

  alias DevilsDictionary.Routing.{ClassificationDecision, Page, PageRevision, PublicPath}
  alias DevilsDictionary.Sources.Actor

  @operations [:allocate, :move, :merge, :split, :retire, :rollback]
  @kinds [:canonical, :alias, :tombstone]
  @lifecycles [:active, :merged, :split, :retired]

  schema "route_changes" do
    field :operation_id, Ecto.UUID
    field :sequence, :integer
    field :operation, Ecto.Enum, values: @operations

    belongs_to :path, PublicPath
    field :before_kind, Ecto.Enum, values: @kinds
    field :after_kind, Ecto.Enum, values: @kinds
    belongs_to :before_destination, Page
    belongs_to :after_destination, Page

    belongs_to :page, Page
    field :before_lifecycle, Ecto.Enum, values: @lifecycles
    field :after_lifecycle, Ecto.Enum, values: @lifecycles
    belongs_to :before_canonical_path, PublicPath
    belongs_to :after_canonical_path, PublicPath
    belongs_to :before_merged_into, Page
    belongs_to :after_merged_into, Page
    belongs_to :before_revision, PageRevision
    belongs_to :after_revision, PageRevision

    belongs_to :classification_decision, ClassificationDecision
    field :policy_version, :string
    belongs_to :actor, Actor
    field :reason, :string
    field :reverts_operation_id, Ecto.UUID
    field :details, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def operations, do: @operations
end
