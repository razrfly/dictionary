defmodule DevilsDictionary.Curation.CompositionItem do
  @moduledoc """
  One lead or highlight of a composition version, as exact references.

  An item stores ids, hashes and locators, never source text (R7):

    * `:content`: a content revision of `item_object_id`;
    * `:sense_quotation`: a sense revision, the `quotation:N` locator of one
      example, and the SHA-256 of its words;
    * `:work`: a source-record revision, or a committed catalog manifest
      pinned by name, checksum and row identity.

  When a referenced source row is deleted, the database nulls the reference
  and the reader withholds the item. Nothing else about an item ever changes.
  """
  use Ecto.Schema

  schema "editorial_composition_items" do
    field :composition_version_id, :id
    field :role, Ecto.Enum, values: [:lead, :highlight]
    field :position, :integer
    field :item_kind, Ecto.Enum, values: [:content, :sense_quotation, :work]
    field :item_object_id, :id
    field :content_revision_id, :id
    field :sense_revision_id, :id
    field :source_record_revision_id, :id
    field :catalog_manifest, :string
    field :catalog_checksum, :string
    field :catalog_identity, :string
    field :locator, :string
    field :words_sha256, :string
    field :meaning_sense_revision_id, :id
    field :meaning_lexeme_id, :id
    field :assertion_revision_id, :id
    field :selection_origin, Ecto.Enum, values: [:manual], default: :manual
    field :note, :string
    field :note_author_kind, Ecto.Enum, values: [:human, :model]
    field :note_author_label, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
