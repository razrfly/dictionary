defmodule DevilsDictionary.Curation.Opening.Meaning do
  @moduledoc """
  The meaning an opening item was selected for (#156: every selection carries
  an intended meaning, and a composition may span the page's meanings).

  `:sense` is one source's meaning at an exact revision — its gloss is the
  label, verbatim. `:lexeme` is a whole word and part of speech, which is what
  a definition *defines*: Bierce's entry is about *love* the noun, not about
  one of WordNet's six senses of it.

  `anchor` is the element on this page where the meaning is written, when
  there is one.
  """

  @enforce_keys [:kind, :object_id, :label]
  defstruct kind: nil,
            object_id: nil,
            sense_revision_id: nil,
            lexeme_id: nil,
            label: nil,
            part_of_speech: nil,
            source: nil,
            anchor: nil

  @type t :: %__MODULE__{
          kind: :sense | :lexeme,
          object_id: pos_integer(),
          sense_revision_id: pos_integer() | nil,
          lexeme_id: pos_integer() | nil,
          label: String.t(),
          part_of_speech: String.t() | nil,
          source: %{slug: String.t(), name: String.t()} | nil,
          anchor: String.t() | nil
        }
end
