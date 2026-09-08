defmodule DevilsDictionary.Corpus.SourceRecordRevision do
  @moduledoc """
  One immutable observation of a source record.

  MVP-0 overwrote `source_records.raw` in place, which meant a claim could cite
  "the Wiktionary record for bank" and that citation would quietly come to mean
  whatever Wiktionary said most recently. The audit's findings #1 and #2 both
  trace back to it.

  `revision_key` is the content hash, still taken on the payload **as fetched,
  before `trim/1`** — so tightening what we choose to keep never reads as a
  change at the source. A re-fetch that hashes the same writes nothing; one that
  differs adds a revision beside the old one, and the old one stays citable.

  `payload` is `load_in_query: false`: the whole set is roughly 660 MB and no
  ordinary read wants it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Sources.{ImportRun, SourceRecord}

  schema "source_record_revisions" do
    belongs_to :source_record, SourceRecord
    field :revision_key, :string
    field :payload, :map, load_in_query: false, default: %{}
    field :checksum, :string
    field :observed_at, :utc_datetime_usec
    belongs_to :import_run, ImportRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :source_record_id,
      :revision_key,
      :payload,
      :checksum,
      :observed_at,
      :import_run_id
    ])
    |> validate_required([:source_record_id, :revision_key])
    |> unique_constraint([:source_record_id, :revision_key])
  end
end
