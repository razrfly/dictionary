defmodule DevilsDictionary.DictionaryAPI do
  @moduledoc """
  The Dictionary API context.

  Handles integration with external dictionary APIs:
  - Merriam-Webster (Middle Class tier)
  - Free Dictionary API (free fallback)
  - Urban Dictionary (Plebs tier)

  Uses Cachex for caching responses and Oban for background fetching.
  """

  # API client modules will be added in Phase 4
  # Cache management will be added in Phase 4
  # Background job workers will be added in Phase 4
end
