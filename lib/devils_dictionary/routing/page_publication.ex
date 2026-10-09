defmodule DevilsDictionary.Routing.PagePublication do
  @moduledoc """
  A publication receipt (#237, Stage 5 of #194): one change of a page's
  `publication_state`, publish or withdraw, with the states before and
  after, the launch manifest and standing review rule it was made under, the
  eight gates as they were checked, the human actor and the reason.
  Append-only; the database refuses a publication state change no receipt
  records, and a receipt that does not continue its page's history
  (`Routing.Publications`).
  """
  use Ecto.Schema

  alias DevilsDictionary.Routing.Page
  alias DevilsDictionary.Sources.Actor

  @states [:draft, :published, :withdrawn]

  schema "page_publications" do
    belongs_to :page, Page
    field :action, Ecto.Enum, values: [:publish, :withdraw]
    field :before_state, Ecto.Enum, values: @states
    field :after_state, Ecto.Enum, values: @states
    field :manifest_sha256, :string
    field :rule_sha256, :string
    field :gates, :map, default: %{}
    belongs_to :actor, Actor
    field :reason, :string
    field :committed_at, :utc_datetime_usec, read_after_writes: true
  end
end
