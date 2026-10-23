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
      review the receipt cites, and the publication receipt.

  A `work` or `exemplar` highlight is withheld as `:unsupported_item`: P1
  shows definitions and quotations, and #254's later parts add the rest.

  Reads only: no provider, no model, no write and no refresh admission.
  """

  @behaviour DevilsDictionary.Curation.OpeningReader

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    CompositionItem,
    CompositionReview,
    Compositions,
    Configurations,
    Excerpt,
    LeadPolicy,
    Opening,
    Published
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
    review = Repo.get(CompositionReview, receipt.authorizing_review_id)

    actors =
      actors([version.created_by_actor_id, receipt.actor_id, review && review.reviewer_actor_id])

    ctx = %{
      page: page,
      reviewed_by: review && label(actors[review.reviewer_actor_id]),
      reviewed_on: review && date(review.inserted_at)
    }

    {lead, lead_withheld} = lead(published.lead, ctx)

    {highlights, highlight_withheld} =
      published.highlights
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&highlight(&1, ctx))
      |> Enum.split_with(&match?(%Highlight{}, &1))

    %Opening{
      composition: %{id: composition.id, version: version.version},
      origin: :published,
      configuration: %Configuration{
        id: configuration.id,
        slug: configuration.slug,
        version: configuration_version.version,
        lead_rule: configuration_version.lead_policy,
        resolution_reason: :global_default,
        resolution_policy_version: @resolution_policy_version
      },
      lead: lead,
      highlights: highlights,
      review: %Review{
        state: :published,
        selected_by: person(actors[version.created_by_actor_id]),
        selected_on: date(version.inserted_at),
        reviewed_by: ctx.reviewed_by,
        reviewed_on: ctx.reviewed_on,
        published_by: person(actors[receipt.actor_id]),
        published_on: date(receipt.committed_at),
        receipt_id: receipt.id
      },
      withheld:
        Enum.sort_by(
          published.withheld ++ lead_withheld ++ highlight_withheld,
          &{&1.role != :lead, &1.position || 0}
        )
    }
  end

  # ── the lead ─────────────────────────────────────────────────────────────

  defp lead(nil, _ctx), do: {nil, []}

  defp lead(%CompositionItem{} = item, ctx) do
    with {:ok, content} <- content(item),
         {:ok, card, entry} <- page_entry(ctx.page, item.item_object_id),
         {:ok, excerpt} <- Excerpt.sentences(content.body, content.body_format, @lead_sentences),
         {:ok, meaning} <- meaning(item, ctx) do
      source = content.source
      policy = lead_policy(source)

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
        reasons:
          compact([%Reason{kind: :policy, text: LeadPolicy.statement(policy)}, note(item, ctx)])
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

  defp highlight(%CompositionItem{} = item, _ctx), do: withheld(item, :unsupported_item)

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
      author: %{kind: item.note_author_kind, label: item.note_author_label},
      reviewed_by: ctx.reviewed_by,
      reviewed_on: ctx.reviewed_on
    }
  end

  defp note(_item, _ctx), do: nil

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

  defp source_view(source) do
    %{
      slug: source.slug,
      name: source.name,
      tier: source.tier,
      logo: source.logo,
      attribution: source.attribution,
      license: source.license,
      license_url: source.license_url,
      homepage: source.homepage
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
