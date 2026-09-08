defmodule DevilsDictionary.Registry.ContentItem do
  @moduledoc """
  A piece of published text or media with an identity of its own: a definition,
  an encyclopedia article, a quotation, a passage, an image.

  This replaces `entries`, and the difference that matters is that content no
  longer carries its target in a column. An `entries` row had `lexeme_id` and
  `concept_id` with a check constraint the read layer treated as XOR and the
  database wrote as OR, plus a single `author_id`. Here the target is a
  `defines` or `about` assertion and the credit is `authored_by`, so a
  translated work with two credits costs a row rather than a column.

  A definition stays a definition. #73 is explicit that a reader later
  attaching it as satire does not change what it is.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.{ContentRevision, Object}
  alias DevilsDictionary.Sources.Source

  @kinds ~w(definition article quotation passage image media other)a

  @primary_key false
  schema "content_items" do
    belongs_to :object, Object, primary_key: true, define_field: false
    field :object_id, :id, primary_key: true

    field :content_kind, Ecto.Enum, values: @kinds
    field :original_language, :string
    belongs_to :source, Source
    field :metadata, :map, default: %{}

    has_many :revisions, ContentRevision, foreign_key: :content_id, references: :object_id

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:object_id, :content_kind, :original_language, :source_id, :metadata])
    |> validate_required([:object_id, :content_kind])
    |> check_constraint(:content_kind, name: :content_items_content_kind)
  end
end
