defmodule DevilsDictionary.Curation.Opening.Reason do
  @moduledoc """
  Why an item is in the opening, and — always — who says so.

  Three kinds, which the component draws differently so they can never be
  mistaken for one another or for the quoted source text:

    * `:policy` — a rule of the page, stated by the page: *an applicable
      Devil's Dictionary entry leads*.
    * `:source_match` — derived from data the registry holds: *the catalog
      records this work as depicting Q316; the encyclopedia links this meaning
      to Q316*. No person or model wrote it.
    * `:editorial` — a note written by whoever selected the item. `author`
      names them and says what they are (`:human`, `:model`, or `:fixture` for
      a development fixture), and `reviewed_by` is `nil` until a person has
      reviewed it. A generated note is never presented as a quotation.
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
