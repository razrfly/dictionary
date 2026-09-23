defmodule DevilsDictionary.SourceIdentity.Resolution do
  @moduledoc "The durable outcome of resolving one source identity proposal."

  @type state :: :matched | :newly_created | :insufficient_evidence | :conflicting_identifiers
  @type t :: %__MODULE__{}

  defstruct state: :insufficient_evidence,
            object_id: nil,
            conflict_id: nil,
            reason: nil,
            identifiers: [],
            # One outcome per relationship on the entry, in the provider's
            # order (#164): `%{role, target, qid, state, object_id, label,
            # reason}`, `state` one of `:matched`, `:minted`, `:overridden`,
            # `:deferred`, `:unresolved`. Empty when the subject did not
            # resolve, because nothing is credited to an identity that is not
            # there.
            relationships: []
end
