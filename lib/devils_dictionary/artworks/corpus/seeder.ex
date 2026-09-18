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

  Options: `:dry_run` (resolve nothing, just count what would be seeded),
  `:limit` (seed only the first N rows) and `:refresh`.

  ## `:refresh`

  `SourceIdentity.resolve/1` never replaces a field an identity already holds —
  an absorbed record must not be overwritten by a manifest-shaped summary. That
  is right for identity and description, and wrong for the handful of display
  facts a committed manifest *is* the source of: the image URL and the credit
  that travels with it, and the depicted QIDs the lookup matches on. Correcting
  a manifest would otherwise reach the database only by deleting rows.

  So `refresh: true` rewrites exactly those keys, and only on an identity this
  manifest already owns — one whose metadata carries this manifest's `corpus`
  version. It mints nothing and touches no other row.
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
              # Ownership is read before the resolve, not after: resolving fills
              # this manifest's missing keys onto whatever identity it matched,
              # so afterwards an absorbed record carries the `corpus` marker too
              # and would look owned when it is not.
              owned? = opts[:refresh] && corpus_owned?(entry, version)
              resolution = SourceIdentity.resolve(entry)
              refreshed? = owned? && refresh(resolution, entry)

              summary
              |> tally(resolution.state, row)
              |> Map.update!(:refreshed, &if(refreshed?, do: &1 + 1, else: &1))
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
      refreshed: 0,
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

  @owned_display_keys ~w(image_url image_attribution credit_line depicts depicts_qids sitelinks)

  # A row this manifest has not seeded yet is its own to write; a row it seeded
  # before carries its version. Anything else belongs to whoever put it there.
  defp corpus_owned?(entry, version) do
    identifier = entry.stable_identifier

    case Registry.by_external_id(identifier.namespace, identifier.external_id) do
      nil ->
        true

      object_id ->
        DevilsDictionary.Repo.get!(Registry.Entity, object_id).metadata["corpus"] == version
    end
  end

  defp refresh(%{object_id: object_id}, entry) when is_integer(object_id) do
    entity = DevilsDictionary.Repo.get!(Registry.Entity, object_id)
    owned = Map.take(entry.metadata, @owned_display_keys)

    if Map.take(entity.metadata, Map.keys(owned)) == owned do
      false
    else
      entity
      |> Registry.Entity.changeset(%{metadata: Map.merge(entity.metadata, owned)})
      |> DevilsDictionary.Repo.update!()

      true
    end
  end

  defp refresh(_resolution, _entry), do: false

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
        label: label(title),
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
        label: label(title),
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

  @doc false
  def entry("poetrydb", version, row) do
    with {:ok, poem_id} <- required(row["poem_id"]),
         {:ok, title} <- required(row["title"]),
         {:ok, author} <- required(row["author"]) do
      Entry.new(%{
        source_slug: "poetrydb",
        object_kind: :entity,
        entity_kind: :work,
        work_kind: "poem",
        stable_identifier: %{namespace: "poetrydb_poem", external_id: poem_id},
        # The poet's QID is **not** among these. A poem is not the person who
        # wrote it, and registering `wikidata: Q82083` on *Ode to a Nightingale*
        # would claim it is Keats — and collide with the entity that actually is.
        # The crosswalk is recorded as what it is: a fact about the author.
        identifiers: [%{namespace: "poetrydb_poem", external_id: poem_id}],
        label: label(title),
        metadata:
          %{
            "content_type" => "text",
            "catalog_source" => "poetrydb",
            "corpus" => version,
            "author_display_name" => author
          }
          |> put_present("author_qid", row["author_qid"])
          |> put_present("lines_sha256", row["lines_sha256"])
          |> put_present("source_url", row["source_url"])
          |> put_line_count(row["line_count"]),
        eligibility: :eligible,
        retention: :durable
      })
    end
  end

  @doc false
  def entry("open-library", version, row) do
    with {:ok, olid} <- required(row["olid"]),
         {:ok, title} <- required(row["title"]) do
      Entry.new(%{
        source_slug: "open-library",
        object_kind: :entity,
        entity_kind: :work,
        work_kind: "book",
        stable_identifier: %{namespace: "olid", external_id: olid},
        # The work's own Wikidata QID belongs here — unlike PoetryDB's
        # `author_qid`, this one is about *this work* and not about the person
        # who wrote it, so registering it collides with nothing. The authors'
        # QIDs stay in metadata, where they are facts about the authors.
        identifiers: [%{namespace: "olid", external_id: olid}] ++ wikidata_identifier(row["qid"]),
        label: label(title),
        year: row["year"],
        metadata:
          %{
            "content_type" => "text",
            "catalog_source" => "open-library",
            "corpus" => version
          }
          |> put_present("author_display_name", author_names(row))
          |> put_present("author_qids", author_qids(row))
          |> put_present("public_domain_basis", row["pd_basis"])
          |> put_present("source_url", row["source_url"])
          |> put_present("wikidata_url", row["wikidata_url"])
          |> put_sitelinks(row["sitelinks"]),
        eligibility: :eligible,
        retention: :durable
      })
    end
  end

  def entry(kind, _version, _row), do: {:error, "unsupported_manifest_kind_#{kind}"}

  defp wikidata_identifier(qid) do
    if is_binary(qid) and valid_qid?(qid),
      do: [%{namespace: "wikidata", external_id: qid, metadata: %{"field" => "P648_subject"}}],
      else: []
  end

  defp author_names(%{"authors" => authors}) when is_list(authors) do
    authors |> Enum.map(& &1["name"]) |> Enum.filter(&present?/1) |> Enum.join(", ") |> presence()
  end

  defp author_names(_row), do: nil

  defp author_qids(%{"authors" => authors}) when is_list(authors) do
    case authors |> Enum.map(& &1["qid"]) |> Enum.filter(&(is_binary(&1) and valid_qid?(&1))) do
      [] -> nil
      qids -> qids
    end
  end

  defp author_qids(_row), do: nil

  # `entities.preferred_label` is varchar(255) and Postgres counts characters,
  # not bytes, so this is the column's own width. Met highlight titles reach it:
  # "Rebel Cassion Destroyed by Federal Shells. At Fredericksburgh, May 3, 1863.
  # Eight Horses Killed." is one of the shorter long ones.
  defp label(title), do: String.slice(title, 0, 255)

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

  defp put_line_count(map, count) when is_integer(count), do: Map.put(map, "line_count", count)
  defp put_line_count(map, _count), do: map

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
