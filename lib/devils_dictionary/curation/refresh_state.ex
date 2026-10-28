defmodule DevilsDictionary.Curation.RefreshState do
  @moduledoc """
  A composition's refresh clock under one configuration version (#259 §5.1):
  when its inputs were last checked, whether they changed since, and when it
  is next due.

  Five dates, five meanings, never merged (#253 §7):

    * `last_completed_at`: the last **successful check**, including an
      unchanged one and one that found an editor is needed. Completion is
      not publication. A P5 check looks at the inputs; it does not judge
      them (`last_outcome: :needs_editor` means an editor is needed);
    * `refresh_after`: when a periodic check is due;
    * `next_retry_at`: failure backoff only (`state: :deferred`);
    * `dirty_at`: a **pending** input change, cleared only by a completion
      that saw every change (`dirty_seq` against `run_dirty_seq`);
    * `inputs_last_changed_at`: **history**, kept after `dirty_at` clears.

  The fence: `refresh_generation` names the run (a retry and a lease
  recovery keep it), and `lease_token` names who may write (every claim,
  recovery and suppression moves it). `admitted_parent_version_id` is the
  published version at admission, so a publication during the run shows as
  `superseded_on_arrival`, and `run_periodic` says whether the run was
  admitted only because its window passed (decided at admission, not later).

  An editor's assessment (#264 R14) completes as `:proposed`, `:abstained`
  or `:no_change`: those were judged. `:unchanged` and `:needs_editor` keep
  their meaning: the inputs were checked, not judged.
  `review_unit_reserved_at` is the review unit a run holds between its
  frozen packet and its proposal (#264 R5): every exit that moves the row
  clears it, so it is released exactly once.

  Written only by `Curation.Refresh`.
  """
  use Ecto.Schema

  schema "curation_refresh_states" do
    field :composition_id, :id
    field :configuration_version_id, :id

    field :state, Ecto.Enum,
      values: [:idle, :queued, :running, :suppressed, :deferred],
      default: :idle

    field :refresh_generation, :integer, default: 0
    field :lease_token, :integer, default: 0
    field :lease_expires_at, :utc_datetime_usec
    field :lease_attempts, :integer, default: 0
    field :run_periodic, :boolean, default: false
    field :admitted_parent_version_id, :id
    field :superseded_on_arrival, :boolean, default: false
    field :last_completed_at, :utc_datetime_usec

    field :last_outcome, Ecto.Enum,
      values: [:unchanged, :needs_editor, :proposed, :abstained, :no_change]

    field :last_outcome_reason, :string
    field :refresh_after, :utc_datetime_usec
    field :next_retry_at, :utc_datetime_usec
    field :failures, :integer, default: 0
    # Set only by a deferral; dirty marking must not move its date. Legacy
    # rows written before this column existed have an unknown deferral date.
    field :last_deferred_at, :utc_datetime_usec
    field :last_error, :string
    field :input_fingerprint, :string
    field :withheld_digest, :string
    field :dirty_at, :utc_datetime_usec
    field :dirty_reason, :string
    field :dirty_seq, :integer, default: 0
    field :run_dirty_seq, :integer
    field :inputs_last_changed_at, :utc_datetime_usec
    field :inputs_last_changed_reason, :string
    field :review_unit_reserved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
