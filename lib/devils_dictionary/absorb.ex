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

  alias DevilsDictionary.Absorb.Sources

  @modules %{
    "wordnet" => Sources.Wordnet,
    "wiktionary" => Sources.Wiktionary,
    "wikidata" => Sources.Wikidata,
    "wikipedia" => Sources.Wikipedia,
    "bierce" => Sources.Bierce,
    "johnson" => Sources.Johnson
  }

  @doc """
  The module implementing `DevilsDictionary.Absorb.Source` for a source slug.

  Adding a source is a `sources` row plus one entry here (scorecard E1: zero
  migrations).
  """
  def source_module(slug) do
    case Map.fetch(@modules, slug) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_source, slug, Map.keys(@modules)}}
    end
  end

  def source_module!(slug) do
    case source_module(slug) do
      {:ok, module} ->
        module

      {:error, {:unknown_source, slug, known}} ->
        raise ArgumentError,
              "no absorb module for #{inspect(slug)}; known: #{Enum.join(known, ", ")}"
    end
  end

  @doc """
  Source slugs that have an absorb module today.
  """
  def implemented, do: Map.keys(@modules)
end
