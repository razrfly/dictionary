defmodule DevilsDictionary.Routing.BackfillItem do
  @moduledoc """
  One population record's outcome in a backfill run (#194, Stage 2): its
  disposition, why, and the decision, page and address it produced. Written
  in the same transaction as those writes, so it is the run's checkpoint.
  Append-only.
  """
  use Ecto.Schema

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Routing.{BackfillRun, ClassificationDecision, Page, PublicPath}

  @dispositions ~w(allocated awaiting_review deferred_by_review not_addressed refused
                   missing_from_export missing_from_database input_changed evidence_changed
                   classification_refused)

  def dispositions, do: @dispositions

  schema "routing_backfill_items" do
    belongs_to :run, BackfillRun
    belongs_to :object, Object
    field :position, :integer
    field :disposition, :string
    field :reason, :string
    belongs_to :decision, ClassificationDecision
    belongs_to :page, Page
    belongs_to :path, PublicPath
    field :proposed_path, :string
    field :review, :map
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
