defmodule DevilsDictionary.Routing.PageMembership do
  @moduledoc """
  One ordered member of a page revision: exactly one registry object or one
  page, and what the membership means.

    * `supplies_lexical_material` — a lexeme or sense the page draws on;
    * `discusses_subject` — a subject the page is about in part;
    * `editorial_association` — a deliberate link that asserts nothing, such
      as Putin/poutine wordplay;
    * `choice_option` — an option on a choice page;
    * `split_successor` — a successor of a split page, written only by
      `Routing.Ledger.split/3`.

  Membership is never an identity assertion and never writes one. History is
  the revision it belongs to; the row itself is immutable.
  """
  use Ecto.Schema

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Routing.{Page, PageRevision}

  @relationships [
    :supplies_lexical_material,
    :discusses_subject,
    :editorial_association,
    :choice_option,
    :split_successor
  ]

  schema "page_memberships" do
    belongs_to :page, Page
    belongs_to :page_revision, PageRevision
    field :position, :integer
    field :relationship, Ecto.Enum, values: @relationships
    belongs_to :target_object, Object
    belongs_to :target_page, Page
    field :rationale, :string
    field :evidence, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def relationships, do: @relationships
end
