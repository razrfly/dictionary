defmodule DevilsDictionary.Sources.MaterializedOutput do
  @moduledoc """
  Which objects a source record produced, and when a run last re-emitted them.

  This is the fix for the audit's finding #1. The materializer upserts what it
  emits and has no idea what it emitted last time, so a meaning the source has
  dropped stays live for ever: an isolated probe replaced a Wiktionary record's
  two senses with one and **both old senses remained**, one of them now showing
  the other's gloss, while parity reported zero gaps.

  A run stamps `last_seen_run_id` on everything it emits. Afterwards, this
  source record's outputs that the run did not stamp are **retired** — not
  deleted, and never another source's support for the same object. A word
  WordNet still attests survives Wiktionary dropping it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Sources.{ImportRun, SourceRecord}

  @primary_key false
  schema "source_materialized_outputs" do
    belongs_to :source_record, SourceRecord, primary_key: true
    field :output_role, :string, primary_key: true
    field :output_key, :string, primary_key: true
    belongs_to :output_object, Object
    belongs_to :last_seen_run, ImportRun
    field :retired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [
      :source_record_id,
      :output_role,
      :output_key,
      :output_object_id,
      :last_seen_run_id,
      :retired_at
    ])
    |> validate_required([:source_record_id, :output_role, :output_key, :output_object_id])
  end
end
