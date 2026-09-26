defmodule DevilsDictionary.Curation.Opening.Review do
  @moduledoc """
  What the disclosure under an opening tells a reader about how it was chosen.

    * `state` — `:unreviewed` (nobody has checked it), `:reviewed` (a person
      checked a development fixture; it is still not published) or
      `:approved` (a human accepted this exact version for publication, #196).
    * `selected_by` / `selected_on` — who chose the arrangement, as
      `%{kind, label}`: `:human`, or `:model` for anything generated.
    * `reviewed_by` / `reviewed_on` — the human who approved it, or `nil`.
    * `panel` — the profiles, profile versions and model configuration that
      took part, when a panel did (#197). `nil` means **no model or persona
      took part**, which is the only honest value in Phase 1.
    * `support` / `dissent` — permitted, evidence-backed summaries. Empty
      means nothing was recorded; a vote is never shown as evidence, and a
      pending sensitive nomination is never shown as dissent.
  """

  @enforce_keys [:state]
  defstruct state: nil,
            selected_by: nil,
            selected_on: nil,
            reviewed_by: nil,
            reviewed_on: nil,
            panel: nil,
            support: [],
            dissent: []

  @type t :: %__MODULE__{
          state: :unreviewed | :reviewed | :approved,
          selected_by: %{kind: :human | :model | :fixture, label: String.t()} | nil,
          selected_on: Date.t() | nil,
          reviewed_by: String.t() | nil,
          reviewed_on: Date.t() | nil,
          panel: map() | nil,
          support: [String.t()],
          dissent: [String.t()]
        }
end
