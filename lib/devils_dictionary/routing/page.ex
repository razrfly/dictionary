defmodule DevilsDictionary.Routing.Page do
  @moduledoc """
  A durable page identity (ADR 0004 §5): what a public address serves.

  A page is not a registry object and has no `objects` kind. A subject,
  edition or lexeme page is *about* exactly one registry object; an On
  overview, a collection and a choice page are editorial and are about none.
  Role, locale and target never change once written — a different treatment is
  a different page.

  Two states, deliberately separate:

    * `publication_state` — draft, published or withdrawn. Stage 1 writes no
      transition out of draft: publication needs every gate of ADR §7 and is
      Stage 5's.
    * `lifecycle_state` — active, merged (into `merged_into_page_id`), split
      (a choice among successors) or retired (its paths are tombstones). Only
      `Routing.Ledger` changes it, and only with a `route_changes` row.

  `canonical_path_id` and the canonical path's destination agree at commit, and
  a published active or split page has one (deferred constraint triggers).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Routing.{PageRevision, PublicPath, RouteChange}

  @roles [:subject, :edition, :lexeme, :overview, :collection, :choice]
  @targeted [:subject, :edition, :lexeme]

  schema "pages" do
    field :role, Ecto.Enum, values: @roles
    field :locale, :string, default: "en"
    belongs_to :target_object, Object
    field :publication_state, Ecto.Enum, values: [:draft, :published, :withdrawn], default: :draft

    field :lifecycle_state, Ecto.Enum,
      values: [:active, :merged, :split, :retired],
      default: :active

    belongs_to :merged_into_page, __MODULE__
    belongs_to :current_revision, PageRevision
    belongs_to :canonical_path, PublicPath
    belongs_to :last_route_change, RouteChange

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles

  @doc "Roles whose page is about exactly one registry object."
  def targeted_roles, do: @targeted

  @doc "A new, unrouted page. Nothing else about a page is set by a changeset."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:role, :locale, :target_object_id])
    |> validate_required([:role, :locale])
    |> update_change(:locale, &String.downcase/1)
    |> validate_format(:locale, ~r/^[a-z]{2,3}(-[a-z0-9]{2,8})*$/)
    |> validate_target()
    |> foreign_key_constraint(:target_object_id)
    |> check_constraint(:target_object_id, name: :pages_target_by_role)
    |> unique_constraint([:target_object_id, :locale], name: :pages_subject_target_locale_index)
    |> unique_constraint([:target_object_id, :locale], name: :pages_lexeme_target_locale_index)
  end

  defp validate_target(changeset) do
    role = get_field(changeset, :role)
    target = get_field(changeset, :target_object_id)

    cond do
      role in @targeted and is_nil(target) ->
        add_error(changeset, :target_object_id, "is required for a #{role} page")

      role not in @targeted and not is_nil(target) ->
        add_error(changeset, :target_object_id, "must be empty for an editorial page")

      true ->
        changeset
    end
  end
end
