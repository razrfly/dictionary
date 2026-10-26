defmodule DevilsDictionary.Curation.Opening.Review do
  @moduledoc """
  Who chose an opening's arrangement and whether a person has reviewed it.

    * `state` — `:unreviewed` (nobody has checked it), `:reviewed` (a person
      checked a development fixture; it is still not published),
      `:approved` (a human accepted this exact version for publication, #196)
      or `:published` (a reviewer published it, and the receipt says so).
    * `selected_by` / `selected_on` — who chose the arrangement, as
      `%{kind, label}`: `:human`, or `:model` for anything generated.
    * `reviewed_by` / `reviewed_on` — the human who reviewed it, or `nil`.
    * `published_by` / `published_on` / `receipt_id` — for a published
      composition, the actor and date of the publication receipt and its id
      (#255). `nil` for a fixture, which nobody published.
    * `assessment` — for a published composition, its refresh clock as
      `Curation.Refresh.assessment/1` reads it (#259 §2.1): when its inputs
      were last checked and with what outcome, when they last changed, when
      the next check is due. `nil` when it has never been checked, and for a
      fixture. A P5 check looks at the inputs; it does not judge them.

  What this deliberately does not hold: panel rosters, per-profile votes,
  counts, objections and human override lineage. Those are #203's structured
  decision and history records over #196's runs and ballots, and they will
  join the contract as typed fields when those records exist — not as free
  text here, and never invented for a fixture no panel saw.
  """

  @enforce_keys [:state]
  defstruct state: nil,
            selected_by: nil,
            selected_on: nil,
            reviewed_by: nil,
            reviewed_on: nil,
            published_by: nil,
            published_on: nil,
            receipt_id: nil,
            assessment: nil

  @type t :: %__MODULE__{
          state: :unreviewed | :reviewed | :approved | :published,
          selected_by: %{kind: :human | :model | :fixture, label: String.t()} | nil,
          selected_on: Date.t() | nil,
          reviewed_by: String.t() | nil,
          reviewed_on: Date.t() | nil,
          published_by: %{kind: :human | :model, label: String.t()} | nil,
          published_on: Date.t() | nil,
          receipt_id: pos_integer() | nil,
          assessment: map() | :preview | nil
        }
end
