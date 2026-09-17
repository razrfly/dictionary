defmodule DevilsDictionary.Artworks.Corpus.Seeder do
  @moduledoc """
  Seeds a committed corpus manifest into the existing encyclopedia structures.

  Zero new tables. An artwork is what #86 made it: an `entities` row with
  `work_details.work_kind == "artwork"` and its identity in
  `external_identifiers` — namespace `met_object_id` for a Met object,
  `wikidata` for a QID (both, when the Met publishes the object's QID). That is
  the same shape the Artsy pilot and the Phase 2a discovery provider resolve to,
  which is why the three read as one catalog.

  ## Why the depicted QIDs are metadata

  Every Met row carries its tag QIDs and every Wikidata row its `P180`
  depictions, so a word page can ask *which artworks depict Q198* without a live
  search. Those QIDs are not identity — an artwork is not the thing it depicts —
  and the depicted concept usually has no local entity to point a claim at, so
  they are stored on the artwork's `metadata` as `depicts` (term + QID) and
  `depicts_qids` (the flat list the lookup filters on). A claim would need an
  object; this needs only a match key.

  ## Idempotence

  The manifest is the whole input and `SourceIdentity.resolve/1` is the whole
  write: a second run of the same manifest matches every row on its exact
  identifier and updates nothing that is already filled, so the counts come back
  identical. Nothing here consults a title.
  """

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Registry
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Entry

  @met_collection "The Metropolitan Museum of Art"

  @doc """
  Seeds one loaded manifest and returns a summary.

  Options: `:dry_run` (resolve nothing, just count what would be seeded) and
  `:limit` (seed only the first N rows).
  """
  def run(manifest, opts \\ []) when is_map(manifest) do
    rows = manifest["rows"] |> List.wrap() |> take(opts[:limit])
    kind = manifest["kind"]
    version = manifest["manifest"]

    summary =
      Enum.reduce(rows, empty_summary(kind, version, length(rows)), fn row, summary ->
        case entry(kind, version, row) do
          {:ok, entry} ->
            if opts[:dry_run] do
              tally(summary, :would_seed, row)
            else
              resolution = SourceIdentity.resolve(entry)
              tally(summary, resolution.state, row)
            end

          {:error, reason} ->
            summary
            |> tally(:invalid, row)
            |> Map.update!(
              :invalid_reasons,
              &Map.update(&1, to_string(reason), 1, fn n -> n + 1 end)
            )
        end
      end)

    {:ok, Map.delete(summary, :depicted_qid_set)}
  end

  @doc "Loads a committed manifest from disk and seeds it."
  def run_file(path, opts \\ []) do
    path |> Manifest.load!() |> run(opts)
  end

  defp take(rows, nil), do: rows
  defp take(rows, limit) when is_integer(limit), do: Enum.take(rows, limit)

  defp empty_summary(kind, version, count) do
    %{
      kind: kind,
      manifest: version,
      rows: count,
      newly_created: 0,
      matched: 0,
      would_seed: 0,
      insufficient_evidence: 0,
      conflicting_identifiers: 0,
      invalid: 0,
      invalid_reasons: %{},
      with_image: 0,
      with_depicts: 0,
      depicted_qids: 0,
      depicted_qid_set: MapSet.new()
    }
  end

  defp tally(summary, state, row) do
    depicts = depicts(row)

    summary
    |> Map.update!(state, &(&1 + 1))
    |> Map.update!(:with_image, &if(present?(row["image_url"]), do: &1 + 1, else: &1))
    |> Map.update!(:with_depicts, &if(depicts != [], do: &1 + 1, else: &1))
    |> Map.update!(:depicted_qid_set, fn set ->
      Enum.reduce(depicts, set, &MapSet.put(&2, &1["qid"]))
    end)
    |> then(&Map.put(&1, :depicted_qids, MapSet.size(&1.depicted_qid_set)))
  end

  @doc "The provider-neutral identity proposal for one manifest row."
  def entry("met-highlights", version, row) do
    with {:ok, met_id} <- required(row["met_object_id"]),
         {:ok, title} <- required(row["title"]) do
      Entry.new(%{
        source_slug: "met",
        object_kind: :entity,
        entity_kind: :work,
        work_kind: "artwork",
        stable_identifier: %{namespace: "met_object_id", external_id: met_id},
        identifiers:
          [%{namespace: "met_object_id", external_id: met_id}] ++
            qid_identifier(row["qid"]),
        label: String.slice(title, 0, 300),
        year: begin_year(row["date"]),
        metadata:
          base_metadata(row, version, "met")
          |> put_present("artist_display_name", row["artist"])
          |> put_present("object_date", row["date"])
          |> put_present("medium", row["medium"])
          |> put_present("department", row["department"])
          |> Map.put("collection", @met_collection),
        eligibility: :eligible,
        retention: :durable
      })
    end
  end

  def entry("wikidata-famous", version, row) do
    with {:ok, qid} <- required(row["qid"]),
         {:ok, title} <- required(row["title"]) do
      Entry.new(%{
        source_slug: "wikidata",
        object_kind: :entity,
        entity_kind: :work,
        work_kind: "artwork",
        stable_identifier: %{namespace: "wikidata", external_id: qid},
        identifiers: [%{namespace: "wikidata", external_id: qid}],
        label: String.slice(title, 0, 300),
        year: begin_year(row["date"]),
        metadata:
          base_metadata(row, version, "wikidata")
          |> put_present("artist_display_name", creator_names(row))
          |> put_present("object_date", row["date"])
          |> put_present("commons_file", row["commons_file"])
          |> put_present("creator_qids", creator_qids(row))
          |> put_sitelinks(row["sitelinks"]),
        eligibility: :eligible,
        retention: :durable
      })
    end
  end

  def entry(kind, _version, _row), do: {:error, "unsupported_manifest_kind_#{kind}"}

  defp base_metadata(row, version, catalog_source) do
    depicts = depicts(row)

    %{
      "content_type" => "artwork",
      "catalog_source" => catalog_source,
      "corpus" => version,
      "depicts" => depicts,
      "depicts_qids" => Enum.map(depicts, & &1["qid"])
    }
    |> put_present("image_url", row["image_url"])
    |> put_present("image_attribution", row["credit_line"])
    |> put_present("credit_line", row["credit_line"])
    |> put_present("source_url", row["source_url"])
  end

  # A Met tag and a Wikidata `P180` statement are the same assertion in two
  # vocabularies — *this picture shows that concept* — so they normalize to one
  # shape and one lookup key.
  defp depicts(row) do
    (row["tags"] || row["depicts"] || [])
    |> Enum.flat_map(fn
      %{"qid" => qid} = entry when is_binary(qid) ->
        if valid_qid?(qid), do: [%{"qid" => qid, "term" => presence(entry["term"])}], else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  defp qid_identifier(qid) do
    if is_binary(qid) and valid_qid?(qid),
      do: [
        %{namespace: "wikidata", external_id: qid, metadata: %{"field" => "objectWikidata_URL"}}
      ],
      else: []
  end

  defp creator_names(row) do
    (row["creators"] || [])
    |> Enum.map(& &1["term"])
    |> Enum.filter(&present?/1)
    |> Enum.join(", ")
    |> presence()
  end

  defp creator_qids(row) do
    (row["creators"] || [])
    |> Enum.map(& &1["qid"])
    |> Enum.filter(&(is_binary(&1) and valid_qid?(&1)))
    |> case do
      [] -> nil
      qids -> qids
    end
  end

  defp put_sitelinks(metadata, count) when is_integer(count),
    do: Map.put(metadata, "sitelinks", count)

  defp put_sitelinks(metadata, _count), do: metadata

  # `objectDate` and an inception year are free text — "ca. 1780", "1863–65".
  # The first four-digit run is the only part of them that is a year.
  defp begin_year(value) when is_binary(value) do
    case Regex.run(~r/\d{4}/, value) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp begin_year(_value), do: nil

  defp required(value) do
    if present?(value), do: {:ok, String.trim(value)}, else: {:error, :missing_required_field}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_qid?(value), do: Regex.match?(~r/\AQ[1-9]\d*\z/, value)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  @doc "How many artworks the catalog currently holds, by catalog source."
  def catalog_counts do
    import Ecto.Query

    DevilsDictionary.Repo.all(
      from entity in Registry.Entity,
        join: details in Registry.WorkDetails,
        on: details.entity_id == entity.object_id and details.work_kind == "artwork",
        group_by: fragment("COALESCE(?->>'catalog_source', 'unlabelled')", entity.metadata),
        select:
          {fragment("COALESCE(?->>'catalog_source', 'unlabelled')", entity.metadata),
           count(entity.object_id)}
    )
    |> Map.new()
  end
end
