defmodule DevilsDictionary.Sources.ReconciliationCase do
  @moduledoc """
  A source change the importer would not decide on its own.

  #74: "Ambiguous sense identity changes create a reconciliation case; they never
  reuse an old ID for a different meaning. This cannot be solved by a uniqueness
  constraint alone."

  A case need not come from a source. An identity split is curatorial, and #74
  requires its ambiguous attachments to enter explicit review rather than be
  guessed onto an output -- so `source_id` is optional and such a case names
  the `object` being split and the `assertion` nobody may reassign for you.

  The Gate 0 spike showed both ways in. Either nothing scores well enough to
  claim an existing identity, or two candidates score so close that picking the
  higher would be arbitrary — measured at 0.897 against two senses with a 0.000
  gap, where the tiebreak would have been the row id. In both cases the sense
  goes to `needs_review`, a case opens, no revision is written and no attachment
  moves.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Registry.{Lexeme, Object, Sense}
  alias DevilsDictionary.Sources.{Actor, ImportRun, Source, SourceRecord}

  @statuses [:open, :resolved, :dismissed]

  schema "reconciliation_cases" do
    belongs_to :source, Source
    belongs_to :source_record, SourceRecord
    field :kind, :string
    belongs_to :object, Object
    belongs_to :assertion, Assertion
    belongs_to :lexeme, Lexeme, references: :object_id
    belongs_to :sense, Sense, references: :object_id
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :open
    belongs_to :opened_run, ImportRun
    belongs_to :resolved_by_actor, Actor
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @castable ~w(source_id source_record_id kind object_id assertion_id lexeme_id sense_id
               payload status opened_run_id resolved_by_actor_id resolved_at)a

  def changeset(kase, attrs) do
    kase
    |> cast(attrs, @castable)
    |> validate_required([:kind])
    |> check_constraint(:status, name: :reconciliation_cases_status)
  end
end
