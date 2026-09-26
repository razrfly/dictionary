defmodule DevilsDictionary.Curation.Opening.Highlight do
  @moduledoc """
  One of an opening's zero to three highlights.

  `kind` is what the component draws: `:artwork` (a picture, with the credit
  its catalog committed) or `:quotation` (a line, verbatim, with the citation
  its source wrote). The component branches on the kind and never on which
  provider supplied the item (#156, promise 9).

    * `position` — 1 to 3, the order the selection gave.
    * `title`, `creator`, `date` — as the source records them.
    * `image` — `%{url, alt}` for an artwork, or `nil`.
    * `quotation` — `%{text, citation, provenance}` for a line, or `nil`.
      `provenance` is the badge the page already derives for that line.
    * `links` — `source` is the source's own page for the item. The durable
      page a reader inspects it on (the work's entity page, the sense
      revision's evidence page) is built by the component from `reference`.
    * `reasons` — a `:source_match` reason when the registry records why the
      item fits the meaning, and an `:editorial` reason when the selector
      wrote one, each attributed.
  """

  alias DevilsDictionary.Curation.Opening.{Credit, Meaning, Reason, Reference}

  @enforce_keys [:position, :kind, :reference, :meaning, :source]
  defstruct position: nil,
            kind: nil,
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
            reasons: []

  @type t :: %__MODULE__{
          position: 1..3,
          kind: :artwork | :quotation,
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
          reasons: [Reason.t()]
        }
end
