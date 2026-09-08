defmodule DevilsDictionary.Registry.Sense do
  @moduledoc """
  One source's meaning of one word. Never merged with another source's.

  `external_key` records what the source called this sense — `bank/noun/1#5`,
  `oewn-13377435-n#bank` — for provenance. **It is not identity.** The audit
  reproduced why: Wiktionary keys a sense by its position, so deleting a meaning
  from the middle renumbers everything after it and the row that held
  *"Money; profit."* silently comes to hold something else. Every quote, example
  and vote hanging off that id follows, with no foreign key violated anywhere.

  So identity is matched on content — part of speech, etymology number, and
  gloss similarity — and `identity_state` records when that match was not
  confident enough to make:

    * `active` — this meaning is attested by its source right now
    * `needs_review` — an incoming sense was plausibly this one and plausibly
      another; a `reconciliation_cases` row is open and a person decides
    * `retired` — the source no longer publishes it. Retired, not deleted, so
      everything that referenced it still resolves.

  The text lives in `sense_revisions`, and exactly one of those is current.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.{Lexeme, Object, SenseRevision}
  alias DevilsDictionary.Sources.Source

  @identity_states [:active, :needs_review, :retired]

  @primary_key false
  schema "senses" do
    belongs_to :object, Object, primary_key: true, define_field: false
    field :object_id, :id, primary_key: true

    belongs_to :lexeme, Lexeme, references: :object_id
    belongs_to :source, Source
    field :external_key, :string
    field :identity_state, Ecto.Enum, values: @identity_states, default: :active

    has_many :revisions, SenseRevision, foreign_key: :sense_id, references: :object_id

    timestamps(type: :utc_datetime_usec)
  end

  def identity_states, do: @identity_states

  def changeset(sense, attrs) do
    sense
    |> cast(attrs, [:object_id, :lexeme_id, :source_id, :external_key, :identity_state])
    |> validate_required([:object_id, :lexeme_id, :source_id, :external_key])
    |> unique_constraint([:source_id, :external_key])
    |> check_constraint(:identity_state, name: :senses_identity_state)
  end
end
