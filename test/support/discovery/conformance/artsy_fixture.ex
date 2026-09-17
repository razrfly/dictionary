defmodule DevilsDictionary.Discovery.Conformance.ArtsyFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Artsy` — registry only.

  Artsy declares `background: false`, so there is no run for the suite to drive
  and `retrieve/4` does not exist to drive it with. K9 freezes the pilot: its
  43 artworks reach a word page through the committed catalog and the shared
  shelf, not through this module. What conformance can assert is the half that
  is still a contract — the identity, the capabilities, and that the pipeline
  gate agrees this module must never be scheduled.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Artsy

  @impl true
  def provider, do: Artsy

  @impl true
  def covered_target(context) do
    word = word!(context, "allegory", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(_scenario, _context), do: %{pages: [[]]}
end
