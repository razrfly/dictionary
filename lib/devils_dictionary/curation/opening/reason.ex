defmodule DevilsDictionary.Curation.Opening.Reason do
  @moduledoc """
  Why an item is in the opening, and — always — who says so.

  Three kinds, which the component labels differently so they can never be
  mistaken for one another or for the quoted source text (#203, #204: satire,
  exact quotation, factual statement and generated commentary stay
  distinguishable):

    * `:policy` — an **editorial preference** of the page, stated by the
      page: *where The Devil's Dictionary defines a word, its entry leads*. A
      preference about voice, not a claim of factual authority.
    * `:source_match` — a **source record**: a factual statement derived from
      data the registry holds and the public may see (*the catalog records
      this work as depicting Q316; the encyclopedia links this meaning to
      Q316*). No person or model wrote it, and a relationship a reviewer
      rejected never becomes one.
    * `:editorial` — a **note** written by whoever selected the item. `author`
      names them and says what they are (`:human`, `:model` — shown as
      AI-generated — or `:fixture`), and `reviewed_by` is `nil` until a
      person has reviewed it. A generated note is never presented as a
      quotation or as the words of a historical author.
  """

  @enforce_keys [:kind, :text]
  defstruct kind: nil, text: nil, author: nil, reviewed_by: nil, reviewed_on: nil

  @type author :: %{kind: :human | :model | :fixture, label: String.t()}

  @type t :: %__MODULE__{
          kind: :policy | :source_match | :editorial,
          text: String.t(),
          author: author() | nil,
          reviewed_by: String.t() | nil,
          reviewed_on: Date.t() | nil
        }
end
