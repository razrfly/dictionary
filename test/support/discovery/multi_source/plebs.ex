defmodule DevilsDictionary.Discovery.MultiSource.Plebs do
  @moduledoc """
  The lesser-tiered of the two stubs on the multi-source shelf, with the slug
  that sorts *first* alphabetically. A keyword search that says so (M6), like
  Openverse will be.
  """

  use DevilsDictionary.Discovery.MultiSourceStub,
    slug: "aa-plebs-stub",
    name: "Plebs stub",
    tier: :plebs,
    namespace: "stub_plebs",
    evidence: :query
end
