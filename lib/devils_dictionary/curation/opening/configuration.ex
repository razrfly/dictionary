defmodule DevilsDictionary.Curation.Opening.Configuration do
  @moduledoc """
  Which curation configuration produced an opening, and why that one (#201).

  The typed place for #201's resolved configuration: the configuration's
  stable `id` and `slug` (`global-default`), the exact `version` that was
  frozen for the run or manual composition, and the resolver's answer —
  `resolution_reason` (`:global_default` is the only MVP reason) and the
  `resolution_policy_version` it was decided under.

  **Always `nil` in Phase 1.** A development fixture resolves no
  configuration and runs no panel, and the opening says exactly that; this
  struct exists so #196/#201's reader has a typed field to fill rather than a
  map to improvise, and so the component's rendering of both cases is tested
  now. It carries no panel roster, votes or decisions: those are #203's
  structured records, which join the contract when they exist.
  """

  @enforce_keys [:id, :slug, :version, :resolution_reason, :resolution_policy_version]
  defstruct [:id, :slug, :version, :resolution_reason, :resolution_policy_version]

  @type t :: %__MODULE__{
          id: pos_integer(),
          slug: String.t(),
          version: pos_integer(),
          resolution_reason: atom(),
          resolution_policy_version: pos_integer()
        }
end
