defmodule DevilsDictionary.Curation.PublishedReader do
  @moduledoc """
  The opening reader for published compositions (#255, #156 Phase 2): what a
  reviewer published for this page's words, revalidated now, mapped onto
  `DevilsDictionary.Curation.Opening`.

  **Which composition.** A page's scope is its words, never its address: every
  lexeme the page reaches (`page.headword.lexemes`), as a `:lexical_page`
  scope of the global default configuration (`Configurations.resolve_default/1`),
  found by its signature (`Compositions.active/4`, K2). So `/on/love`, which
  reads every *love*, and `/words/:id/love`, which reads one, are two scopes;
  and no query parameter can name a configuration or a composition. A page
  whose words span languages has no such scope, and no opening.

  **What is shown.** `Published.current/1`'s answer, which already applies the
  read-time rules (R6): a version withheld as a whole is no opening at all; an
  item withheld alone is listed in `withheld`, and nothing takes its place.
  Nothing that answer settled is checked again here. What this module adds is
  only how a published item appears on this page:

    * the lead's rule, read from what was shown: `Published.current/1`
      applied `Curation.LeadRule`, so a lead it shows from the priority
      source leads under `:priority_source` and any other under
      `:manual_fallback`. `LeadPolicy` words it and names its register, and
      finds the card on this page that holds the whole entry; a lead the
      page does not show is withheld (`:not_on_page`) rather than quoted
      without its entry;
    * a definition highlight by its entry's opening block, and a quotation by
      its line as the sense row shows it (`WordPage.quotations/1`);
    * each note as an editorial reason, signed with the author label the
      database recorded for it, never one supplied by a caller;
    * who selected, reviewed and published it: the version's author, the
      review the receipt cites, and the publication receipt. A version the
      owner took from the editor's proposal (#264 R14.4) is selected by the
      editor, named as an AI model with its attempt, and taken (or edited
      and published) by the owner; a note the model wrote names its attempt
      too (D9), and a fallback lead the model chose says the editor chose it
      (#253 D3, `LeadPolicy.statement/1`).

  A `work` or `exemplar` highlight is drawn too (#257):

    * a **catalog work** from the committed manifest row it pins, read
      through `Manifest.committed_row/2`: an artwork (`met-highlights`,
      `wikidata-famous`) with its image and the credit its catalog committed,
      a poem (`poetrydb`) by its title, poet and length, a book
      (`open-library`) by its title, authors, year and public-domain basis.
      What is shown is the row that was selected, never the database's copy;
      a poem's lines are not in its row, so none are quoted. A work pinned by
      a source record rather than a catalog row is still `:unsupported_item`;
    * an **exemplar** from `Published.current/1`'s `subject`: a thing by its
      registry label, a passage by its pinned words under the quotation
      register, with the claim's reason and its provenance as the examples
      card reads it for the public (`Examples.Provenance`).

  `arrangement/3` is the mapping itself, for any arrangement and record. The
  operator screen's preview (`Curation.Preview`) draws an unsaved selection
  through it, so what the owner previews is what the page will show.

  The disclosure's assessment rows come from the composition's refresh clock
  (`Curation.Refresh.assessment/1`, #259 §2.1), read here, never admitted
  here: the visit check is `WordLive`'s.

  Reads only: no provider, no model, no write and no refresh admission.
  """

  @behaviour DevilsDictionary.Curation.OpeningReader

  import Ecto.Query

  alias DevilsDictionary.{Artworks, Examples, Markdown, Sources}
  alias DevilsDictionary.Artworks.Corpus.Manifest

  alias DevilsDictionary.Curation.{
    Candidates,
    CompositionItem,
    CompositionReview,
    CompositionVersion,
    Compositions,
    Configurations,
    Eligibility,
    Proposal,
    Excerpt,
    LeadPolicy,
    Opening,
    Published,
    References,
    Refresh
  }

  alias DevilsDictionary.Curation.Opening.{
    Configuration,
    Credit,
    Highlight,
    Lead,
    Meaning,
    Reason,
    Reference,
    Review
  }

  alias DevilsDictionary.Examples.Provenance
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Lexeme, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, Source}

  # `resolve_default/1` resolves by one policy: the enabled global default and
  # nothing else (C7). It has no version number of its own yet; this is it.
  @resolution_policy_version 1

  # A lead quotes its entry's first sentence, so the Definitions stay on the
  # first screen (#255 §2.1); "Read the whole entry" opens the rest.
  @lead_sentences 1

  # A definition highlight quotes its entry's whole first block. Johnson
  # numbers his senses, so a first *sentence* would be "1.".
  @block_sentences 1_000

  @impl true
  def opening(page, _opts \\ []) do
    with {:ok, %{configuration: configuration, version: configuration_version}} <-
           Configurations.resolve_default(),
         {:ok, ids, language} <- scope(page),
         %{} = composition <-
           Compositions.active(
             configuration.id,
             :lexical_page,
             language,
             Compositions.signature(ids)
           ),
         {:ok, published} <- Published.current(composition.id) do
      build(page, published, configuration, configuration_version)
    else
      _ -> nil
    end
  end

  # The page's words, in one language. A lexical page composition has one
  # language (`Compositions.provision/3` refuses a mixed scope).
  defp scope(%{headword: %{lexemes: [_ | _] = lexemes}}) do
    case lexemes |> Enum.map(& &1.language) |> Enum.uniq() do
      [language] when is_binary(language) -> {:ok, Enum.map(lexemes, & &1.id), language}
      _languages -> :none
    end
  end

  defp scope(_page), do: :none

  defp build(page, published, configuration, configuration_version) do
    %{composition: composition, version: version, receipt: receipt} = published

    review =
      receipt.authorizing_review_id && Repo.get(CompositionReview, receipt.authorizing_review_id)

    proposal = proposal_of(version)

    actors =
      actors([
        version.created_by_actor_id,
        receipt.actor_id,
        review && review.reviewer_actor_id,
        proposal && proposal.created_by_actor_id
      ])

    arrangement(page, published, %{
      composition: %{id: composition.id, version: version.version},
      configuration: configuration,
      configuration_version: configuration_version,
      review: %Review{
        state: :published,
        selected_by: selector(version, proposal, actors),
        selected_on: date((proposal || version).inserted_at),
        reviewed_by: review && label(actors[review.reviewer_actor_id]),
        reviewed_on: review && date(review.inserted_at),
        published_by: person(actors[receipt.actor_id]),
        published_on: date(receipt.committed_at),
        receipt_id: receipt.id,
        assessment:
          composition.id
          |> Refresh.state_for(configuration_version.id)
          |> Refresh.assessment()
      }
    })
  end

  # A parent edge alone is not a Take: ordinary manual saves also parent
  # to the newest version, including a pending or dismissed proposal (R13).
  defp proposal_of(%{id: id}) when is_integer(id) do
    Repo.one(
      from p in Proposal,
        join: v in CompositionVersion,
        on: v.id == p.version_id,
        where: p.state == :taken and p.resolution_version_id == ^id,
        select: v
    )
  end

  defp proposal_of(_version), do: nil

  # Who selected a published version: its author, or, for one taken from a
  # proposal, the editor that proposed it and the owner who took it. An
  # unchanged Take has the proposal's arrangement; anything else was edited.
  defp selector(version, nil, actors), do: person(actors[version.created_by_actor_id])

  defp selector(version, proposal, actors) do
    case person(actors[proposal.created_by_actor_id]) do
      nil ->
        person(actors[version.created_by_actor_id])

      editor ->
        Map.merge(editor, %{
          attempt_id: proposal.attempt_id,
          taken_by: label(actors[version.created_by_actor_id]),
          taken_on: date(version.inserted_at),
          edited?: version.arrangement_hash != proposal.arrangement_hash
        })
    end
  end

  @doc """
  An arrangement mapped onto this page's opening, under a record.

  `arrangement` is `%{lead, highlights, withheld}` as `Published.current/1`
  answers it: the eligible lead or `nil`, the eligible highlights (an
  exemplar with its `subject`), and the items already withheld. `record` is
  `%{composition, configuration, configuration_version, review}`, the
  `%Opening{}` fields that say who selected, reviewed and published it, and
  may carry `:provenance`, a function from an exemplar item to its
  `Examples.Provenance` (by default the claim's as the public reads it, with
  this item's selection and publication).

  An item this page cannot draw is withheld here with its reason, beside the
  ones the arrangement already withheld. Nothing takes its place.
  """
  def arrangement(page, arrangement, record) do
    review = record.review

    ctx = %{
      page: page,
      reviewed_by: review.reviewed_by,
      reviewed_on: review.reviewed_on,
      provenance: Map.get(record, :provenance, &Provenance.of(&1, :public)),
      attempts: attempts(List.wrap(arrangement.lead) ++ arrangement.highlights)
    }

    {lead, lead_withheld} = lead(arrangement.lead, ctx)

    {highlights, highlight_withheld} =
      arrangement.highlights
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&highlight(&1, ctx))
      |> Enum.split_with(&match?(%Highlight{}, &1))

    slug =
      case ctx.page.headword.lexemes do
        [lexeme | _] -> Repo.get!(Lexeme, lexeme.id).slug
        _ -> nil
      end

    receipt_path = slug && "/on/" <> URI.encode(slug) <> "/receipt/#{record.composition.version}"
    all_items = List.wrap(arrangement.lead) ++ arrangement.highlights

    highlights =
      Enum.map(highlights, fn tile ->
        item = Enum.find(all_items, &(&1.role == :highlight and &1.position == tile.position))
        enrich_choice(tile, item, receipt_path)
      end)

    lead = if lead, do: enrich_choice(lead, arrangement.lead, receipt_path)
    configuration = record.configuration
    configuration_version = record.configuration_version

    %Opening{
      composition: record.composition,
      origin: :published,
      configuration: %Configuration{
        selection_scope: configuration_version.manifest["selection_scope"],
        id: configuration.id,
        slug: configuration.slug,
        version: configuration_version.version,
        lead_rule: configuration_version.lead_policy,
        resolution_reason: :global_default,
        resolution_policy_version: @resolution_policy_version
      },
      lead: lead,
      highlights: highlights,
      review: review,
      withheld:
        Enum.sort_by(
          arrangement.withheld ++ lead_withheld ++ highlight_withheld,
          &{&1.role != :lead, &1.position || 0}
        )
    }
  end

  defp enrich_choice(tile, item, path) do
    basis =
      if item.id,
        do: DevilsDictionary.Curation.ItemBasis.get(item.id),
        else: %DevilsDictionary.Curation.ItemBasis{
          origin: "owner",
          evidence_kind: if(item.shelf, do: "shelf", else: to_string(item.item_kind)),
          fields_version: "screen-fields-v1"
        }

    date =
      if item.shelf_citation_id do
        c = DevilsDictionary.Curation.ShelfCitations.get(item.shelf_citation_id)

        case DevilsDictionary.Curation.ShelfCitations.payload(c) do
          nil ->
            %{value: nil, meaning: c.content_date_meaning, precision: c.content_date_precision}

          payload ->
            DevilsDictionary.Curation.Shelf.date(
              Repo.get!(Source, c.source_id).slug,
              payload["preview_metadata"] || %{}
            )
        end
      else
        DevilsDictionary.Curation.ContentDate.of(item)
      end

    %{
      tile
      | date_info: date,
        basis: basis,
        receipt_path: if(item.id, do: path <> "#receipt-item-#{item.role}-#{item.position}"),
        source_edition: tile.source && tile.source[:edition_year]
    }
  end

  # ── the lead ─────────────────────────────────────────────────────────────

  defp lead(nil, _ctx), do: {nil, []}

  defp lead(%CompositionItem{item_kind: :sense_definition} = item, ctx) do
    case highlight(item, ctx) do
      %Highlight{} = tile ->
        {%Lead{
           reference: tile.reference,
           policy: :manual_fallback,
           register: :definition,
           source: tile.source,
           author: tile.creator,
           work: nil,
           entry: %{headword: "Selected definition", marker: nil, year: nil},
           excerpt: tile.excerpt,
           meaning: tile.meaning,
           links:
             Map.put(
               tile.links,
               :card_id,
               String.trim_leading(tile.meaning.anchor || "", "#")
             ),
           credits: tile.credits,
           reasons: [
             %Reason{
               kind: :policy,
               text:
                 "A sourced sense definition selected to lead where Bierce has no eligible entry."
             }
             | tile.reasons
           ]
         }, []}

      held ->
        {nil, [held]}
    end
  end

  defp lead(%CompositionItem{} = item, ctx) do
    with {:ok, content} <- content(item),
         {:ok, card, entry} <- page_entry(ctx.page, item.item_object_id),
         {:ok, excerpt} <- Excerpt.sentences(content.body, content.body_format, @lead_sentences),
         {:ok, meaning} <- meaning(item, ctx) do
      source = content.source
      policy = lead_policy(source)

      statement =
        if policy == :manual_fallback and item.selection_origin == :model,
          do: LeadPolicy.statement(:editor_fallback),
          else: LeadPolicy.statement(policy)

      lead = %Lead{
        reference: content_reference(content, %{kind: :sentences, count: @lead_sentences}),
        policy: policy,
        register: LeadPolicy.register(policy),
        source: source_view(source),
        author: author_of(source),
        work: work_of(source),
        entry: %{headword: printed_headword(content), marker: marker(content), year: content.year},
        # The entry's length as its Definitions row counts it, so the lead
        # and the card say one number.
        excerpt:
          excerpt
          |> Map.take([:text, :html, :clipped?, :chars])
          |> Map.put(:chars, Map.get(entry, :chars) || excerpt.chars),
        meaning: %{meaning | anchor: "#" <> card.id},
        links: %{card_id: card.id, source: content.canonical_url},
        credits: content_credits(content),
        reasons: compact([%Reason{kind: :policy, text: statement}, note(item, ctx)])
      }

      {lead, []}
    else
      {:error, reason} -> {nil, [withheld(item, reason)]}
    end
  end

  # The card on this page that holds the entry, and the entry's row.
  defp page_entry(page, content_id) do
    case LeadPolicy.page_entry(page, content_id) do
      {card, entry} -> {:ok, card, entry}
      nil -> {:error, :not_on_page}
    end
  end

  # The rule a shown lead stands under. `LeadRule` admitted it when
  # `Published.current/1` read it, against the claims the public may see; it
  # is not decided again here from the page's cards.
  defp lead_policy(%{slug: slug}) do
    if slug == LeadPolicy.priority_source(), do: :priority_source, else: :manual_fallback
  end

  # ── highlights ───────────────────────────────────────────────────────────

  defp highlight(%CompositionItem{item_kind: :content} = item, ctx) do
    with {:ok, content} <- content(item),
         {:ok, excerpt} <- Excerpt.sentences(content.body, content.body_format, @block_sentences),
         {:ok, meaning} <- meaning(item, ctx) do
      {card, entry} = LeadPolicy.page_entry(ctx.page, item.item_object_id) || {nil, %{}}
      source = content.source

      %Highlight{
        position: item.position,
        kind: :definition,
        register: :definition,
        reference: content_reference(content, nil),
        title: entry_label(content),
        creator: author_of(source),
        date: content.year && Integer.to_string(content.year),
        excerpt:
          excerpt
          |> Map.take([:text, :html, :clipped?, :chars])
          |> Map.put(:chars, Map.get(entry, :chars) || excerpt.chars),
        meaning: anchored(meaning, card),
        source: source_view(source),
        credits: content_credits(content),
        links: %{card_id: card && card.id, source: content.canonical_url},
        reasons: compact([note(item, ctx)])
      }
    else
      {:error, reason} -> withheld(item, reason)
    end
  end

  defp highlight(%CompositionItem{item_kind: :sense_quotation} = item, ctx) do
    with {:ok, sense} <- sense(item.sense_revision_id),
         {:ok, line} <- line(sense, item.locator),
         {:ok, meaning} <- meaning(item, ctx) do
      source = sense.source

      url =
        WordPage.link_out(%{url: sense.url, external_id: sense.external_key}, source, sense.lemma)

      filed_here =
        meaning.object_id == sense.object_id &&
          %Reason{
            kind: :source_match,
            text: "#{source.name} files this quotation under this meaning."
          }

      %Highlight{
        position: item.position,
        kind: :quotation,
        register: :quotation,
        reference: %Reference{
          object_id: sense.object_id,
          object_kind: :sense,
          sense_revision_id: sense.sense_revision_id,
          source_record_revision_id: sense.source_record_revision_id,
          locator: %{kind: :quotation, fingerprint: line.fingerprint}
        },
        quotation: %{text: line.text, citation: line.citation, provenance: line.provenance},
        meaning: meaning,
        source: source_view(source),
        credits:
          compact([
            credit(:source, "Quoted in", source.attribution || source.name, url),
            credit(:rights, "Rights", source.license, source.license_url)
          ]),
        links: %{source: url},
        reasons: compact([filed_here, note(item, ctx)])
      }
    else
      {:error, reason} -> withheld(item, reason)
    end
  end

  # A catalog work (#257): the committed row it pins, as its kind draws it.
  defp highlight(%CompositionItem{item_kind: :sense_definition} = item, ctx) do
    with {:ok, sense} <- sense(item.sense_revision_id), {:ok, meaning} <- meaning(item, ctx) do
      text = sense.gloss

      %Highlight{
        position: item.position,
        kind: :definition,
        register: :definition,
        reference: %Reference{
          object_id: item.item_object_id,
          object_kind: :sense,
          sense_revision_id: item.sense_revision_id
        },
        title: "Sense definition",
        creator: sense.source.name,
        source: source_view(sense.source),
        meaning: meaning,
        excerpt: %{
          text: text,
          html: Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(text)),
          chars: String.length(text),
          clipped?: false
        },
        links: %{source: sense.url},
        reasons: compact([note(item, ctx)])
      }
    else
      {:error, reason} -> withheld(item, reason)
    end
  end

  defp highlight(%CompositionItem{item_kind: :claim} = item, ctx) do
    basis = item.basis || (item.id && DevilsDictionary.Curation.ItemBasis.get(item.id))

    representation =
      if is_struct(basis), do: basis.representation, else: basis && basis["representation"]

    with %{} <- representation, {:ok, meaning} <- meaning(item, ctx) do
      label =
        Enum.join(
          [
            representation["subject_label"],
            representation["predicate_phrase"],
            representation["object_label"]
          ],
          " "
        )

      claim = Repo.get!(DevilsDictionary.Claims.AssertionRevision, item.assertion_revision_id)

      current =
        Enum.join(
          [
            DevilsDictionary.Curation.LinkedClaims.label(claim.subject_object_id),
            representation["predicate_phrase"],
            DevilsDictionary.Curation.LinkedClaims.label(claim.object_object_id)
          ],
          " "
        )

      %Highlight{
        position: item.position,
        kind: :linked_claim,
        title: label,
        current_label: if(current != label, do: current),
        reference: %Reference{
          object_id: item.item_object_id,
          object_kind: :entity,
          assertion_revision_id: item.assertion_revision_id
        },
        source: source_view(nil),
        links: %{connection: claim.assertion_id},
        meaning: meaning,
        reasons: compact([note(item, ctx)])
      }
    else
      _ -> withheld(item, :claim_unlinked)
    end
  end

  defp highlight(%CompositionItem{shelf_citation_id: id} = item, ctx) when is_integer(id) do
    citation = DevilsDictionary.Curation.ShelfCitations.get(id)
    draw_shelf(item, citation, ctx)
  end

  defp highlight(%CompositionItem{shelf: shelf} = item, ctx) when is_map(shelf) do
    result = Repo.get(DevilsDictionary.Discovery.Result, shelf[:result] || shelf["result"])

    if result do
      run = Repo.get!(DevilsDictionary.Discovery.Run, result.run_id)
      o = DevilsDictionary.Curation.ShelfCitations.observation(result, run)

      if o.status == :ok do
        c = %DevilsDictionary.Curation.ShelfCitation{
          source_id: o.source.id,
          source_record_id: o.record.id,
          source_record_revision_id: o.revision.id,
          cited_revision_id: o.revision.id,
          cited_checksum: o.revision.checksum,
          expires_at: o.expires_at,
          observed_at: o.observed_at,
          shelf_kind: o.kind
        }

        draw_shelf(item, c, ctx)
      else
        withheld(item, o.status)
      end
    else
      withheld(item, :observation_unbound)
    end
  end

  defp highlight(%CompositionItem{item_kind: :work, catalog_manifest: name} = item, ctx)
       when is_binary(name) do
    with {:ok, kind} <- catalog_kind(name),
         {:ok, row} <- catalog_row(name, item.catalog_identity),
         {:ok, meaning} <- meaning(item, ctx) do
      catalog = %{
        name: name,
        kind: kind,
        row: row,
        source: Sources.get_source_by_slug(Manifest.source_of(name)),
        object_id:
          item.item_object_id ||
            Eligibility.catalog_object(name, item.catalog_checksum, item.catalog_identity)
      }

      work(Manifest.work_kind(kind), item, catalog, meaning, ctx)
    else
      {:error, reason} -> withheld(item, reason)
    end
  end

  # An exemplar (#212, #257): the subject `Published.current/1` described,
  # the claim's reason and nominator as the Examples section reads them for
  # the public, and its provenance.
  defp highlight(%CompositionItem{item_kind: :exemplar, subject: %{} = subject} = item, ctx) do
    with {:ok, meaning} <- meaning(item, ctx),
         {:ok, passage} <- passage(subject, item),
         {:ok, example} <- example(item.assertion_revision_id, meaning),
         {:ok, provenance} <- found(ctx.provenance.(item), :claim_not_visible) do
      %Highlight{
        position: item.position,
        kind: :exemplar,
        register: if(passage, do: :quotation),
        reference: %Reference{
          object_id: subject.object_id,
          object_kind: subject.kind,
          content_revision_id: item.content_revision_id,
          assertion_revision_id: item.assertion_revision_id
        },
        title: subject.label,
        subject: %{
          kind: subject.kind,
          entity_kind: if(subject.kind == :entity, do: subject.subkind),
          content_kind: if(subject.kind == :content, do: subject.subkind),
          qid: example.subject.qid,
          words: passage && passage.body,
          html: passage && Markdown.to_html(passage.body, passage.body_format)
        },
        # The nominator by label only: an account id never reaches a page.
        claim: %{
          assertion_id: example.claim.assertion_id,
          rationale: example.claim.rationale,
          nominated_by: %{label: example.claim.nominated_by && example.claim.nominated_by.label}
        },
        meaning: meaning,
        source: source_view(passage && passage.source),
        credits: if(passage, do: passage_credits(passage), else: []),
        links: %{source: passage && passage.canonical_url},
        reasons: compact([note(item, ctx)]),
        provenance: provenance
      }
    else
      {:error, reason} -> withheld(item, reason)
    end
  end

  defp highlight(%CompositionItem{} = item, _ctx), do: withheld(item, :unsupported_item)

  defp draw_shelf(item, citation, ctx) do
    with %{} = payload <- DevilsDictionary.Curation.ShelfCitations.payload(citation),
         {:ok, meaning} <- meaning(item, ctx) do
      source = Repo.get!(Source, citation.source_id)
      metadata = payload["preview_metadata"] || %{}

      provider = DevilsDictionary.Discovery.Providers.get(source.slug)
      type = List.first(provider.capabilities().content_types)

      mark =
        if function_exported?(provider, :attribution_mark, 0),
          do: DevilsDictionaryWeb.Culture.mark(provider.attribution_mark())

      thumbnail = DevilsDictionary.Discovery.ContentTypes.thumbnail_url(type, metadata)
      attribution = DevilsDictionary.Discovery.ContentTypes.attribution(type)

      match =
        DevilsDictionary.Discovery.MatchReason.from_result(payload["match_details"], nil)
        |> Enum.map(
          &%Reason{kind: :source_match, text: DevilsDictionary.Discovery.MatchReason.describe(&1)}
        )

      date = DevilsDictionary.Curation.Shelf.date(source.slug, metadata)

      %Highlight{
        position: item.position,
        kind: :shelf,
        title: metadata["title"] || "untitled",
        creator: DevilsDictionary.Curation.Shelf.creator(metadata),
        date: date.value && to_string(date.value),
        source: source_view(source),
        meaning: meaning,
        reference: %Reference{
          object_id: item.item_object_id,
          object_kind: :entity,
          source_record_revision_id: item.source_record_revision_id,
          shelf_citation_id: citation.id
        },
        image: thumbnail && %{url: thumbnail, alt: ""},
        links: %{source: metadata["source_url"]},
        work: %{
          kind: citation.shelf_kind,
          attribution: attribution,
          mark: mark,
          credit_parts:
            DevilsDictionaryWeb.Culture.credit_parts(
              metadata["attribution"] || metadata["credit_line"],
              metadata
            )
        },
        credits:
          compact([
            credit(:source, "Source", source.name, metadata["source_url"]),
            credit(
              :creator,
              "Creator",
              DevilsDictionary.Curation.Shelf.creator(metadata),
              metadata["creator_url"]
            ),
            credit(:rights, "Rights", metadata["license"], metadata["license_url"])
          ]),
        reasons: match ++ compact([note(item, ctx)])
      }
    else
      _ -> withheld(item, DevilsDictionary.Curation.ShelfCitations.check(citation))
    end
  end

  # ── catalog works ────────────────────────────────────────────────────────

  defp catalog_kind(name) do
    case Candidates.manifest_kind(name) do
      nil -> {:error, :catalog_changed}
      kind -> {:ok, kind}
    end
  end

  # The pinned row of the committed manifest. `Eligibility` has found the row
  # in this build's manifest, so a manifest that answers none here is not the
  # one the record checked: it has changed (`Manifest.committed_row/2`).
  defp catalog_row(name, identity) do
    case Manifest.committed_row(name, identity) do
      %{} = row -> {:ok, row}
      nil -> {:error, :catalog_changed}
    end
  end

  defp work("artwork", item, catalog, meaning, ctx) do
    row = catalog.row

    case row["image_url"] do
      url when is_binary(url) and url != "" ->
        %Highlight{
          position: item.position,
          kind: :artwork,
          reference: catalog_reference(item, catalog),
          title: row["title"],
          creator: creator_of(row),
          date: row["date"] && to_string(row["date"]),
          image: %{url: url, alt: ""},
          meaning: meaning,
          source: source_view(catalog.source),
          credits:
            compact([
              credit(:image, "Image", row["credit_line"], commons_page(row)),
              credit(
                :catalog,
                "Catalog record",
                Enum.join(
                  compact([catalog.source && catalog.source.attribution, item.catalog_identity]),
                  " · "
                ),
                row["source_url"],
                false
              )
            ]),
          links: %{source: row["source_url"]},
          reasons: compact([depiction_reason(catalog, meaning), note(item, ctx)])
        }

      _none ->
        withheld(item, :no_image)
    end
  end

  # A poem by its row: title, poet and length. The row pins the lines by
  # their digest and does not hold them, so the tile quotes none and links to
  # the source the row names.
  defp work("poem", item, catalog, meaning, ctx) do
    row = catalog.row
    source = catalog.source

    %Highlight{
      position: item.position,
      kind: :poem,
      reference: catalog_reference(item, catalog),
      title: row["title"],
      creator: row["author"],
      meaning: meaning,
      source: source_view(source),
      work: %{line_count: row["line_count"]},
      credits:
        compact([
          credit(
            :source,
            "Source",
            source && (source.attribution || source.name),
            row["source_url"]
          ),
          credit(:rights, "Rights", source && source.license, source && source.license_url)
        ]),
      links: %{source: row["source_url"]},
      reasons: compact([note(item, ctx)])
    }
  end

  defp work("book", item, catalog, meaning, ctx) do
    row = catalog.row
    source = catalog.source

    %Highlight{
      position: item.position,
      kind: :book,
      reference: catalog_reference(item, catalog),
      title: row["title"],
      creator: row["authors"] |> List.wrap() |> Enum.map(& &1["name"]) |> compact() |> join(", "),
      date: row["year"] && to_string(row["year"]),
      meaning: meaning,
      source: source_view(source),
      work: %{public_domain: row["pd_basis"]},
      credits:
        compact([
          credit(
            :source,
            "Source",
            source && (source.attribution || source.name),
            row["source_url"]
          ),
          credit(:rights, "Rights", public_domain(row["pd_basis"]), nil),
          credit(
            :catalog,
            "Catalog record",
            source && source.license,
            source && source.license_url,
            false
          )
        ]),
      links: %{source: row["source_url"]},
      reasons: compact([note(item, ctx)])
    }
  end

  defp work(_work_kind, item, _catalog, _meaning, _ctx), do: withheld(item, :unsupported_item)

  defp catalog_reference(item, catalog) do
    %Reference{
      object_id: catalog.object_id,
      object_kind: :entity,
      catalog: %{
        manifest: catalog.name,
        checksum: item.catalog_checksum,
        identity: item.catalog_identity
      }
    }
  end

  # The basis the catalog recorded for a book being in the public domain, as
  # its manifest's selection rule states it.
  defp public_domain("publication"), do: "Public domain: published in or before 1929"

  defp public_domain("author_death"),
    do: "Public domain: every author died in or before 1955"

  defp public_domain(_basis), do: nil

  # The creators the row names: Wikidata's P170 terms, or the Met's artist.
  defp creator_of(%{"creators" => [_ | _] = creators}),
    do: creators |> Enum.map(& &1["term"]) |> compact() |> join(", ")

  defp creator_of(%{"artist" => artist}) when is_binary(artist) and artist != "", do: artist
  defp creator_of(_row), do: nil

  defp join([], _separator), do: nil
  defp join(list, separator), do: Enum.join(list, separator)

  # The Commons file page, where an image's licence is stated, when the
  # catalog committed the file name.
  defp commons_page(%{"commons_file" => file}) when is_binary(file) and file != "" do
    "https://commons.wikimedia.org/wiki/File:" <>
      URI.encode(String.replace(file, " ", "_"), &URI.char_unreserved?/1)
  end

  defp commons_page(_row), do: nil

  # Why the work fits the meaning, when the registry says so: a concept the
  # meaning publicly `refers_to` is among the row's committed depictions.
  defp depiction_reason(catalog, %Meaning{kind: :sense, object_id: sense_id}) do
    qids = References.refers_to_qids(sense_id)

    case Enum.find(References.pinned_depicts(catalog.row), &(&1["qid"] in qids)) do
      nil ->
        nil

      depicted ->
        %Reason{
          kind: :source_match,
          text:
            Artworks.depiction_note(%{catalog_source: Manifest.source_of(catalog.name)}, depicted)
        }
    end
  end

  defp depiction_reason(_catalog, _meaning), do: nil

  # ── exemplars ────────────────────────────────────────────────────────────

  # What the tile can draw: a thing by its name, or a quotation or passage by
  # its pinned words, with its source, under the quotation register.
  defp passage(%{kind: :entity}, _item), do: {:ok, nil}

  defp passage(%{kind: :content, subkind: kind}, item) when kind in [:quotation, :passage],
    do: content(item)

  defp passage(_subject, _item), do: {:error, :unsupported_subject}

  # The claim as the Examples section reads it for the public.
  defp example(revision_id, %Meaning{lexeme_id: lexeme_id}) do
    case Enum.find(
           Examples.exemplars([lexeme_id], :public),
           &(&1.claim.revision_id == revision_id)
         ) do
      nil -> {:error, :claim_not_visible}
      example -> {:ok, example}
    end
  end

  defp passage_credits(passage) do
    source = passage.source

    compact([
      credit(:source, "Quoted in", source.attribution || source.name, passage.canonical_url),
      credit(:rights, "Rights", source.license, source.license_url)
    ])
  end

  # The line at the item's locator, as the sense row on this page reads it:
  # the same trimming, citation and fingerprint. Its words were checked
  # against the selection's hash by `Published.current/1`.
  defp line(sense, "quotation:" <> index) do
    with {n, ""} <- Integer.parse(index),
         %{} = example <- Enum.at(List.wrap(sense.examples), n),
         [line] <- WordPage.quotations([example]).shown do
      {:ok, line}
    else
      _ -> {:error, :quotation_not_found}
    end
  end

  defp line(_sense, _locator), do: {:error, :quotation_not_found}

  # ── meanings ─────────────────────────────────────────────────────────────

  defp meaning(%CompositionItem{meaning_lexeme_id: id}, ctx) when is_integer(id) do
    case Enum.find(ctx.page.headword.lexemes, &(&1.id == id)) do
      nil ->
        {:error, :meaning_off_page}

      lexeme ->
        {:ok,
         %Meaning{
           kind: :lexeme,
           object_id: id,
           lexeme_id: id,
           label: lexeme.lemma,
           part_of_speech: lexeme.pos
         }}
    end
  end

  defp meaning(%CompositionItem{meaning_sense_revision_id: id}, ctx) when is_integer(id) do
    case sense(id) do
      {:ok, sense} ->
        {:ok,
         %Meaning{
           kind: :sense,
           object_id: sense.object_id,
           sense_revision_id: sense.sense_revision_id,
           lexeme_id: sense.lexeme_id,
           label: sense.gloss,
           part_of_speech: sense.part_of_speech,
           source: %{slug: sense.source.slug, name: sense.source.name},
           anchor: sense_anchor(ctx.page, sense.object_id)
         }}

      {:error, _reason} ->
        {:error, :meaning_deleted}
    end
  end

  defp meaning(_item, _ctx), do: {:error, :meaning_deleted}

  # A word's meaning, for a definition, is written on that definition's card.
  defp anchored(%Meaning{kind: :lexeme} = meaning, %{id: card_id}),
    do: %{meaning | anchor: "#" <> card_id}

  defp anchored(meaning, _card), do: meaning

  # The card on this page whose rows hold the sense.
  defp sense_anchor(page, sense_id) do
    Enum.find_value(page.cards, fn card ->
      if Enum.any?(card.groups, fn group -> Enum.any?(group.senses, &(&1.id == sense_id)) end),
        do: "#" <> card.id
    end)
  end

  # ── registry rows ────────────────────────────────────────────────────────

  # The exact revision an item names, with its source. Its eligibility was
  # settled by `Published.current/1`; this reads what to print.
  defp content(%CompositionItem{item_object_id: object_id, content_revision_id: revision_id})
       when is_integer(object_id) and is_integer(revision_id) do
    Repo.one(
      from r in ContentRevision,
        join: c in ContentItem,
        on: c.object_id == r.content_id,
        join: s in Source,
        on: s.id == c.source_id,
        where: r.id == ^revision_id and r.content_id == ^object_id,
        select: %{
          object_id: c.object_id,
          content_revision_id: r.id,
          source_record_revision_id: r.source_record_revision_id,
          body: r.body,
          body_format: r.body_format,
          headword: r.headword,
          metadata: r.metadata,
          year: r.year,
          canonical_url: r.canonical_url,
          source: s
        }
    )
    |> found(:revision_deleted)
  end

  defp content(_item), do: {:error, :revision_deleted}

  defp sense(revision_id) when is_integer(revision_id) do
    Repo.one(
      from r in SenseRevision,
        join: s in Sense,
        on: s.object_id == r.sense_id,
        join: l in Lexeme,
        on: l.object_id == s.lexeme_id,
        join: src in Source,
        on: src.id == s.source_id,
        where: r.id == ^revision_id,
        select: %{
          object_id: s.object_id,
          external_key: s.external_key,
          sense_revision_id: r.id,
          source_record_revision_id: r.source_record_revision_id,
          gloss: r.gloss,
          url: r.url,
          examples: r.examples,
          lexeme_id: l.object_id,
          lemma: l.lemma,
          part_of_speech: l.part_of_speech,
          source: src
        }
    )
    |> found(:revision_deleted)
  end

  defp sense(_revision_id), do: {:error, :revision_deleted}

  defp found(nil, reason), do: {:error, reason}
  defp found(row, _reason), do: {:ok, row}

  defp content_reference(content, locator) do
    %Reference{
      object_id: content.object_id,
      object_kind: :content,
      content_revision_id: content.content_revision_id,
      source_record_revision_id: content.source_record_revision_id,
      locator: locator
    }
  end

  # ── attribution ──────────────────────────────────────────────────────────

  # A note is its author's, under the label the database recorded with it
  # (K9): the reader never names anyone the item does not.
  defp note(%CompositionItem{note: text} = item, ctx) when is_binary(text) and text != "" do
    %Reason{
      kind: :editorial,
      text: text,
      author: %{
        kind: item.note_author_kind,
        label: item.note_author_label,
        attempt_id: Map.get(ctx[:attempts] || %{}, item.id)
      },
      reviewed_by: ctx.reviewed_by,
      reviewed_on: ctx.reviewed_on
    }
  end

  defp note(_item, _ctx), do: nil

  # The original attempt behind each model-written note (#253 D9), following
  # every copy edge before considering the containing version.
  defp attempts(items) do
    for %CompositionItem{id: id, note_author_kind: :model} <- items,
        is_integer(id),
        attempt = attempt_of(id, MapSet.new()),
        into: %{},
        do: {id, attempt}
  end

  defp attempt_of(id, visited) do
    if MapSet.member?(visited, id) do
      nil
    else
      case Repo.one(
             from i in CompositionItem,
               join: v in CompositionVersion,
               on: v.id == i.composition_version_id,
               where: i.id == ^id,
               select: {v.origin, v.attempt_id, i.copied_from_item_id}
           ) do
        # A carried note belongs to its original author, even inside a newer
        # model proposal. Follow provenance before the containing version.
        {_origin, _attempt, source} when is_integer(source) ->
          attempt_of(source, MapSet.put(visited, id))

        {:model, attempt_id, nil} ->
          attempt_id

        _other ->
          nil
      end
    end
  end

  defp actors(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Repo.all(from a in Actor, where: a.id in ^ids) |> Map.new(&{&1.id, &1})
  end

  # Who acted, by the label their actor carries (`Compositions.author_label/1`).
  # A manual composition's author and reviewer are people (K9, R1).
  defp person(nil), do: nil
  defp person(%Actor{actor_kind: :bot} = actor), do: %{kind: :model, label: label(actor)}
  defp person(%Actor{} = actor), do: %{kind: :human, label: label(actor)}

  defp label(nil), do: nil
  defp label(%Actor{} = actor), do: Compositions.author_label(actor)

  defp date(%DateTime{} = at), do: DateTime.to_date(at)
  defp date(_at), do: nil

  # ── presentation helpers, as the fixture reader writes them ──────────────

  defp content_credits(content) do
    source = content.source

    compact([
      credit(:source, "Source", source.attribution || source.name, source.homepage),
      credit(:entry, "Entry", entry_label(content), content.canonical_url, false),
      credit(:rights, "Rights", source.license, source.license_url)
    ])
  end

  defp printed_headword(content), do: content.metadata["printed_headword"] || content.headword
  defp marker(content), do: content.metadata["pos_marker"]

  defp entry_label(content) do
    case marker(content) do
      marker when is_binary(marker) and marker != "" ->
        "#{printed_headword(content)} (#{marker})"

      _none ->
        printed_headword(content)
    end
  end

  defp source_view(nil), do: %{slug: nil, name: nil, tier: nil, logo: nil}

  defp source_view(source) do
    %{
      slug: source.slug,
      name: source.name,
      tier: source.tier,
      logo: source.logo,
      attribution: source.attribution,
      license: source.license,
      license_url: source.license_url,
      homepage: source.homepage,
      era_year: source.era_year,
      edition_year: if(source.access in [:static, :dump], do: source.era_year)
    }
  end

  # "Ambrose Bierce, The Devil's Dictionary": the author before the comma and
  # the work after it, as a card's header reads it.
  defp author_of(source), do: source.name |> String.split(",", parts: 2) |> hd() |> String.trim()

  defp work_of(source) do
    case String.split(source.name, ",", parts: 2) do
      [_author, work] -> String.trim(work)
      [_only] -> nil
    end
  end

  defp credit(role, label, text, href, required? \\ true)
  defp credit(_role, _label, text, _href, _required?) when text in [nil, ""], do: nil

  defp credit(role, label, text, href, required?),
    do: %Credit{role: role, label: label, text: text, href: href, required?: required?}

  defp compact(list), do: Enum.reject(list, &(&1 in [nil, false]))

  defp withheld(%CompositionItem{role: role, position: position}, reason),
    do: %{role: role, position: position, reason: reason}
end
