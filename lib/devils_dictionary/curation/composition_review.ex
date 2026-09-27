defmodule DevilsDictionary.Curation.CompositionReview do
  @moduledoc """
  A human presentation decision about one composition version (R1, R2).
  Append-only; the latest decision is the version's state.

  Accepting a presentation is not publishing it, and it accepts no claim or
  page. It writes no pointer, no receipt, no assertion review and no page row.
  """
  use Ecto.Schema

  @decisions [:accepted, :rejected, :withdrawn, :needs_review]

  schema "editorial_composition_reviews" do
    field :composition_id, :id
    field :composition_version_id, :id
    field :reviewer_actor_id, :id
    field :decision, Ecto.Enum, values: @decisions
    field :reason, :string
    field :reviewed_eligibility_fingerprint, :string
    field :idempotency_key, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def decisions, do: @decisions
end
