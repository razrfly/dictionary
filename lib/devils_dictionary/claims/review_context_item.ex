defmodule DevilsDictionary.Claims.ReviewContextItem do
  @moduledoc """
  One endpoint's displayed revision within a review context.

  Exactly one revision target per row, enforced by a check constraint. An entity
  endpoint has no textual revision and simply contributes **no row** — which is
  not the same as a row with both columns null, and #74 is careful about the
  difference: "Do not require a revision ID for immutable identity-only
  endpoints or fabricate an entity version."
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.ReviewContext
  alias DevilsDictionary.Registry.{ContentRevision, SenseRevision}

  @roles [:subject, :object, :context]

  @primary_key false
  schema "review_context_items" do
    belongs_to :context, ReviewContext, primary_key: true
    field :endpoint_role, Ecto.Enum, values: @roles, primary_key: true
    belongs_to :content_revision, ContentRevision
    belongs_to :sense_revision, SenseRevision
  end

  def roles, do: @roles

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:context_id, :endpoint_role, :content_revision_id, :sense_revision_id])
    |> validate_required([:context_id, :endpoint_role])
    |> validate_one_target()
    |> check_constraint(:content_revision_id, name: :review_context_items_one_target)
  end

  defp validate_one_target(changeset) do
    content = get_field(changeset, :content_revision_id)
    sense = get_field(changeset, :sense_revision_id)

    case {content, sense} do
      {nil, nil} ->
        add_error(changeset, :content_revision_id, "a context item must cite one revision")

      {c, s} when not is_nil(c) and not is_nil(s) ->
        add_error(changeset, :content_revision_id, "a context item cites exactly one revision")

      _ ->
        changeset
    end
  end
end
