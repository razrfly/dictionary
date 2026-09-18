defmodule DevilsDictionary.Artworks.Corpus.Manifest do
  @moduledoc """
  A committed, checksummed artwork corpus manifest.

  The #99 P0 probe measured the Met's search totals as parameter-sensitive: the
  same highlight query answered 2,310, 2,299 and 62 depending on the order the
  parameters were written in. A corpus that re-ran its own search would
  therefore be a different corpus every time it was seeded, and nobody could say
  which objects a given page had been showing. So the object list is built once,
  written to `priv/artworks/manifests/`, committed, and read from disk by the
  seeder — which never makes a provider call.

  This is a sibling of `DevilsDictionary.Artworks.Manifest`, not a replacement:
  that one is the Artsy pilot's resumable *import* state, keyed on
  `qid` + `artsy_artwork_slug`. This one is a durable *selection* keyed on one
  identity namespace per manifest, with no import state in it at all — the
  seeder is idempotent against the database instead, so a committed file never
  needs rewriting to record what has already been seeded.
  """

  @schema_version 1

  # `identity` is the row field this kind is keyed and ordered on; `namespace`
  # is the `external_identifiers` namespace `Corpus.Seeder.entry/3` writes that
  # field to. They differ — a Wikidata row is keyed on `qid` and identified as
  # `wikidata` — so neither can be derived from the other, and a kind that
  # declared only the first left anything reading the seeded row back with a
  # hard-coded list of its own.
  # `work_kind` is the third registration, and it is here for the same reason
  # the other two are: nothing outside this table should hold a list of which
  # corpora are artworks. `Corpus.Conformance` counted seeded rows as
  # `work_kind == "artwork"` literally, which was true of both corpora until a
  # corpus of poems existed.
  @kinds %{
    "met-highlights" => %{
      source: "met",
      identity: "met_object_id",
      namespace: "met_object_id",
      work_kind: "artwork"
    },
    "wikidata-famous" => %{
      source: "wikidata",
      identity: "qid",
      namespace: "wikidata",
      work_kind: "artwork"
    },
    "poetrydb" => %{
      source: "poetrydb",
      identity: "poem_id",
      namespace: "poetrydb_poem",
      work_kind: "poem"
    }
  }

  @doc "The manifest kinds this module can build and read."
  def kinds, do: Map.keys(@kinds)

  @doc "The identity field of one manifest kind's rows."
  def identity_field(kind), do: Map.fetch!(@kinds, kind).identity

  @doc """
  The `external_identifiers` namespace this kind's identity field is written to.

  `Registry.by_external_id(identity_namespace(kind), row[identity_field(kind)])`
  is how a seeded row is found again, so a kind that registers one without the
  other cannot be read back.
  """
  def identity_namespace(kind), do: Map.fetch!(@kinds, kind).namespace

  @doc """
  The `work_details.work_kind` this kind's rows are seeded as.

  A corpus is a selection of *works*, and which kind of work is the manifest's
  own fact: `met-highlights` and `wikidata-famous` are artworks, `poetrydb` is
  poems. Anything counting seeded rows reads it from here rather than assuming.
  """
  def work_kind(kind), do: Map.fetch!(@kinds, kind).work_kind

  @doc "Builds a manifest, deduplicated on its kind's identity field and ordered by it."
  def new(kind, rows, metadata \\ %{}) when is_binary(kind) and is_list(rows) do
    spec = Map.fetch!(@kinds, kind)
    field = spec.identity

    %{
      "schema_version" => @schema_version,
      "manifest" => "#{kind}-v#{@schema_version}",
      "kind" => kind,
      "source" => spec.source,
      "identity" => field,
      "generated_at" => timestamp(),
      "selection" => stringify(metadata),
      "rows" =>
        rows
        |> Enum.map(&stringify/1)
        |> Enum.filter(&present?(&1[field]))
        |> Enum.uniq_by(& &1[field])
        |> Enum.sort_by(&sort_key(&1[field]))
    }
    |> put_row_count()
    |> put_checksum()
  end

  @doc "Loads and verifies a committed manifest of a known kind."
  def load!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    unless manifest["schema_version"] == @schema_version and
             is_map_key(@kinds, manifest["kind"]) and is_list(manifest["rows"]) do
      raise ArgumentError, "unsupported artwork corpus manifest: #{path}"
    end

    unless manifest["checksum"] == checksum(Map.delete(manifest, "checksum")) do
      raise ArgumentError, "artwork corpus manifest checksum mismatch: #{path}"
    end

    manifest
  end

  @doc "Whether a JSON file at `path` is a corpus manifest rather than an Artsy pilot manifest."
  def corpus_manifest?(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"kind" => kind}} -> is_map_key(@kinds, kind)
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "Atomically writes a manifest with a refreshed checksum."
  def save!(manifest, path) do
    manifest = manifest |> put_row_count() |> put_checksum()
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, Jason.encode!(manifest, pretty: true) <> "\n")
    File.rename!(temporary, path)
    manifest
  end

  @doc "The deterministic digest committed manifests are verified against."
  def checksum(value) do
    :sha256 |> :crypto.hash(Jason.encode!(value)) |> Base.encode16(case: :lower)
  end

  defp put_checksum(manifest),
    do: Map.put(manifest, "checksum", checksum(Map.delete(manifest, "checksum")))

  defp put_row_count(manifest),
    do: Map.put(manifest, "row_count", length(manifest["rows"] || []))

  # Met object ids are numbers written as strings; sorting them as text would
  # order 10065 before 1000 and make two builds of the same selection differ.
  defp sort_key(value) do
    case Integer.parse(value) do
      {integer, ""} -> {0, integer, value}
      _ -> {1, 0, value}
    end
  end

  defp stringify(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), stringify(inner)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
