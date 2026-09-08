defmodule DevilsDictionary.Sources.Actor do
  @moduledoc """
  Whoever is accountable for a claim: a login account, a curator bot, an
  importing process, an external claimant, or nobody we know of.

  Four things #73 insists are distinct and MVP-0 had no way to distinguish:
  the provider, the author, the submitter and the importer. A `sources` row is
  a provider; an `actors` row is a *principal* — the thing that can be held to
  a claim.

  Two rules the database enforces:

    * **exactly one typed principal per kind.** The community sketch's voter
      check was an OR, so a vote could be cast by a human *and* a bot at once.
      Here `user` has a `user_id` and no `bot_source_id`, `bot` the reverse, and
      `unknown` has none of them.
    * **`unknown` is a real answer.** A historical claim with no known claimant
      gets an explicit unknown actor rather than an invented person. #73: "Unknown
      is a valid state for authorship, matching and evidence."

  `entity_id` is the public person or organisation this actor *is*, when that
  has genuinely been established. It is nullable and stays that way by default:
  a curator account claiming to be a known author is not thereby that author.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Sources.Source

  @kinds [:user, :bot, :import, :external, :unknown]

  schema "actors" do
    field :actor_kind, Ecto.Enum, values: @kinds
    belongs_to :user, User
    belongs_to :bot_source, Source
    belongs_to :entity, Entity, references: :object_id
    field :label, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(actor, attrs) do
    actor
    |> cast(attrs, [:actor_kind, :user_id, :bot_source_id, :entity_id, :label, :metadata])
    |> validate_required([:actor_kind])
    |> check_constraint(:actor_kind, name: :actors_typed_principal)
    |> unique_constraint(:user_id)
    |> unique_constraint(:bot_source_id)
  end
end
