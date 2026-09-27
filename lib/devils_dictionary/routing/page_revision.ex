defmodule DevilsDictionary.Routing.PageRevision do
  @moduledoc """
  One immutable editorial revision of a page: title, body, the actors
  accountable for it, its evidence, and — sealed by `membership_count` — its
  complete ordered membership.

  The database refuses UPDATE and DELETE, and refuses a membership row that
  does not fill one of the positions `1..membership_count` the revision
  declared, so what a revision said can never be edited afterwards. An On page
  body is editorial content owned by routing; it is not a curation composition
  (#196) and holds no ballot or claim-review state.
  """
  use Ecto.Schema

  alias DevilsDictionary.Routing.{Page, PageMembership}
  alias DevilsDictionary.Sources.Actor

  schema "page_revisions" do
    belongs_to :page, Page
    field :revision_number, :integer
    field :title, :string
    field :body, :string
    field :body_format, Ecto.Enum, values: [:markdown, :text], default: :markdown
    belongs_to :author_actor, Actor
    belongs_to :reviewer_actor, Actor
    field :evidence, :map, default: %{}
    field :membership_count, :integer, default: 0
    has_many :memberships, PageMembership, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
