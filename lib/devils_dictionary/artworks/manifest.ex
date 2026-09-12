defmodule DevilsDictionary.Artworks.Manifest do
  @moduledoc "Versioned, credential-free artwork seed manifests with resumable per-record outcomes."

  @schema_version 1

  def new(candidates, metadata \\ %{}) when is_list(candidates) do
    %{
      "schema_version" => @schema_version,
      "generated_at" => timestamp(),
      "selection" => Map.merge(default_selection(), stringify(metadata)),
      "candidates" =>
        candidates
        |> Enum.uniq_by(&{&1["qid"], &1["artsy_artwork_slug"]})
        |> Enum.map(&Map.put_new(&1, "import", %{"status" => "pending"}))
    }
    |> put_checksum()
  end

  def load!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    unless manifest["schema_version"] == @schema_version and is_list(manifest["candidates"]) do
      raise ArgumentError, "unsupported artwork seed manifest"
    end

    expected = checksum(Map.delete(manifest, "checksum"))

    unless manifest["checksum"] == expected,
      do: raise(ArgumentError, "artwork manifest checksum mismatch")

    manifest
  end

  def save!(manifest, path) do
    manifest = manifest |> Map.put("updated_at", timestamp()) |> put_checksum()
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, Jason.encode!(manifest, pretty: true) <> "\n")
    File.rename!(temporary, path)
    manifest
  end

  def update_candidate(manifest, index, outcome) when is_integer(index) and is_map(outcome) do
    candidates =
      List.update_at(manifest["candidates"], index, fn candidate ->
        Map.put(candidate, "import", stringify(outcome))
      end)

    manifest |> Map.put("candidates", candidates) |> put_checksum()
  end

  def completed?(candidate),
    do:
      get_in(candidate, ["import", "status"]) in ~w(matched created skipped conflict unavailable)

  def checksum(value) do
    :sha256
    |> :crypto.hash(Jason.encode!(value))
    |> Base.encode16(case: :lower)
  end

  defp put_checksum(manifest),
    do: Map.put(manifest, "checksum", checksum(Map.delete(manifest, "checksum")))

  defp default_selection do
    %{
      "artwork_kinds" => ["painting"],
      "identity" => "Wikidata QID plus P11005; title is never identity",
      "pilot_cap" => 500,
      "wikipedia_required" => false
    }
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
