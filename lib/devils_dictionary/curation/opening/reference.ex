defmodule DevilsDictionary.Curation.Opening.Reference do
  @moduledoc """
  Which durable thing an opening item is, and exactly which revision of it was
  read — the columns #196's `editorial_composition_items` holds as foreign keys.

    * `object_id` / `object_kind` — the `objects` row: a `:content` item (a
      definition), an `:entity` (a work) or a `:sense` (a meaning whose source
      filed a quotation under it).
    * `content_revision_id`, `sense_revision_id`, `source_record_revision_id`
      — the exact revisions, whichever apply. Immutable rows, so a reference
      keeps meaning what it meant.
    * `catalog` — `%{manifest, checksum}` for a work read from a committed
      corpus manifest, which is that work's source revision.
    * `locator` — where inside the revision: `%{kind: :sentences, count: n}`
      for a lead clipped at its first `n` sentences, `%{kind: :quotation,
      fingerprint: fp}` for one line of a sense's quotations (ADR 0003).
    * `assertion_revision_id` — an accepted `illustrates` claim, when the item
      relies on one: an exemplar's (#212), and `nil` for everything else.
      Highlighting a work or a line is presentation, not an implicit claim
      (#156); an exemplar *is* a claim, someone else's, and the opening shows
      it only once a reviewer has accepted it.
  """

  @enforce_keys [:object_id, :object_kind]
  defstruct object_id: nil,
            object_kind: nil,
            content_revision_id: nil,
            sense_revision_id: nil,
            source_record_revision_id: nil,
            catalog: nil,
            locator: nil,
            assertion_revision_id: nil

  @type t :: %__MODULE__{
          object_id: pos_integer(),
          object_kind: :content | :entity | :sense,
          content_revision_id: pos_integer() | nil,
          sense_revision_id: pos_integer() | nil,
          source_record_revision_id: pos_integer() | nil,
          catalog: %{manifest: String.t(), checksum: String.t()} | nil,
          locator: map() | nil,
          assertion_revision_id: pos_integer() | nil
        }
end
