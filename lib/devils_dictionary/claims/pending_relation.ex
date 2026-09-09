defmodule DevilsDictionary.Claims.PendingRelation do
  @moduledoc """
  A source edge whose other end does not exist yet.

  `materialize/1` is pure and per record, so when Wiktionary says *cat* has the
  hypernym *feline* all it can write is the string. In MVP-0 that was a
  `lexical_relations` row with `to_lemma` set and `to_lexeme_id` NULL. Here both
  endpoints of an assertion are real objects and NOT NULL, so an unresolved edge
  cannot be an assertion — and inventing a lexeme for a lemma no source listed
  would be exactly the identity-by-string mistake #74 exists to end.

  So it waits here, with the record that attested it, and
  `DevilsDictionary.Absorb.Resolver` drains it into assertions as targets
  appear. An unresolved edge is still a perfectly good edge: this table is what
  scorecard row **R2** reports as unresolved, by predicate, rather than a number
  nobody can inspect.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.Predicate
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Sources.{ImportRun, Source, SourceRecord}

  schema "pending_relations" do
    belongs_to :source, Source
    belongs_to :source_record, SourceRecord
    belongs_to :subject_object, Object
    belongs_to :predicate, Predicate
    field :to_lemma, :string
    field :to_pos, :string
    field :origin_key, :string
    field :confidence, :float
    field :method, :string
    field :metadata, :map, default: %{}
    belongs_to :last_seen_run, ImportRun

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(source_id source_record_id subject_object_id predicate_id to_lemma to_pos
               origin_key confidence method metadata last_seen_run_id)a

  def changeset(pending, attrs) do
    pending
    |> cast(attrs, @castable)
    |> validate_required([:source_id, :subject_object_id, :predicate_id, :to_lemma])
    |> unique_constraint([:source_id, :subject_object_id, :predicate_id, :to_lemma, :to_pos],
      name: :pending_relations_edge_index
    )
  end
end
