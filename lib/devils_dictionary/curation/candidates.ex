defmodule DevilsDictionary.Curation.Candidates do
  @moduledoc """
  What a word page's curated opening may be made of (#257 §3, §4): the
  candidates of the four kinds the record admits, read from the page as the
  reader sees it and from the registry, for the owner's curation screen.

  **The scope is the page's words.** Every candidate is listed for
  `page.headword.lexemes`, in the page's order, as `WordPage.build/2` built
  them. Nothing is read from an address or a parameter: the screen hands
  over a built page and gets back what that page's composition may hold.

  **The four kinds**, each from the seam the record already uses:

    * **leads and definitions** (`:content`): every entry on the page's
      cards (`LeadPolicy.page_entry/2` finds the card a lead opens). Who may
      lead is the record's own rule, `Curation.LeadRule` (K10), which
      counts a Bierce entry only where it may itself lead
      (`Eligibility.leadable?/1`): an applicable Bierce entry is then the
      only admissible lead, and "no lead" is admissible only where there is
      none. A definition may also be a highlight. One whose `defines` claim
      the public may not see means nothing on this page, and is listed and
      not offered rather than given a guessed meaning;
    * **sense quotations** (`:sense_quotation`): the quotations of the
      scope's current senses, pinned by `locator` (`"quotation:N"`) and the
      SHA-256 of their words, as `Curation.ManualFixture` pins them, and only
      the lines the sense row itself would show (`WordPage.quotations/1`);
    * **catalog works** (`:work`): exactly the rows `Artworks.shelf_items/1`
      lists for the page (the "Saved catalog" shelf), each referenced by its
      committed manifest, checksum and row identity. A shelf row that is not
      a committed catalog row (the Artsy pilot's) is listed and cannot be
      selected;
    * **exemplars** (`:exemplar`): the `illustrates` claims the Examples
      section lists for the page's senses (`Examples.exemplars/3`) whose
      latest review is an acceptance. A nomination still waiting is counted,
      never offered.

  Every candidate carries the item spec `Compositions.create_version/3`
  takes (without its note, which is the author's to write) and its standing
  now: `Curation.Eligibility.check/3` asked of the item it would make. The
  rules are the record's; this module only lists.

  Reads only: no provider, no model, no write.
  """

  import Ecto.Query

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision

  alias DevilsDictionary.Curation.{
    CompositionItem,
    Digest,
    Eligibility,
    Excerpt,
    LeadPolicy,
    LeadRule
  }

  alias DevilsDictionary.Curation.Runtime.Packet
  alias DevilsDictionary.Examples
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    ContentRevision,
    Entity,
    ExternalIdentifier,
    Sense,
    SenseRevision
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @kinds [:content, :sense_quotation, :work, :exemplar]

  # A definition is quoted by its entry's whole first block (`PublishedReader`).
  @block_sentences 1_000

  @doc "The highlight kinds, in the order the screen groups them."
  def kinds, do: @kinds

  @doc """
  The candidates for a built `WordPage`:

      %{
        scope: %{ids: [lexeme_id], language: tag | nil,
                 lexemes: [%{id, lemma, pos, language}]},
        bierce?: boolean,
        leads: [candidate],          # the page's entries, Bierce's first
        no_lead: :ok | {:error, reason},
        highlights: [candidate],     # definitions, quotations, works, exemplars
        nominations: n               # exemplars awaiting review, not offered
      }

  A candidate is `%{key, kind, spec, item, status, lead, source, label,
  title, creator, date, text, citation, meaning, work_kind, subject_kind,
  image_url, detail}`: `spec` is the item spec, `item` the unsaved
  `CompositionItem` it would make (what `status` was asked of, and what the
  preview draws), `status` is `:ok` or the reason the record would refuse
  the item now, and `lead` (leads only) is `{:ok, policy}` or `{:error,
  reason}` from the lead rule. A page with no words, or
  whose words span languages, has no scope and no candidates.
  """
  def for_page(%{headword: %{lexemes: lexemes}} = page) do
    scope = scope(lexemes)

    if scope.language do
      definitions = definitions(page, scope)
      exemplars = exemplars(scope)

      %{
        scope: scope,
        bierce?: LeadRule.applicable(scope.ids) != [],
        leads: leads(page, scope, definitions),
        no_lead: no_lead(scope),
        highlights:
          definitions ++
            quotations(scope) ++ works(scope) ++ Enum.filter(exemplars, & &1.accepted?),
        nominations: Enum.count(exemplars, &(not &1.accepted?))
      }
    else
      empty(scope)
    end
  end

  def for_page(_page), do: empty(scope([]))

  defp empty(scope),
    do: %{scope: scope, bierce?: false, leads: [], no_lead: :ok, highlights: [], nominations: 0}

  @doc """
  The candidate marks the queue prints for a page (#257 §2.1): `B` a Bierce
  entry, `J` a Johnson entry, `Q` a sense quotation, `W` a catalog work, `E`
  an accepted exemplar. Only a candidate that may be selected now counts.
  """
  def marks(%{leads: leads, highlights: highlights}) do
    usable = Enum.filter(leads ++ highlights, &(&1.status == :ok))
    sources = usable |> Enum.filter(&(&1.kind == :content)) |> Enum.map(& &1.source.slug)

    %{
      "B" => LeadPolicy.priority_source() in sources,
      "J" => "johnson" in sources,
      "Q" => Enum.any?(usable, &(&1.kind == :sense_quotation)),
      "W" => Enum.any?(usable, &(&1.kind == :work)),
      "E" => Enum.any?(usable, &(&1.kind == :exemplar))
    }
  end

  @doc "Whether a page has anything the record can cite (#257 §2.6)."
  def any?(%{leads: leads, highlights: highlights}),
    do: Enum.any?(leads ++ highlights, &(&1.status == :ok))

  @doc "The candidate with `key` among the leads and highlights, or `nil`."
  def find(%{leads: leads, highlights: highlights}, key),
    do: Enum.find(leads ++ highlights, &(&1.key == key))

  # ── the scope ────────────────────────────────────────────────────────────

  defp scope(lexemes) do
    language =
      case lexemes |> Enum.map(& &1.language) |> Enum.uniq() do
        [language] when is_binary(language) -> language
        _none_or_many -> nil
      end

    %{
      ids: Enum.map(lexemes, & &1.id),
      language: language,
      lexemes: Enum.map(lexemes, &Map.take(&1, [:id, :lemma, :pos, :language]))
    }
  end

  # ── definitions and leads ────────────────────────────────────────────────

  # Every entry on the page's cards, in the page's order, as a `:content`
  # candidate meaning the word it defines.
  defp definitions(page, scope) do
    entries =
      for card <- page.cards,
          entry <- card.entries,
          id = Map.get(entry, :content_id),
          not is_nil(id),
          do: {card, entry}

    ids = Enum.map(entries, fn {_card, entry} -> entry.content_id end)
    defined = defined_lexemes(ids, scope.ids)
    revisions = revisions(ids)

    for {card, entry} <- entries,
        revision = revisions[entry.content_id],
        not is_nil(revision) do
      lexeme_id = defined[entry.content_id]

      spec = %{
        kind: :content,
        object_id: entry.content_id,
        content_revision_id: revision.id,
        meaning: lexeme_id && {:lexeme, lexeme_id}
      }

      item = lexeme_id && probe(spec)
      block = Excerpt.sentences(revision.body, revision.body_format, @block_sentences)

      candidate(%{
        key: "content-#{entry.content_id}",
        kind: :content,
        spec: spec,
        item: item,
        status:
          if(item,
            do: drawable(Eligibility.check(item, scope.ids), block),
            else: :meaning_mismatch
          ),
        source: source_of(card.source),
        label: Enum.join(compact([card.source.name, card.pos]), " · "),
        title: entry_label(entry),
        text: excerpt(revision, block),
        meaning: lexeme_label(scope, lexeme_id),
        card_id: card.id,
        first_sentence: Excerpt.sentences(revision.body, revision.body_format, 1)
      })
    end
  end

  # Who may lead: the record's lead rule (`LeadRule.check/3`, K10) over the
  # page's words, an entry this page shows (`LeadPolicy.page_entry/2`), and
  # the entry's own standing. A lead must also have a first sentence to
  # quote, since the page quotes a lead by its first sentence.
  defp leads(page, scope, definitions) do
    applicable = LeadRule.applicable(scope.ids)

    definitions
    |> Enum.map(fn candidate ->
      id = candidate.spec.object_id

      lead =
        with :ok <- candidate.status,
             {_card, _entry} <- LeadPolicy.page_entry(page, id) || :not_on_page,
             {:ok, rule} <- LeadRule.check(scope.ids, id, applicable),
             {:ok, _excerpt} <- candidate.first_sentence do
          {:ok, rule}
        else
          {:error, reason} -> {:error, reason}
          reason when is_atom(reason) -> {:error, reason}
        end

      %{candidate | lead: lead}
    end)
    |> Enum.sort_by(&(not match?({:ok, :priority_source}, &1.lead)))
  end

  # "No lead" as the record's rule answers it: admissible only where no
  # applicable Bierce entry exists.
  defp no_lead(scope) do
    case LeadRule.check(scope.ids, nil) do
      {:ok, _none} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The scope lexeme each definition defines, by the `defines` claims the
  # public may see: directly, or through one of the lexeme's senses.
  defp defined_lexemes([], _member_ids), do: %{}

  defp defined_lexemes(content_ids, member_ids) do
    from(link in AssertionRevision,
      join: p in assoc(link, :predicate),
      on: p.key == "defines",
      left_join: s in Sense,
      on: s.object_id == link.object_object_id,
      where: link.subject_object_id in ^content_ids and link.is_current,
      where: link.lifecycle_state == :active,
      where: link.object_object_id in ^member_ids or s.lexeme_id in ^member_ids,
      select: {link.subject_object_id, coalesce(s.lexeme_id, link.object_object_id)}
    )
    |> Claims.visible(:public)
    |> Repo.all()
    |> Enum.sort_by(fn {_content, lexeme} -> Enum.find_index(member_ids, &(&1 == lexeme)) end)
    |> Enum.reverse()
    |> Map.new()
  end

  defp revisions([]), do: %{}

  defp revisions(content_ids) do
    Repo.all(
      from r in ContentRevision,
        where: r.content_id in ^content_ids and r.is_current,
        select: {r.content_id, r}
    )
    |> Map.new()
  end

  # The page quotes a definition by its entry's first block, as the reader
  # does (`PublishedReader`); an entry with no prose to open it (Johnson's
  # that begin with a quotation) cannot be drawn, and says why.
  defp drawable(:ok, {:error, reason}), do: reason
  defp drawable(status, _block), do: status

  defp excerpt(_revision, {:ok, %{text: text}}), do: text

  defp excerpt(revision, {:error, _reason}),
    do: (revision.body || "") |> String.replace(~r/^>\s*/m, "") |> Packet.excerpt()

  defp entry_label(entry) do
    case entry[:marker] do
      marker when is_binary(marker) and marker != "" -> "#{entry[:headword]} (#{marker})"
      _none -> entry[:headword]
    end
  end

  # ── sense quotations ─────────────────────────────────────────────────────

  # The quotations of the scope's current senses, each as the sense row would
  # show it: a line `WordPage.quotations/1` keeps, at its position in the
  # revision's examples.
  defp quotations(scope) do
    rows =
      Repo.all(
        from r in SenseRevision,
          join: s in Sense,
          on: s.object_id == r.sense_id,
          join: src in Source,
          on: src.id == s.source_id,
          where:
            s.lexeme_id in ^scope.ids and r.is_current and r.lifecycle_state == :active and
              s.identity_state == :active and src.active,
          order_by: [src.slug, r.position, r.id],
          select: {r, src, s.lexeme_id}
      )

    for {revision, source, lexeme_id} <- rows,
        {example, index} <- Enum.with_index(revision.examples || []),
        [line] <- [WordPage.quotations([example]).shown] do
      spec = %{
        kind: :sense_quotation,
        object_id: revision.sense_id,
        sense_revision_id: revision.id,
        locator: "quotation:#{index}",
        words_sha256: Digest.sha256(example["text"]),
        meaning: {:sense_revision, revision.id}
      }

      item = probe(spec)

      candidate(%{
        key: "quotation-#{revision.id}-#{index}",
        kind: :sense_quotation,
        spec: spec,
        item: item,
        status: Eligibility.check(item, scope.ids),
        source: source_of(source),
        label: source.name,
        text: line.text,
        citation: line.citation,
        meaning: gloss_label(revision.gloss, lexeme_label(scope, lexeme_id))
      })
    end
  end

  # ── catalog works ────────────────────────────────────────────────────────

  # Exactly the page's Saved catalog shelf. A row is selectable when it is a
  # committed catalog row: its work carries a manifest this build committed,
  # and the row's identity as a verified identifier.
  defp works(scope) do
    rows = Artworks.shelf_items(scope.ids)
    pins = pins(Enum.map(rows, & &1.object_id))
    senses = current_sense_revisions(Enum.map(rows, & &1.sense_id))

    for row <- rows do
      meta = row.preview_metadata
      pin = pins[row.object_id]
      sense = senses[row.sense_id]

      # The meaning the shelf matched the work for; a row with none means
      # nothing here, and is not given one.
      spec =
        pin && sense &&
          %{
            kind: :work,
            object_id: row.object_id,
            catalog: Map.take(pin, [:manifest, :checksum, :identity]),
            meaning: {:sense_revision, sense.id}
          }

      item = spec && probe(spec)

      status =
        cond do
          is_nil(pin) -> :not_a_catalog_row
          is_nil(sense) -> :meaning_mismatch
          true -> Eligibility.check(item, scope.ids)
        end

      candidate(%{
        key: "work-#{row.object_id}",
        kind: :work,
        spec: spec,
        item: item,
        status: status,
        source: %{slug: row.source_slug, name: meta["provider"] || row.source_slug},
        label: meta["provider"],
        title: meta["title"],
        creator: meta["artist"],
        date: meta["year"],
        work_kind: pin && pin.work_kind,
        image_url: meta["thumbnail_url"] || meta["image_url"],
        meaning: sense && gloss_label(sense.gloss, lexeme_label(scope, sense.lexeme_id)),
        detail: row.match_reasons |> List.wrap() |> Enum.map_join(" ", &reason_text/1)
      })
    end
  end

  # For each work, the committed manifest row it carries: the manifest named
  # by its `corpus`, and the row's identity in that kind's namespace.
  defp pins([]), do: %{}

  defp pins(object_ids) do
    corpora =
      Repo.all(
        from e in Entity,
          where: e.object_id in ^object_ids,
          select: {e.object_id, fragment("? ->> 'corpus'", e.metadata)}
      )

    identifiers =
      Repo.all(
        from x in ExternalIdentifier,
          where: x.object_id in ^object_ids and x.status == :verified,
          order_by: [x.object_id, x.namespace, x.external_id],
          select: {x.object_id, x.namespace, x.external_id}
      )

    for {object_id, name} <- corpora,
        kind = manifest_kind(name),
        not is_nil(kind),
        checksum = Manifest.checksum_of(name),
        not is_nil(checksum),
        namespace = Manifest.identity_namespace(kind),
        identity <- identifiers |> identities(object_id, namespace) |> Enum.take(1),
        not is_nil(Manifest.committed_row(name, identity)),
        into: %{} do
      {object_id,
       %{
         manifest: name,
         checksum: checksum,
         identity: identity,
         work_kind: Manifest.work_kind(kind)
       }}
    end
  end

  defp identities(identifiers, object_id, namespace) do
    for {^object_id, ^namespace, id} <- identifiers, do: id
  end

  @doc "The kind of the committed manifest `name`, as the file declares it, or `nil`."
  def manifest_kind(name), do: Manifest.kind_of(name)

  defp reason_text(%{detail: detail}) when is_binary(detail), do: detail
  defp reason_text(%{"detail" => detail}) when is_binary(detail), do: detail
  defp reason_text(_reason), do: ""

  # ── exemplars ────────────────────────────────────────────────────────────

  # The page's exemplars as the Examples section reads them for the public:
  # accepted ones are candidates, the rest are only counted.
  defp exemplars(scope) do
    items = Examples.exemplars(scope.ids, :internal)
    senses = current_sense_revisions(Enum.map(items, & &1.target.object_id))

    for item <- items, sense = senses[item.target.object_id], not is_nil(sense) do
      claim = item.claim
      subject = item.subject

      spec = %{
        kind: :exemplar,
        assertion_revision_id: claim.revision_id,
        meaning: {:sense_revision, sense.id}
      }

      probe = %CompositionItem{
        role: :highlight,
        position: 1,
        item_kind: :exemplar,
        item_object_id: subject.object_id,
        content_revision_id: pinned_words(subject),
        assertion_revision_id: claim.revision_id,
        meaning_sense_revision_id: sense.id,
        selection_origin: :manual
      }

      candidate(%{
        key: "exemplar-#{claim.revision_id}",
        kind: :exemplar,
        spec: spec,
        item: probe,
        status: Eligibility.check(probe, scope.ids),
        accepted?: claim.review_state == :accepted,
        source: nil,
        label: subject_label(subject),
        title: subject.label,
        subject_kind: subject.entity_kind || subject.kind,
        subject_object_id: subject.object_id,
        text: claim.rationale,
        detail: nominated(claim.nominated_by),
        meaning: gloss_label(sense.gloss, lexeme_label(scope, sense.lexeme_id))
      })
    end
  end

  defp pinned_words(%{kind: :content, object_id: id}) do
    case Registry.current_content_revision(id) do
      %{id: revision_id} -> revision_id
      nil -> nil
    end
  end

  defp pinned_words(_subject), do: nil

  defp subject_label(%{kind: :content}), do: "Passage"

  defp subject_label(%{entity_kind: kind}) when not is_nil(kind),
    do: kind |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp subject_label(_subject), do: "Thing"

  defp nominated(%{label: label}) when is_binary(label), do: "Nominated by #{label}"
  defp nominated(_by), do: nil

  # ── shared ───────────────────────────────────────────────────────────────

  defp candidate(fields) do
    Map.merge(
      %{
        key: nil,
        kind: nil,
        spec: nil,
        item: nil,
        status: :ok,
        lead: nil,
        accepted?: true,
        source: nil,
        label: nil,
        title: nil,
        creator: nil,
        date: nil,
        text: nil,
        citation: nil,
        meaning: nil,
        work_kind: nil,
        subject_kind: nil,
        subject_object_id: nil,
        image_url: nil,
        card_id: nil,
        detail: nil,
        first_sentence: nil
      },
      fields
    )
  end

  # The item a spec would make, for `Eligibility.check/3`: the same fields
  # `Compositions.create_version/3` stores, unsaved and without a note.
  @doc false
  def probe(%{kind: kind} = spec) when kind in [:content, :sense_quotation, :work] do
    catalog = spec[:catalog] || %{}

    struct(
      CompositionItem,
      Map.merge(
        %{
          role: :highlight,
          position: 1,
          item_kind: kind,
          item_object_id: spec[:object_id],
          content_revision_id: spec[:content_revision_id],
          sense_revision_id: spec[:sense_revision_id],
          source_record_revision_id: spec[:source_record_revision_id],
          catalog_manifest: catalog[:manifest],
          catalog_checksum: catalog[:checksum],
          catalog_identity: catalog[:identity] && to_string(catalog[:identity]),
          locator: spec[:locator],
          words_sha256: spec[:words_sha256],
          selection_origin: :manual
        },
        meaning(spec[:meaning])
      )
    )
  end

  defp meaning({:lexeme, id}), do: %{meaning_lexeme_id: id}
  defp meaning({:sense_revision, id}), do: %{meaning_sense_revision_id: id}

  defp current_sense_revisions(sense_ids) do
    ids = sense_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Repo.all(
        from r in SenseRevision,
          join: s in Sense,
          on: s.object_id == r.sense_id,
          where: r.sense_id in ^ids and r.is_current,
          select: {r.sense_id, %{id: r.id, gloss: r.gloss, lexeme_id: s.lexeme_id}}
      )
      |> Map.new()
    end
  end

  defp source_of(%{slug: slug, name: name}), do: %{slug: slug, name: name}

  defp lexeme_label(scope, lexeme_id) do
    case Enum.find(scope.lexemes, &(&1.id == lexeme_id)) do
      nil -> nil
      lexeme -> Enum.join(compact([lexeme.lemma, lexeme.pos]), ", ")
    end
  end

  defp gloss_label(gloss, word) when is_binary(gloss),
    do: Enum.join(compact(["“#{gloss}”", word && "(#{word})"]), " ")

  defp gloss_label(_gloss, word), do: word

  defp compact(list), do: Enum.reject(list, &(&1 in [nil, ""]))
end
