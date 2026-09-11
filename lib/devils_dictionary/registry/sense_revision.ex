defmodule DevilsDictionary.Registry.SenseRevision do
  @moduledoc """
  What a source says a meaning is, at one point in time.

  `position` is here and it is **ordering only** — it is what the source printed,
  useful for rendering senses in the order the dictionary lists them, and it
  never identifies anything. That distinction is the whole point of splitting
  revisions out of `senses`.

  `is_current` designates the revision the reader sees. Exactly one per sense:
  a partial unique index proves at most one, and a deferred constraint trigger
  proves at least one at commit — #74 is explicit that the index alone is not
  enough. `lifecycle_state` is a separate question: the current revision may say
  `withdrawn`, which is how "the source dropped this meaning" is expressed
  without pretending the meaning never existed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision

  @states [:active, :withdrawn, :superseded]

  schema "sense_revisions" do
    field :sense_id, :id
    field :revision_number, :integer
    field :gloss, :string
    field :group_key, :string
    field :position, :integer, default: 0
    field :tags, {:array, :string}, default: []
    field :topics, {:array, :string}, default: []
    field :examples, DevilsDictionary.Types.JsonValue, default: []
    field :url, :string
    field :metadata, :map, default: %{}
    field :lifecycle_state, Ecto.Enum, values: @states, default: :active
    field :is_current, :boolean, default: false
    belongs_to :source_record_revision, SourceRecordRevision

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states

  @castable ~w(sense_id revision_number gloss group_key position tags topics examples
               url metadata lifecycle_state is_current source_record_revision_id)a

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @castable)
    |> validate_required([:sense_id, :revision_number])
    |> unique_constraint([:sense_id, :revision_number])
    |> unique_constraint(:is_current, name: :sense_revisions_one_current_index)
  end
end
