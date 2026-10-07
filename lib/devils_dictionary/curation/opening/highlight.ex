defmodule DevilsDictionary.Curation.Opening.Highlight do
  @moduledoc """
  One of an opening's zero to three highlights.

  `kind` is what the component draws: `:artwork` (a picture, with the credit
  its catalog committed), `:quotation` (a line, verbatim, with the citation
  its source wrote) or `:exemplar` (a person, work or passage someone cited
  as an example of the meaning, through an accepted `illustrates` claim,
  #212). The component branches on the kind and never on which provider
  supplied the item (#156, promise 9).

    * `position` — 1 to 3, the order the selection gave.
    * `title`, `creator`, `date` — as the source records them.
    * `image` — `%{url, alt}` for an artwork, or `nil`.
    * `register` — `:quotation` for a line (an exact sourced quotation; its
      accuracy does not make what it says true), `nil` for a picture.
    * `quotation` — `%{text, citation, provenance}` for a line, or `nil`.
      `provenance` is the badge the page already derives for that line.
    * `links` — `source` is the source's own page for the item. The durable
      page a reader inspects it on (the work's entity page, the sense
      revision's evidence page) is built by the component from `reference`.
    * `reasons` — a `:source_match` reason when the registry records why the
      item fits the meaning, and an `:editorial` reason when the selector
      wrote one, each attributed.

  An exemplar also carries, and nothing else does:

    * `subject` — what the claim cites: `%{kind: :entity | :content,
      entity_kind, qid, words}`, `words` being a passage's pinned words and
      `nil` for an entity. `title` is its label.
    * `claim` — `%{assertion_id, rationale, nominated_by: %{label}}`: the
      nominator's own reason, and who the record says nominated it (`label`
      `nil` when it names nobody).
    * `provenance` — the claim's `DevilsDictionary.Examples.Provenance`, as
      the examples card reads it for the public, with this opening's
      selection in place of the card's ranking (`Provenance.in_fixture/2`).
      The component draws it with `DevilsDictionaryWeb.ExampleProvenance`,
      so the opening and the card say the same about one claim.
  """

  alias DevilsDictionary.Curation.Opening.{Credit, Meaning, Reason, Reference}

  @enforce_keys [:position, :kind, :reference, :meaning, :source]
  defstruct position: nil,
            kind: nil,
            register: nil,
            reference: nil,
            title: nil,
            creator: nil,
            date: nil,
            image: nil,
            quotation: nil,
            meaning: nil,
            source: nil,
            credits: [],
            links: %{},
            reasons: [],
            subject: nil,
            claim: nil,
            provenance: nil

  @type t :: %__MODULE__{
          position: 1..3,
          kind: :artwork | :quotation | :exemplar,
          register: :quotation | nil,
          reference: Reference.t(),
          title: String.t() | nil,
          creator: String.t() | nil,
          date: String.t() | nil,
          image: %{url: String.t(), alt: String.t()} | nil,
          quotation:
            %{text: String.t(), citation: String.t() | nil, provenance: String.t() | nil} | nil,
          meaning: Meaning.t(),
          source: map(),
          credits: [Credit.t()],
          links: %{source: String.t() | nil},
          reasons: [Reason.t()],
          subject:
            %{
              kind: :entity | :content,
              entity_kind: atom() | nil,
              qid: String.t() | nil,
              words: String.t() | nil
            }
            | nil,
          claim: %{assertion_id: pos_integer(), rationale: String.t(), nominated_by: map()} | nil,
          provenance: DevilsDictionary.Examples.Provenance.t() | nil
        }
end
