defmodule DevilsDictionary.Claims.Predicate do
  @moduledoc """
  A registered relationship type, with the labels each direction reads as.

  One directional row is stored and the inverse is *derived* for display —
  #73 is explicit that an independently editable mirror edge is a way for the
  two halves of one fact to disagree. `forward_label` and `reverse_label` are
  what the two page sections say.

  `is_symmetric` and `is_transitive` are spelled that way deliberately:
  `SYMMETRIC` is a reserved word in SQL, and a quoted identifier would have
  worked right up until someone wrote a query by hand.

  Transitivity and cycle rules are **per predicate**, defaulting to off.
  `subclass_of` is transitive; `illustrates` plainly is not, and inferring it
  would manufacture claims nobody made.

  `source_native` marks the predicates that came from a source's own vocabulary
  — WordNet's hypernym, Wikidata's P279 — as against the product's own
  (`defines`, `illustrates`). #72: do not collapse a source's distinctions into
  a generic `related_to`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.PredicateEndpointRule

  schema "predicates" do
    field :key, :string
    field :forward_label, :string
    field :reverse_label, :string
    field :is_symmetric, :boolean, default: false
    field :is_transitive, :boolean, default: false
    field :cycles_allowed, :boolean, default: true
    field :source_native, :boolean, default: false
    field :description, :string

    has_many :endpoint_rules, PredicateEndpointRule

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(key forward_label reverse_label is_symmetric is_transitive
               cycles_allowed source_native description)a

  def changeset(predicate, attrs) do
    predicate
    |> cast(attrs, @castable)
    |> validate_required([:key, :forward_label, :reverse_label])
    |> validate_format(:key, ~r/\A[a-z][a-z0-9_]*\z/,
      message: "must be lowercase snake_case, so it can be a stable public identifier"
    )
    |> unique_constraint(:key)
  end
end
