defmodule DevilsDictionary.Curation.Opening.Credit do
  @moduledoc """
  One line of an item's credit: a `label` the reader sees (*Source*, *Image*,
  *Rights*), the `text` exactly as the source or its row states it, and the
  `href` it links to, if any.

  The text is never composed from a template of our own. A source's credit is
  its row's `attribution`; an image's is the credit the catalog committed; a
  quotation's citation is the `ref` its source wrote. A credit a licence
  requires is rendered whole and never clamped (#116 M4).
  """

  @enforce_keys [:label, :text]
  defstruct role: nil, label: nil, text: nil, href: nil

  @type t :: %__MODULE__{
          role: atom() | nil,
          label: String.t(),
          text: String.t(),
          href: String.t() | nil
        }
end
