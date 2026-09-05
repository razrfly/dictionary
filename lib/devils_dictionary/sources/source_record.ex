defmodule DevilsDictionary.Sources.SourceRecord do
  @moduledoc """
  The truth we fetched, trimmed to the fields we use.

  One row per `(source, external_id)`; replaced, never edited. Carries the
  canonical URL at the source, so every derived row has a link back and can be
  rebuilt with the network off. Spec: issue #69 §4.

  `raw` is `load_in_query: false` — select it explicitly when you need it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "source_records" do
    belongs_to :source, DevilsDictionary.Sources.Source

    field :external_id, :string
    field :url, :string
    field :raw, :map, load_in_query: false
    field :content_hash, :string
    field :fetched_at, :utc_datetime_usec
    field :changed_at, :utc_datetime_usec
    field :materialized_at, :utc_datetime_usec
    field :absent_until, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :source_id,
      :external_id,
      :url,
      :raw,
      :content_hash,
      :fetched_at,
      :changed_at,
      :materialized_at,
      :absent_until
    ])
    |> validate_required([:source_id, :external_id])
    |> unique_constraint([:source_id, :external_id])
  end

  @doc """
  sha256 of the raw payload, used to detect a changed record on refetch.
  """
  def content_hash(raw) when is_map(raw) do
    :sha256
    |> :crypto.hash(Jason.encode!(raw))
    |> Base.encode16(case: :lower)
  end
end
