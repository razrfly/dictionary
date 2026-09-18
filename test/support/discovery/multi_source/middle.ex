defmodule DevilsDictionary.Discovery.MultiSource.Middle do
  @moduledoc """
  The better-tiered of the two stubs on the multi-source shelf, with the slug
  that sorts *last* alphabetically — so a shelf that took turns by slug rather
  than by tier would put the other one first, and the check would say so.
  Identity-bearing, like Commons.
  """

  use DevilsDictionary.Discovery.MultiSourceStub,
    slug: "zz-middle-stub",
    name: "Middle stub",
    tier: :middle,
    namespace: "stub_middle",
    evidence: :identity
end
