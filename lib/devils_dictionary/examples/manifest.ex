defmodule DevilsDictionary.Examples.Manifest do
  @moduledoc """
  An exemplar manifest (#181 build 2): a committed, checksummed list of
  things someone cites as examples of a meaning, under `priv/exemplars/`.

  The manifest is the nomination path a bot will reuse: a persona (#97) or
  the assessor (#101) changes who *writes the file*, never the seeder. So the
  shape is the interface, and it is small:

      {
        "schema_version": 1,
        "kind": "exemplars",
        "manifest": "first-v1",
        "rows": [
          {
            "word": "coward",
            "sense": {"source": "wordnet", "match": "shows fear or timidity"},
            "subject": {"wikidata": "Q312556", "label": "Jeff Bezos", "kind": "person"},
            "rationale": "…",
            "evidence": [{"url": "https://…", "attribution": "CNN, 25 October 2024",
                          "role": "supports"}],
            "curator": "holden"
          }
        ],
        "row_count": 1,
        "checksum": "…"
      }

    * `sense.match` names a **meaning**, never a sense id: a case-insensitive
      substring of one current gloss from `sense.source`, resolved at seed time
      (`Examples.Seeder`), so a refresh cannot silently move it.
    * `subject.wikidata` is the identity. `subject.label` is a note for the
      person reading the file and is **never** used to find anyone (#164).
      A subject with no QID must name an existing entity by `subject.entity_id`.
    * `evidence` is at least one URL for a person (#105 rule 2); every row
      may carry `contradicts` entries beside its `supports` ones.

  ## The checksum

  Computed over everything but itself, as the corpus manifests are
  (`Artworks.Corpus.Manifest.checksum/1`). A hand-edited manifest must be
  re-stamped (`mix dd.exemplars.seed <path> --stamp`), and one whose checksum
  does not match what it says is **refused** by `load!/1` — the file drifted
  from what its curator signed off.
  """

  alias DevilsDictionary.Artworks.Corpus.Manifest, as: CorpusManifest

  @schema_version 1
  @kind "exemplars"
  @dir "priv/exemplars"

  # The subject kinds an `illustrates` claim may have (`priv/predicates`),
  # as a manifest spells them. Content subjects (a GIF, a quotation) wait for
  # #105 step 5, which mints a content item first.
  @subject_kinds ~w(person organization event artifact work)
  @sense_sources ~w(wordnet wiktionary)
  @roles ~w(supports contradicts)

  @doc "Where exemplar manifests live."
  def dir, do: @dir

  @doc "The subject kinds a row may name."
  def subject_kinds, do: @subject_kinds

  @doc "Loads a manifest from disk, refusing a wrong shape or a drifted checksum."
  def load!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    unless manifest["schema_version"] == @schema_version and manifest["kind"] == @kind and
             is_binary(manifest["manifest"]) and is_list(manifest["rows"]) do
      raise ArgumentError, "not an exemplar manifest: #{path}"
    end

    unless manifest["checksum"] == checksum(manifest) do
      raise ArgumentError,
            "exemplar manifest checksum mismatch: #{path} (edited since it was stamped; " <>
              "re-stamp with mix dd.exemplars.seed #{path} --stamp)"
    end

    manifest
  end

  @doc "The digest a manifest is verified against: everything but `checksum`."
  def checksum(manifest), do: manifest |> Map.delete("checksum") |> CorpusManifest.checksum()

  @doc "Writes a manifest with its row count and checksum refreshed."
  def stamp!(path) do
    manifest = path |> File.read!() |> Jason.decode!()
    manifest = Map.put(manifest, "row_count", length(manifest["rows"] || []))
    manifest = Map.put(manifest, "checksum", checksum(manifest))
    File.write!(path, Jason.encode!(manifest, pretty: true) <> "\n")
    manifest
  end

  @doc """
  Whether one row is well formed, before anything reads the database.

  `:ok` or `{:error, reason}`. Resolution — the sense, the subject — is the
  seeder's, because it needs the registry.
  """
  def validate_row(row) when is_map(row) do
    with :ok <- present(row["word"], :word_required),
         :ok <- sense(row["sense"]),
         :ok <- subject(row["subject"]),
         :ok <- present(row["rationale"], :rationale_required),
         :ok <- present(row["curator"], :curator_required),
         :ok <- evidence(row["evidence"]) do
      if row["subject"]["kind"] == "person" and supports(row["evidence"]) == [],
        do: {:error, :evidence_required_for_person},
        else: :ok
    end
  end

  def validate_row(_row), do: {:error, :row_not_an_object}

  defp sense(%{"source" => source, "match" => match}) when source in @sense_sources,
    do: present(match, :sense_match_required)

  defp sense(%{"source" => _}), do: {:error, :unsupported_sense_source}
  defp sense(_), do: {:error, :sense_required}

  defp subject(%{"kind" => kind} = subject) when kind in @subject_kinds do
    case {subject["wikidata"], subject["entity_id"]} do
      # #105 rule 3: a QID or an entity the registry already holds. A name
      # alone is nobody (#165 option 1: no QID, no nomination).
      {nil, nil} -> {:error, :subject_without_identity}
      {qid, _} when is_binary(qid) -> if qid?(qid), do: :ok, else: {:error, :invalid_qid}
      {nil, id} when is_integer(id) -> :ok
      _ -> {:error, :invalid_subject_identity}
    end
  end

  defp subject(%{"kind" => _}), do: {:error, :unsupported_subject_kind}
  defp subject(_), do: {:error, :subject_required}

  defp evidence(entries) when is_list(entries) do
    if Enum.all?(entries, &evidence_entry?/1), do: :ok, else: {:error, :invalid_evidence}
  end

  defp evidence(nil), do: :ok
  defp evidence(_), do: {:error, :invalid_evidence}

  defp evidence_entry?(%{"url" => url, "attribution" => attribution} = entry) do
    http_url?(url) and is_binary(attribution) and String.trim(attribution) != "" and
      Map.get(entry, "role", "supports") in @roles
  end

  defp evidence_entry?(_), do: false

  defp supports(entries),
    do: Enum.filter(entries || [], &(Map.get(&1, "role", "supports") == "supports"))

  defp present(value, reason) do
    if is_binary(value) and String.trim(value) != "", do: :ok, else: {:error, reason}
  end

  defp qid?(value), do: Regex.match?(~r/\AQ[1-9]\d*\z/, value)

  defp http_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.length(value) <= 255

      _ ->
        false
    end
  end

  defp http_url?(_), do: false
end
