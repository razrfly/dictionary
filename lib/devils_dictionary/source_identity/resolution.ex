defmodule DevilsDictionary.SourceIdentity.Resolution do
  @moduledoc "The durable outcome of resolving one source identity proposal."

  @type state :: :matched | :newly_created | :insufficient_evidence | :conflicting_identifiers
  @type t :: %__MODULE__{}

  defstruct state: :insufficient_evidence,
            object_id: nil,
            conflict_id: nil,
            reason: nil,
            identifiers: []
end
