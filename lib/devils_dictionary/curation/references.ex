defmodule DevilsDictionary.Curation.References do
  @moduledoc """
  Turns a selection's durable references into the registry rows they name, and
  says when a row is no longer eligible to show (#156, #196 read-time rules).

  A reference names things the way the sources do, so it survives a rebuild of
  the database from the same inputs:

    * a **definition** by its source record — `source` slug, `record`
      (`source_records.external_id`, e.g. `LOVE/n`) and the `revision_key` of
      the exact observation (the content hash) — which resolves to the
      `content_items` object materialized from that observation;
    * a **meaning** by its word's `lexical_key` (`en/love/noun`, lossless
      identity), its source, the source record and revision it came from, and
      its gloss as printed — a sense's own `external_key` is a position, never
      identity (`DevilsDictionary.Registry.Sense`);
    * a **work** by its verified Wikidata QID and the committed catalog
      manifest (name and checksum) it was seeded from.

  Every function answers `{:ok, row}` or `{:error, reason}`. The reasons are
  what a reader withholds an item for: `:not_found`, `:ambiguous`,
  `:object_inactive`, `:revision_not_current`, `:revision_inactive`,
  `:display_not_allowed`, `:source_inactive`, `:catalog_changed`,
  `:not_an_artwork`, `:no_image`. Nothing here writes and nothing leaves the
  database.
  """

  import Ecto.Query

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Claims.{AssertionRevision, Predicate}
  alias DevilsDictionary.Corpus.SourceRecordRevision

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    ExternalIdentifier,
    Lexeme,
    Object,
    Sense,
    SenseRevision,
    WorkDetails
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  @doc """
  The lexemes named by these lexical keys, as `%{key => %{object_id, lemma,
  part_of_speech, language}}`. A key with no row is absent from the map.
  """
  def lexemes([]), do: %{}

  def lexemes(keys) when is_list(keys) do
    Repo.all(
      from l in Lexeme,
        join: o in Object,
        on: o.id == l.object_id and o.lifecycle_state == :active,
        where: l.lexical_key in ^keys,
        select:
          {l.lexical_key,
           %{
             object_id: l.object_id,
             lemma: l.lemma,
             part_of_speech: l.part_of_speech,
             language: l.language_tag
           }}
    )
    |> Map.new()
  end

  @doc """
  The definition a source record's exact observation was materialized into.

  `ref` is `%{"source", "record", "revision_key"}`. The revision must still be
  the content item's **current** one: a lead quotes the text a reader can
  check, and a pinned revision that has been superseded is a changed source.
  """
  def content(%{"source" => slug, "record" => external_id, "revision_key" => key})
      when is_binary(slug) and is_binary(external_id) and is_binary(key) do
    rows =
      Repo.all(
        from rec in SourceRecord,
          join: source in Source,
          on: source.id == rec.source_id and source.slug == ^slug,
          join: srr in SourceRecordRevision,
          on: srr.source_record_id == rec.id and srr.revision_key == ^key,
          join: cr in ContentRevision,
          on: cr.source_record_revision_id == srr.id,
          join: ci in ContentItem,
          on: ci.object_id == cr.content_id,
          join: o in Object,
          on: o.id == ci.object_id,
          where: rec.external_id == ^external_id,
          select: %{
            object_id: ci.object_id,
            content_kind: ci.content_kind,
            object_state: o.lifecycle_state,
            content_revision_id: cr.id,
            revision_number: cr.revision_number,
            current?: cr.is_current,
            lifecycle_state: cr.lifecycle_state,
            body: cr.body,
            body_format: cr.body_format,
            headword: cr.headword,
            metadata: cr.metadata,
            year: cr.year,
            canonical_url: cr.canonical_url,
            source_record_revision_id: srr.id,
            display_allowed?: rec.display_allowed,
            source: source
          }
      )

    with {:ok, row} <- one(rows),
         :ok <- active(row.object_state),
         :ok <- current(row.current?, row.lifecycle_state),
         :ok <- displayable(row.display_allowed?, row.source) do
      {:ok, row}
    end
  end

  def content(_ref), do: {:error, :not_found}

  @doc "Whether content object `content_id` currently `defines` lexeme `lexeme_id` or one of its senses."
  def defines?(content_id, lexeme_id) do
    Repo.exists?(
      from r in AssertionRevision,
        join: p in Predicate,
        on: p.id == r.predicate_id and p.key == "defines",
        left_join: s in Sense,
        on: s.object_id == r.object_object_id,
        where:
          r.subject_object_id == ^content_id and r.is_current and r.lifecycle_state == :active and
            (r.object_object_id == ^lexeme_id or s.lexeme_id == ^lexeme_id)
    )
  end

  @doc """
  One source's meaning, at the exact revision a selection read.

  `ref` is `%{"lexeme", "source", "record", "revision_key", "gloss"}`: the
  word's lexical key, the source slug, the source record and observation the
  sense's current revision was materialized from, and the gloss verbatim.
  """
  def sense(
        %{
          "lexeme" => lexical_key,
          "source" => slug,
          "record" => external_id,
          "revision_key" => key,
          "gloss" => gloss
        } = _ref
      )
      when is_binary(lexical_key) and is_binary(slug) and is_binary(gloss) do
    rows =
      Repo.all(
        from s in Sense,
          join: l in Lexeme,
          on: l.object_id == s.lexeme_id and l.lexical_key == ^lexical_key,
          join: source in Source,
          on: source.id == s.source_id and source.slug == ^slug,
          join: rev in SenseRevision,
          on: rev.sense_id == s.object_id and rev.is_current,
          join: srr in SourceRecordRevision,
          on: srr.id == rev.source_record_revision_id and srr.revision_key == ^key,
          join: rec in SourceRecord,
          on: rec.id == srr.source_record_id and rec.external_id == ^external_id,
          join: o in Object,
          on: o.id == s.object_id,
          where: rev.gloss == ^gloss,
          select: %{
            object_id: s.object_id,
            identity_state: s.identity_state,
            object_state: o.lifecycle_state,
            external_key: s.external_key,
            sense_revision_id: rev.id,
            lifecycle_state: rev.lifecycle_state,
            gloss: rev.gloss,
            url: rev.url,
            examples: rev.examples,
            source_record_revision_id: srr.id,
            display_allowed?: rec.display_allowed,
            lexeme_id: l.object_id,
            lemma: l.lemma,
            part_of_speech: l.part_of_speech,
            source: source
          }
      )

    with {:ok, row} <- one(rows),
         :ok <- active(row.object_state),
         :ok <- sense_active(row.identity_state),
         :ok <- current(true, row.lifecycle_state),
         :ok <- displayable(row.display_allowed?, row.source) do
      {:ok, row}
    end
  end

  def sense(_ref), do: {:error, :not_found}

  @doc "The verified Wikidata QIDs a sense currently `refers_to`."
  def refers_to_qids(sense_id) do
    Repo.all(
      from r in AssertionRevision,
        join: p in Predicate,
        on: p.id == r.predicate_id and p.key == "refers_to",
        join: e in Entity,
        on: e.object_id == r.object_object_id,
        join: i in ExternalIdentifier,
        on: i.object_id == e.object_id and i.namespace == "wikidata" and i.status == :verified,
        where: r.subject_object_id == ^sense_id and r.is_current and r.lifecycle_state == :active,
        distinct: true,
        select: i.external_id
    )
  end

  @doc """
  A catalog artwork by its verified QID, seeded from the committed manifest a
  selection pinned.

  `ref` is `%{"wikidata", "catalog", "checksum"}`. The work must still be an
  active artwork from that manifest, the manifest committed now must carry the
  pinned checksum, and the catalog view must still have an image to show —
  `Artworks.get/1` is the view the shelf renders, so it applies the same
  display rules.
  """
  def work(%{"wikidata" => qid, "catalog" => manifest, "checksum" => checksum})
      when is_binary(qid) and is_binary(manifest) and is_binary(checksum) do
    rows =
      Repo.all(
        from i in ExternalIdentifier,
          join: e in Entity,
          on: e.object_id == i.object_id,
          join: o in Object,
          on: o.id == e.object_id,
          left_join: w in WorkDetails,
          on: w.entity_id == e.object_id,
          where: i.namespace == "wikidata" and i.external_id == ^qid and i.status == :verified,
          select: %{
            object_id: e.object_id,
            object_state: o.lifecycle_state,
            work_kind: w.work_kind,
            metadata: e.metadata
          }
      )

    with {:ok, row} <- one(rows),
         :ok <- active(row.object_state),
         :ok <- artwork(row.work_kind),
         :ok <- catalog(row.metadata, manifest, checksum),
         %{} = view <- Artworks.get(row.object_id) || {:error, :not_found},
         :ok <- image(view) do
      {:ok, Map.merge(row, %{qid: qid, manifest: manifest, checksum: checksum, view: view})}
    end
  end

  def work(_ref), do: {:error, :not_found}

  # ── eligibility ──────────────────────────────────────────────────────────

  defp one([row]), do: {:ok, row}
  defp one([]), do: {:error, :not_found}
  defp one([_ | _]), do: {:error, :ambiguous}

  defp active(:active), do: :ok
  defp active(_state), do: {:error, :object_inactive}

  defp sense_active(:active), do: :ok
  defp sense_active(_state), do: {:error, :object_inactive}

  defp current(false, _state), do: {:error, :revision_not_current}
  defp current(true, :active), do: :ok
  defp current(true, _state), do: {:error, :revision_inactive}

  defp displayable(false, _source), do: {:error, :display_not_allowed}
  defp displayable(true, %Source{active: false}), do: {:error, :source_inactive}
  defp displayable(true, _source), do: :ok

  defp artwork("artwork"), do: :ok
  defp artwork(_kind), do: {:error, :not_an_artwork}

  defp catalog(%{"corpus" => manifest}, manifest, checksum) do
    if Manifest.checksum_of(manifest) == checksum, do: :ok, else: {:error, :catalog_changed}
  end

  defp catalog(_metadata, _manifest, _checksum), do: {:error, :catalog_changed}

  defp image(%{image_url: url}) when is_binary(url) and url != "", do: :ok
  defp image(_view), do: {:error, :no_image}
end
