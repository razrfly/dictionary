defmodule DevilsDictionary.Artworks.Manifest do
  @moduledoc "Versioned, credential-free artwork seed manifests with resumable per-record outcomes."

  @schema_version 2
  @terminal_statuses ~w(matched created skipped conflict unavailable)

  @doc "Creates a portable manifest with every unique exact identity pending."
  def new(candidates, metadata \\ %{}) when is_list(candidates) do
    %{
      "schema_version" => @schema_version,
      "generated_at" => timestamp(),
      "selection" => Map.merge(default_selection(), stringify(metadata)),
      "candidates" =>
        candidates
        |> Enum.uniq_by(&{&1["qid"], &1["artsy_artwork_slug"]})
        |> Enum.map(
          &Map.put_new(&1, "import", %{
            "status" => "pending",
            "stages" => default_stages()
          })
        )
    }
    |> put_checksum()
  end

  @doc "Loads and verifies a supported checksummed manifest."
  def load!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    unless manifest["schema_version"] in [1, @schema_version] and
             is_list(manifest["candidates"]) do
      raise ArgumentError, "unsupported artwork seed manifest"
    end

    expected = checksum(Map.delete(manifest, "checksum"))

    unless manifest["checksum"] == expected,
      do: raise(ArgumentError, "artwork manifest checksum mismatch")

    upgrade(manifest)
  end

  @doc """
  Whether two manifests describe the same ordered set of exact identities.

  A checkpoint is a manifest whose import state has moved on, so its own
  checksum always differs from the base manifest's. Identity is what must not
  differ: resuming a checkpoint built from a different selection would silently
  process the wrong candidates.
  """
  def same_selection?(left, right) when is_map(left) and is_map(right),
    do: identities(left) == identities(right)

  defp identities(manifest) do
    manifest
    |> Map.get("candidates", [])
    |> Enum.map(&{&1["qid"], &1["artsy_artwork_slug"]})
  end

  @doc "Atomically saves a manifest with a refreshed checksum."
  def save!(manifest, path) do
    manifest = manifest |> Map.put("updated_at", timestamp()) |> put_checksum()
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, Jason.encode!(manifest, pretty: true) <> "\n")
    File.rename!(temporary, path)
    manifest
  end

  @doc "Merges one resumable import outcome into a candidate by index."
  def update_candidate(manifest, index, outcome) when is_integer(index) and is_map(outcome) do
    candidates =
      List.update_at(manifest["candidates"], index, fn candidate ->
        previous = candidate["import"] || %{}
        Map.put(candidate, "import", deep_merge(previous, stringify(outcome)))
      end)

    manifest |> Map.put("candidates", candidates) |> put_checksum()
  end

  @doc "Returns true only for an import outcome that does not need resuming."
  def completed?(candidate), do: get_in(candidate, ["import", "status"]) in @terminal_statuses

  @doc "Lists terminal candidate status strings."
  def terminal_statuses, do: @terminal_statuses

  @doc "Returns the deterministic SHA-256 digest used by manifest verification."
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

  defp default_stages do
    %{
      "wikidata" => %{"status" => "pending"},
      "artwork" => %{"status" => "pending"},
      "artists" => %{"status" => "pending", "next_cursor" => nil},
      "genes" => %{"status" => "pending", "next_cursor" => nil},
      "identity" => %{"status" => "pending"},
      "creators" => %{"status" => "pending"}
    }
  end

  defp upgrade(%{"schema_version" => @schema_version} = manifest), do: manifest

  defp upgrade(manifest) do
    manifest
    |> Map.put("schema_version", @schema_version)
    |> Map.update!("candidates", fn candidates ->
      Enum.map(candidates, fn candidate ->
        import = candidate["import"] || %{"status" => "pending"}
        Map.put(candidate, "import", Map.put_new(import, "stages", default_stages()))
      end)
    end)
    |> put_checksum()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
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
