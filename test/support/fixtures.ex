defmodule DevilsDictionary.Fixtures do
  @moduledoc """
  Loads the real source records checked in under `test/support/fixtures`.

  These are verbatim records captured by `mix dd.fixtures.capture`, so tests
  exercise what the sources actually emit and run with no network (scorecard
  O3). Wiktionary fixtures are **untrimmed**, because M4 measures the saving
  `trim/1` produces and needs the denominator.
  """

  alias DevilsDictionary.Sources.{Catalog, SourceRecord}

  @dir Path.expand("fixtures", __DIR__)

  @doc """
  Every raw record captured for a lemma from a source.
  """
  def raw(source, lemma) do
    [@dir, source, "#{lemma}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("records")
  end

  @doc """
  The first raw record for a lemma.
  """
  def one_raw(source, lemma), do: raw(source, lemma) |> hd()

  @doc """
  Wraps a raw payload in an unsaved `SourceRecord`, which is all a pure
  `materialize/1` needs.
  """
  def source_record(raw, attrs \\ []) do
    %SourceRecord{
      id: attrs[:id] || 1,
      source_id: attrs[:source_id] || 1,
      external_id: attrs[:external_id] || raw["id"],
      raw: raw
    }
  end

  @doc """
  Upserts the source catalog. Seeds do not run in `:test`, so tests that need
  real `sources` rows call this.
  """
  def seed_catalog!, do: Catalog.seed!()
end
