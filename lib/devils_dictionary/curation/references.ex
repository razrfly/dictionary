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
      manifest (name and checksum) it was seeded from;
    * an **exemplar's subject** (#212) by its verified Wikidata QID, or, for
      a passage, as a definition is named; the claim that cites it is found
      by its semantic key, the subject and the meaning's sense, the way
      `Claims.Contributions.propose/6` keeps that key to one claim.

  Every function answers `{:ok, row}` or `{:error, reason}`. The reasons are
  what a reader withholds an item for: `:not_found`, `:ambiguous`,
  `:object_inactive`, `:revision_not_current`, `:revision_inactive`,
  `:display_not_allowed`, `:source_inactive`, `:catalog_changed`,
  `:catalog_drift`, `:not_an_artwork`, `:no_image`. Nothing here writes and
  nothing leaves the database (and the committed manifests).

  Relationships used as evidence — a definition `defines` a word, a meaning
  `refers_to` a concept — are read through `Claims.visible(:public)`, the
  same review policy every public page applies: a relationship a reviewer
  rejected or withdrew is not evidence here either (#202 audit).
  """

  import Ecto.Query

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{AssertionReview, AssertionRevision, Predicate}
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

  `ref` is `%{"source", "record", "revision_key"}`. The content item's
  **current** revision must be one materialized from that observation: a lead
  quotes the text a reader can check, and a pinned observation that has been
  superseded is a changed source. A re-materialization of the same
  observation can still change the words, which is why a selection also pins
  the words it quotes (`Curation.ManualFixture` checks that pin).
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

    with {:ok, row} <- current_of_one_item(rows),
         :ok <- active(row.object_state),
         :ok <- current(row.current?, row.lifecycle_state),
         :ok <- displayable(row.display_allowed?, row.source) do
      {:ok, row}
    end
  end

  def content(_ref), do: {:error, :not_found}

  # Every revision of one content item that the observation produced; the
  # current one if it is among them. Two items from one observation is not a
  # reference a reader can resolve.
  defp current_of_one_item([]), do: {:error, :not_found}

  defp current_of_one_item(rows) do
    case rows |> Enum.map(& &1.object_id) |> Enum.uniq() do
      [_one] -> {:ok, Enum.find(rows, hd(rows), & &1.current?)}
      _many -> {:error, :ambiguous}
    end
  end

  @doc """
  Whether content object `content_id` currently `defines` lexeme `lexeme_id`
  or one of its senses, by a relationship the public may see.
  """
  def defines?(content_id, lexeme_id) do
    from(r in AssertionRevision,
      join: p in Predicate,
      on: p.id == r.predicate_id and p.key == "defines",
      left_join: s in Sense,
      on: s.object_id == r.object_object_id,
      where:
        r.subject_object_id == ^content_id and r.is_current and r.lifecycle_state == :active and
          (r.object_object_id == ^lexeme_id or s.lexeme_id == ^lexeme_id)
    )
    |> Claims.visible(:public)
    |> Repo.exists?()
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
      when is_binary(lexical_key) and is_binary(slug) and is_binary(external_id) and
             is_binary(key) and is_binary(gloss) do
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

  @doc """
  The verified Wikidata QIDs a sense currently `refers_to`, by relationships
  the public may see: a rejected or withdrawn `refers_to` is not a reason.
  """
  def refers_to_qids(sense_id) do
    from(r in AssertionRevision,
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
    |> Claims.visible(:public)
    |> Repo.all()
  end

  @doc """
  A catalog artwork by its verified QID, displayed exactly as the committed
  manifest row a selection pinned.

  `ref` is `%{"wikidata", "catalog", "checksum"}`. In order:

    * the work is one active artwork, seeded from that manifest;
    * the manifest committed now carries the pinned checksum, and has a row
      for the QID (`Manifest.committed_row/2`) — that row is what was pinned;
    * the manifest's catalog source exists and is active;
    * what the page would display — title, date, image, image credit, Commons
      file and depicted QIDs, through `Artworks.get/1`, the view the shelf
      renders — is exactly that row. The database's copy can drift from the
      file (an edited image URL, an image supplied by another source, a
      changed credit or depiction), and a drifted work is `:catalog_drift`.
      Nothing is substituted for it, and no other image is shown.

  The row returned carries `pinned` (the manifest row) and `source` (the
  catalog's source row); a reader credits the work from `pinned`.
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
         {:ok, pinned} <- pinned_row(manifest, qid),
         {:ok, source} <- catalog_source(manifest, row.metadata),
         %{} = view <- Artworks.get(row.object_id) || {:error, :not_found},
         :ok <- image(view),
         :ok <- as_pinned(view, row.metadata, pinned) do
      {:ok,
       Map.merge(row, %{
         qid: qid,
         manifest: manifest,
         checksum: checksum,
         view: view,
         pinned: pinned,
         source: source
       })}
    end
  end

  def work(_ref), do: {:error, :not_found}

  @doc """
  What an exemplar shows (#212): an entity by its verified Wikidata QID
  (`%{"wikidata" => qid}`), or a passage or quotation by its source record
  (`%{"content" => ref}`, as `content/1` reads it, whose words are then the
  ones pinned). `{:ok, %{object_id, kind: :entity | :content,
  content_revision_id, words, content_kind, body_format, source, url}}`,
  every field after `kind` being `nil` for an entity. `source` is the
  passage's `sources` row, whose attribution and licence the page must carry.
  """
  def subject(%{"wikidata" => qid}) when is_binary(qid) do
    rows =
      Repo.all(
        from i in ExternalIdentifier,
          join: e in Entity,
          on: e.object_id == i.object_id,
          join: o in Object,
          on: o.id == e.object_id,
          where: i.namespace == "wikidata" and i.external_id == ^qid and i.status == :verified,
          select: %{object_id: e.object_id, object_state: o.lifecycle_state}
      )

    with {:ok, row} <- one(rows),
         :ok <- active(row.object_state) do
      {:ok,
       %{
         object_id: row.object_id,
         kind: :entity,
         content_revision_id: nil,
         words: nil,
         content_kind: nil,
         body_format: nil,
         source: nil,
         url: nil
       }}
    end
  end

  def subject(%{"content" => ref}) do
    with {:ok, row} <- content(ref) do
      {:ok,
       %{
         object_id: row.object_id,
         kind: :content,
         content_revision_id: row.content_revision_id,
         words: row.body,
         content_kind: row.content_kind,
         body_format: row.body_format,
         source: row.source,
         url: row.canonical_url
       }}
    end
  end

  def subject(_ref), do: {:error, :not_found}

  @doc """
  The `illustrates` claim citing `subject_id` as an example of the sense
  `sense_id`: the current, active revision of the claim of that semantic key
  whose latest review is not a rejection or a withdrawal, the one
  `Contributions.propose/6` holds a second nomination against.
  `{:error, :claim_not_found}` when there is none.

  `propose/6` keeps that claim unique, but a row written another way (a
  legacy claim, an import) can stand beside it. An accepted claim is then
  preferred, and the oldest among equals, so a pending duplicate never hides
  an accepted one.

  Whether it may be shown is not decided here: an opening holds it to
  `Curation.Eligibility`'s exemplar rules, accepted review first.
  """
  def exemplar_claim(subject_id, sense_id) do
    latest =
      from review in AssertionReview,
        where: review.assertion_revision_id == parent_as(:claim).id,
        order_by: [desc: review.inserted_at, desc: review.id],
        limit: 1,
        select: %{decision: review.decision}

    from(r in AssertionRevision,
      as: :claim,
      join: p in Predicate,
      on: p.id == r.predicate_id and p.key == "illustrates",
      left_lateral_join: decision in subquery(latest),
      on: true,
      where: r.subject_object_id == ^subject_id and r.object_object_id == ^sense_id,
      where: r.is_current and r.lifecycle_state == :active,
      where: is_nil(decision.decision) or decision.decision not in ^Claims.hidden_decisions(),
      order_by: [
        desc: fragment("coalesce(? = 'accepted', false)", decision.decision),
        asc: r.assertion_id
      ],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :claim_not_found}
      claim -> {:ok, claim}
    end
  end

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

  defp pinned_row(manifest, qid) do
    case Manifest.committed_row(manifest, qid) do
      %{} = row -> {:ok, row}
      nil -> {:error, :catalog_changed}
    end
  end

  # The catalog is its manifest's source, and the work must say so too: a
  # work credited to one source and shown under another is drift.
  defp catalog_source(manifest, metadata) do
    slug = Manifest.source_of(manifest)

    cond do
      is_nil(slug) or metadata["catalog_source"] != slug -> {:error, :catalog_drift}
      source = DevilsDictionary.Sources.get_source_by_slug(slug) -> active_source(source)
      true -> {:error, :source_inactive}
    end
  end

  defp active_source(%Source{active: true} = source), do: {:ok, source}
  defp active_source(_source), do: {:error, :source_inactive}

  defp image(%{image_url: url}) when is_binary(url) and url != "", do: :ok
  defp image(_view), do: {:error, :no_image}

  # What would be displayed, field by field, against the pinned row.
  defp as_pinned(view, metadata, pinned) do
    displayed = %{
      title: view.title,
      date: view.date,
      image: view.image_url,
      credit: view.image_attribution,
      commons_file: metadata["commons_file"],
      depicts: metadata |> Map.get("depicts_qids", []) |> List.wrap() |> Enum.sort()
    }

    expected = %{
      title: pinned["title"] && String.slice(pinned["title"], 0, 255),
      date: pinned["date"],
      image: pinned["image_url"],
      credit: pinned["credit_line"],
      commons_file: pinned["commons_file"],
      depicts: pinned |> pinned_depicts() |> Enum.map(& &1["qid"]) |> Enum.sort()
    }

    if displayed == expected, do: :ok, else: {:error, :catalog_drift}
  end

  @doc """
  A pinned catalog row's depictions as `%{"qid", "term"}`, with the QIDs the
  seeder would keep — the same normalisation, so the comparison is exact.
  """
  def pinned_depicts(pinned) do
    for %{"qid" => qid} = entry <- List.wrap(pinned["tags"] || pinned["depicts"]),
        is_binary(qid) and Regex.match?(~r/\AQ[1-9]\d*\z/, qid),
        do: %{"qid" => qid, "term" => blank_to_nil(entry["term"])}
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
