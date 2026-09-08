defmodule DevilsDictionary.Claims.AssertionEvidence do
  @moduledoc """
  What a claim rests on — or what argues against it.

  At least one target is required, and more than one is allowed, because two
  sources can support the same proposition without either losing its own
  attribution or its own withdrawal history. #74: "Multiple citations can
  support one assertion revision without erasing their origins."

  `evidence_role` keeps counterevidence in the same place as evidence.
  A contradicting citation is not an absence of support; it is a thing a reader
  should be able to see.

  Every target is a **revision**, never a mutable row, so "what did this rest
  on" keeps its answer after the source is edited.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry.{ContentRevision, SenseRevision}

  @roles [:supports, :contradicts]

  schema "assertion_evidence" do
    belongs_to :assertion_revision, AssertionRevision
    belongs_to :source_record_revision, SourceRecordRevision
    belongs_to :content_revision, ContentRevision
    belongs_to :sense_revision, SenseRevision
    field :evidence_role, Ecto.Enum, values: @roles, default: :supports
    field :locator, :string
    field :attribution_text, :string

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles

  @castable ~w(assertion_revision_id source_record_revision_id content_revision_id
               sense_revision_id evidence_role locator attribution_text)a

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, @castable)
    |> validate_required([:assertion_revision_id])
    |> validate_has_target()
    |> check_constraint(:assertion_revision_id, name: :assertion_evidence_has_target)
  end

  defp validate_has_target(changeset) do
    targets = [:source_record_revision_id, :content_revision_id, :sense_revision_id]

    if Enum.any?(targets, &get_field(changeset, &1)) do
      changeset
    else
      add_error(
        changeset,
        :source_record_revision_id,
        "evidence must cite at least one source record, content or sense revision"
      )
    end
  end
end
