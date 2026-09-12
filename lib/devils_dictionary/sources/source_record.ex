defmodule DevilsDictionary.Sources.SourceRecord do
  @moduledoc """
  What a source calls one of its records, and when we last looked at it.

  Identity only. The payload moved to `source_record_revisions`, because
  overwriting `raw` in place meant a claim citing "the Wiktionary record for
  bank" would quietly come to cite whatever Wiktionary said most recently — the
  cause the 7 September audit traced findings #1 and #2 back to.

  `content_hash` is still taken on the payload **as fetched, before `trim/1`**.
  That is deliberate and load-bearing: tightening what we choose to keep must
  never read as a change at the source, and 19,250 records were falsely stamped
  once before this rule existed. The hash is now also the revision key, so a
  re-fetch that hashes the same writes nothing at all.

  `absent_until` records "this source had nothing for this target", which is a
  finding with an expiry rather than a permanent verdict.

  The record's `content_hash` names its **current** revision: the two are the
  same value by construction, so "the payload as of now" needs no extra pointer.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.{Actor, Source}

  schema "source_records" do
    belongs_to :source, Source
    field :external_id, :string
    field :url, :string
    field :content_hash, :string
    field :fetched_at, :utc_datetime_usec
    field :changed_at, :utc_datetime_usec
    field :materialized_at, :utc_datetime_usec
    field :absent_until, :utc_datetime_usec
    field :display_allowed, :boolean, default: true
    field :display_policy_reason, :string
    field :display_policy_changed_at, :utc_datetime_usec
    belongs_to :display_policy_actor, Actor

    has_many :revisions, SourceRecordRevision

    # The current revision's payload, loaded on demand rather than stored here.
    # Virtual on purpose: `materialize/1` is a pure function of a record, and
    # keeping the field means all six adapters and their 159 offline tests are
    # untouched by the payload moving into its own table. `Sources.raw/1` and
    # `Absorb.Batch` are what fill it.
    field :raw, :map, virtual: true, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(source_id external_id url content_hash fetched_at changed_at
               materialized_at absent_until display_allowed display_policy_reason
               display_policy_changed_at display_policy_actor_id)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @castable)
    |> validate_required([:source_id, :external_id])
    |> unique_constraint([:source_id, :external_id])
  end

  @doc """
  The content hash of a payload: sha256 of its JSON, lowercase hex.

  Taken before `trim/1` — see the moduledoc. Also the `revision_key`, so
  identical bytes are identical revisions by construction.
  """
  def content_hash(raw) when is_map(raw) do
    :sha256 |> :crypto.hash(Jason.encode!(raw)) |> Base.encode16(case: :lower)
  end
end
