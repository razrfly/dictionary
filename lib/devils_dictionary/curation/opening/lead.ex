defmodule DevilsDictionary.Curation.Opening.Lead do
  @moduledoc """
  The opening's lead: one sourced definition, quoted verbatim.

    * `policy` — `:priority_source` when this is the applicable *Devil's
      Dictionary* entry, which always leads where one exists
      (`DevilsDictionary.Curation.LeadPolicy`); `:manual_fallback` when no such
      entry exists and a person chose another sourced definition.
    * `excerpt` — `%{text, html, clipped?, chars}`: the opening of the exact
      revision, cut only at a sentence end (`DevilsDictionary.Curation.Excerpt`).
      `text` is the words; `html` is the same words through the app's own
      Markdown renderer, which escapes before it marks anything up. `chars` is
      the whole entry's length, for the continuation.
    * `entry` — the headword and grammar marker as the source printed them,
      and the year.
    * `links` — `card_id` is the card on this page that holds the complete
      entry, which the continuation opens; `source` is the source's own page
      for the entry. The exact revision's evidence page is built by the
      component from `reference`, with the app's verified routes.
  """

  alias DevilsDictionary.Curation.Opening.{Credit, Meaning, Reason, Reference}

  @enforce_keys [:reference, :policy, :source, :excerpt, :meaning]
  defstruct reference: nil,
            policy: nil,
            source: nil,
            author: nil,
            work: nil,
            entry: %{},
            excerpt: nil,
            meaning: nil,
            links: %{},
            credits: [],
            reasons: []

  @type t :: %__MODULE__{
          reference: Reference.t(),
          policy: :priority_source | :manual_fallback,
          source: map(),
          author: String.t() | nil,
          work: String.t() | nil,
          entry: %{headword: String.t() | nil, marker: String.t() | nil, year: integer() | nil},
          excerpt: %{text: String.t(), html: String.t(), clipped?: boolean(), chars: integer()},
          meaning: Meaning.t(),
          links: %{card_id: String.t() | nil, source: String.t() | nil},
          credits: [Credit.t()],
          reasons: [Reason.t()]
        }
end
