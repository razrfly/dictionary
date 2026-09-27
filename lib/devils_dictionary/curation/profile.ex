defmodule DevilsDictionary.Curation.Profile do
  @moduledoc """
  A stable curator identity (#196 `curator_profiles`): *inspired by* a dead
  writer, never impersonating one.

  A profile is `proposed` until a human reviewer admits one sourced version of
  its dossier (`Profiles.admit/4`). The database refuses an `admitted` row
  unless it has:

    * a bot principal;
    * a human admitter and a reason;
    * a version citing its sources and deceased-status evidence (C6).

  Seeding creates the five proposed identities and nothing else: no dossier,
  no evidence, no quotation.
  """
  use Ecto.Schema

  @states [:proposed, :admitted, :retired]

  schema "curator_profiles" do
    field :slug, :string
    field :label, :string
    field :subject_label, :string
    field :state, Ecto.Enum, values: @states, default: :proposed
    field :bot_actor_id, :id
    field :admitted_by_actor_id, :id
    field :admitted_at, :utc_datetime_usec
    field :admission_reason, :string
    field :current_version_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
end
