defmodule DevilsDictionary.Curation.OpeningReader do
  @moduledoc """
  The seam between *where a selection is stored* and *how it is shown* (#156,
  #196).

  A reader takes a built `DevilsDictionary.Lexicon.WordPage` and returns the
  `DevilsDictionary.Curation.Opening` to render above its Definitions, or
  `nil`. Two rules every implementation keeps:

    * **Read-time revalidation, never substitution.** An item whose exact
      revision is no longer current, whose source record may no longer be
      displayed, or whose object has left the registry is withheld and named
      in `Opening.withheld`. Another item is never put in its place.
    * **No network, no inference.** A reader reads the database. It never
      asks a discovery provider, never calls a model and never writes.

  `DevilsDictionary.Curation.ManualFixture` is the Phase 1 implementation and
  exists for development only. #196's approved-composition reader replaces it
  without the component or the page changing.
  """

  alias DevilsDictionary.Curation.Opening

  @callback opening(page :: map(), opts :: keyword()) :: Opening.t() | nil
end
