defmodule DevilsDictionary.Registry.ContentRevision do
  @moduledoc """
  One immutable version of a content item's body.

  Immutable is the operative word: a review recorded against a definition has to
  keep meaning what it meant, so `review_context_items` cites a revision id and
  that revision's text never changes underneath it. A correction is a new
  revision, and the old review is marked stale rather than rewritten.

  `rights_metadata` is per revision because permission to reproduce can change
  without the identity or the relationships changing — a licence withdrawal
  restricts display, it does not un-write the definition.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision

  @formats [:text, :markdown, :html]
  @states [:active, :withdrawn, :superseded]

  schema "content_revisions" do
    field :content_id, :id
    field :revision_number, :integer
    field :body, :string
    field :body_format, Ecto.Enum, values: @formats, default: :text
    field :canonical_url, :string
    field :headword, :string
    field :position, :integer, default: 0
    field :year, :integer
    field :rights_metadata, :map, default: %{}
    field :metadata, :map, default: %{}
    field :lifecycle_state, Ecto.Enum, values: @states, default: :active
    field :is_current, :boolean, default: false
    belongs_to :source_record_revision, SourceRecordRevision

    timestamps(type: :utc_datetime_usec)
  end

  def formats, do: @formats
  def states, do: @states

  @castable ~w(content_id revision_number body body_format canonical_url headword position
               year rights_metadata metadata lifecycle_state is_current
               source_record_revision_id)a

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @castable)
    |> validate_required([:content_id, :revision_number])
    |> unique_constraint([:content_id, :revision_number])
    |> unique_constraint(:is_current, name: :content_revisions_one_current_index)
  end
end
