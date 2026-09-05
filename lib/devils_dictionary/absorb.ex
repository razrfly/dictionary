defmodule DevilsDictionary.Absorb do
  @moduledoc """
  The import layer.

  Holds the `DevilsDictionary.Absorb.Source` behaviour (one module per provider,
  human channel or bot under `Absorb.Sources`), the `Materializer` (turns a raw
  `source_record` into normalized rows inside one transaction), the `ScopeBuilder`
  (rules → `scope_lexemes` with reasons), the `Resolver` (lexical relation targets
  and canonical variants) and the `Linker` (the word ↔ thing ladder).

  Spec: https://github.com/razrfly/dictionary/issues/69 §5.
  Build order: https://github.com/razrfly/dictionary/issues/70.
  """
end
