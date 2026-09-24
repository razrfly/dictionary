defmodule DevilsDictionary.Artworks.Corpus.Seeder do
  @moduledoc """
  The seeder's old name, kept for one release (#174).

  The seeder moved to `DevilsDictionary.Corpus.Seeder` when it gained its
  second kind of content, the public-domain Wikiquote corpus. This module
  delegates every public function to it, unchanged, so a caller or a script
  written against the old name keeps working until the alias is removed.

  Not marked `@deprecated`: the artworks corpus's existing tests call this
  name on purpose, as the proof that the move changed nothing, and the gate
  compiles with warnings as errors. Remove this file, and point those tests at
  the new name, in the release after #174.
  """

  defdelegate run(manifest, opts \\ []), to: DevilsDictionary.Corpus.Seeder

  defdelegate run_file(path, opts \\ []), to: DevilsDictionary.Corpus.Seeder

  defdelegate entry(kind, version, row), to: DevilsDictionary.Corpus.Seeder

  defdelegate catalog_counts(), to: DevilsDictionary.Corpus.Seeder
end
