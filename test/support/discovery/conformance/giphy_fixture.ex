defmodule DevilsDictionary.Discovery.Conformance.GiphyFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Giphy` — registry only.

  GIPHY is `transport: :browser` and `persistence: :transient`: the request is
  made by the reader's own browser and nothing is cached server-side, which is
  what K10 parks until written caching approval exists. So there is no run here
  either, and conformance asserts the contract and the gate.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Giphy

  @impl true
  def provider, do: Giphy

  @impl true
  def covered_target(context) do
    word = word!(context, "shrug", ~w(wordnet))

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
