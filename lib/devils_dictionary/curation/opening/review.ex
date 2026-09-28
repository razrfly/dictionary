defmodule DevilsDictionary.Curation.Opening.Review do
  @moduledoc """
  Who chose an opening's arrangement and whether a person has reviewed it.

    * `state` — `:unreviewed` (nobody has checked it), `:reviewed` (a person
      checked a development fixture; it is still not published) or
      `:approved` (a human accepted this exact version for publication, #196).
    * `selected_by` / `selected_on` — who chose the arrangement, as
      `%{kind, label}`: `:human`, or `:model` for anything generated.
    * `reviewed_by` / `reviewed_on` — the human who reviewed it, or `nil`.

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
            reviewed_on: nil

  @type t :: %__MODULE__{
          state: :unreviewed | :reviewed | :approved,
          selected_by: %{kind: :human | :model | :fixture, label: String.t()} | nil,
          selected_on: Date.t() | nil,
          reviewed_by: String.t() | nil,
          reviewed_on: Date.t() | nil
        }
end
