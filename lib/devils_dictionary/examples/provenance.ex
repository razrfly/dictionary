defmodule DevilsDictionary.Examples.Provenance do
  @moduledoc """
  Why an example is on the page (#212): one answer, assembled from the
  records and only from them, for every surface that shows an example. The
  exemplar card's disclosure, the person page, the opening (#156) and #203's
  history all read this one projection, so their attributions cannot
  disagree.

  It has no table. Reading it writes nothing: a page view is not an event, and
  a manifest replay (`:held`) is not a nomination.

  ## The stages

      %Provenance{
        id: "ex:<assertion_id>" | "inst:<family>" | "sel:<composition_item_id>",
        source: [%{slug, name, tier, assertion_id, record_url}] | :none,
        nomination: %{by, claimant, origin, shelf, manifest, rationale, meaning,
                      evidence, at} | :none | :unknown,
        agent: :none | :unknown,
        review: %{state, by, decided_at, context_changed?} | :none,
        selection: %{kind: :ranked, signals} | %{kind: :composed, ...}
                 | %{kind: :fixture, composition, version, selected_by},
        publication: %{receipt_id, authority_kind, actor, committed_at,
                       superseded_at, withdrawn_at} | :none,
        featured: [%{composition_id, version, selected_by, published_at, scope,
                     shown_on_page: false}]
      }

  | Stage | Read from | `:none` means | `:unknown` means |
  |---|---|---|---|
  | `source` | `assertions.source_id`, `source_assertion_outputs` → `source_records.url` | not source-listed (an exemplar) | never |
  | `nomination` | the submitting account (or a manifest's curator), the revision's `rationale`, `metadata` and `method`, `assertion_evidence`, `assertions.inserted_at` | not cited (an instance) | a claim no account submitted and no manifest wrote |
  | `agent` | the revision's `method` (and #197's records, once they exist) | human work (`curated`), or a source's (an instance) | any other method, or none recorded |
  | `review` | the latest `assertion_reviews` row, and its context against what is displayed | no review yet | never |
  | `selection` | `Rank.order/1`'s signals, or the composition item and its version's author, or the development fixture that placed it in an opening (`in_fixture/2`) | — | never |
  | `publication` | the receipt that published the item's version | unpublished | never |

  `featured` is the reverse of selection (#212 decision 3): the published
  compositions of the enabled global default configuration that select this
  claim now, read through `Published.current/1`, so a withheld item is never
  listed and an internal test configuration's never are. Each names the words
  of its scope. No page shows a composition yet (the binding is #194's, the
  reader #156 Phase 2's), so each entry says `shown_on_page: false`, and no
  surface claims the claim is on a page. The card's "Opening" row and the
  person page's line read it.

  ## Who may see what

  A claim is read through `Claims.visible/2` for the viewer, and a claim the
  viewer may not see has no provenance at all (`nil`): no stage, no count, no
  label. For the public, a nomination whose latest review is not `accepted`
  has none either, whatever its subject and whoever submitted it, a legacy
  claim with no nominator included (#212 decision 1). Every attribution is
  an actor's public label, never an account id or an email. `nomination.by`
  is the nominating account, by the card's own rule (`nominator/2`); a
  claimant the claim cites is `nomination.claimant`, never the nominator.

  Only a receipt's `committed_at` is a publication time; a row's update time
  never is.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionReview, AssertionRevision}

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionMembership,
    CompositionPublication,
    CompositionVersion,
    Configuration,
    Published
  }

  alias DevilsDictionary.Examples
  alias DevilsDictionary.Registry.{Entity, Lexeme, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, Source, SourceRecord}

  @no_author %{kind: :unknown, label: nil}

  @enforce_keys [:id, :source, :nomination, :agent, :review, :selection, :publication]
  defstruct [:id, :source, :nomination, :agent, :review, :selection, :publication, featured: []]

  @type t :: %__MODULE__{}

  @doc """
  The provenance of one example for a viewer (`:public` or `:internal`): an
  `Examples` item, or a `CompositionItem`. `nil` when the viewer may not see
  the claim it rests on.
  """
  def of(item, viewer \\ :public), do: [item] |> many(viewer) |> hd()

  @doc "`of/2` for many items, in their order, with a bounded number of queries."
  def many([], _viewer), do: []

  def many(items, viewer) when viewer in [:public, :internal] do
    records = load(items, viewer)
    Enum.map(items, &project(&1, records))
  end

  @doc """
  Adds `:provenance` to each exemplar of an `Examples` read: the result of
  `Examples.for_page/3`, or the groups of `Examples.cited_as/2`. Instances
  are left alone: an instance chip's provenance is the `/connections/:id` of
  each contributing claim.
  """
  def attach(%{items: items} = examples, viewer),
    do: %{examples | items: attach_items(items, viewer)}

  def attach(groups, viewer) when is_list(groups) do
    by_id =
      groups
      |> Enum.flat_map(& &1.items)
      |> attach_items(viewer)
      |> Map.new(&{&1.id, &1})

    Enum.map(groups, fn group -> %{group | items: Enum.map(group.items, &by_id[&1.id])} end)
  end

  defp attach_items(items, viewer) do
    exemplars = Enum.filter(items, &(&1.layer == :exemplar))
    provenance = exemplars |> Enum.map(& &1.id) |> Enum.zip(many(exemplars, viewer)) |> Map.new()

    Enum.map(items, fn
      %{layer: :exemplar, id: id} = item -> Map.put(item, :provenance, provenance[id])
      item -> item
    end)
  end

  @doc """
  The provenance of an exemplar a development fixture placed in a word's
  opening (#212 Build 3, behind `?opening=fixture`): `provenance` is the
  claim's, as `of/2` reads it for the card, and every stage about the claim
  stays exactly as the card has it. Only the two stages about this placement
  change: `selection` is the fixture's (its key, version and who chose it),
  and `publication` is `:none`, because a fixture is never published.
  """
  def in_fixture(%__MODULE__{} = provenance, %{composition: id, version: version} = fixture) do
    %{
      provenance
      | selection: %{
          kind: :fixture,
          composition: id,
          version: version,
          selected_by: fixture[:selected_by] || @no_author
        },
        publication: :none
    }
  end

  @doc """
  Who nominated a claim, as every surface names it: a manifest's curator,
  else the account that submitted it. A cited claimant is who *makes* the
  claim, not who nominated it here (the form's "Who makes this
  interpretation?"), so it is never the nominator; `claimant/2` names it
  apart. `nil` when the record names nobody.
  """
  def nominator(metadata, submitter_label), do: (metadata || %{})["curator"] || submitter_label

  # ── loading ───────────────────────────────────────────────────────────────

  defp load(items, viewer) do
    ids =
      items
      |> Enum.flat_map(&claim_revisions/1)
      |> Enum.uniq()
      |> visible(viewer)

    claims = claims(ids)
    reviews = reviews(ids)
    ids = Enum.filter(ids, &disclosed?(viewer, reviews[&1]))

    %{
      visible: MapSet.new(ids),
      claims: claims,
      reviews: reviews,
      states: Claims.display_review_states(ids),
      evidence: Examples.evidence(ids),
      meanings: meanings(ids),
      featured: featured(ids),
      sources: Map.new(Repo.all(Source), &{&1.slug, &1}),
      record_urls: record_urls(items),
      compositions: compositions(items)
    }
  end

  defp claim_revisions(%{layer: :exemplar, claim: %{revision_id: id}}), do: [id]
  defp claim_revisions(%CompositionItem{assertion_revision_id: id}) when is_integer(id), do: [id]
  defp claim_revisions(_item), do: []

  defp visible([], _viewer), do: []

  defp visible(ids, viewer) do
    from(r in AssertionRevision, where: r.id in ^ids, select: r.id)
    |> Claims.visible(viewer)
    |> Repo.all()
  end

  # The public sees no provenance for a nomination nobody has accepted yet,
  # whatever its subject and whoever submitted it (#212 decision 1, option
  # a). `Claims.visible/2` hides a pending *person* everywhere; a pending work
  # or passage may still have its card (#190 owns that gate), but none of the
  # new surfaces carries it. A claim no account submitted (an import, a
  # legacy row) is a nomination whose nominator is unknown, and is held to
  # the same rule: its record says so only once a reviewer has accepted it.
  defp disclosed?(:internal, _review), do: true
  defp disclosed?(:public, review), do: match?(%{state: :accepted}, review)

  defp claims([]), do: %{}

  defp claims(ids) do
    Repo.all(
      from r in AssertionRevision,
        join: a in Assertion,
        on: a.id == r.assertion_id,
        left_join: claimant in Actor,
        on: claimant.id == a.origin_actor_id,
        left_join: submitter in Actor,
        on: submitter.id == a.submitted_by_actor_id,
        where: r.id in ^ids,
        select:
          {r.id,
           %{
             assertion_id: a.id,
             nominated_at: a.inserted_at,
             method: r.method,
             metadata: r.metadata,
             rationale: r.rationale,
             claimant: %{id: claimant.id, kind: claimant.actor_kind, label: claimant.label},
             submitter: %{id: submitter.id, kind: submitter.actor_kind, label: submitter.label}
           }}
    )
    |> Map.new()
  end

  defp reviews([]), do: %{}

  defp reviews(ids) do
    Repo.all(
      from review in AssertionReview,
        left_join: reviewer in Actor,
        on: reviewer.id == review.reviewer_actor_id,
        where: review.assertion_revision_id in ^ids,
        distinct: review.assertion_revision_id,
        order_by: [asc: review.assertion_revision_id, desc: review.inserted_at, desc: review.id],
        select:
          {review.assertion_revision_id,
           %{state: review.decision, decided_at: review.inserted_at, label: reviewer.label}}
    )
    |> Map.new()
  end

  # The meaning a claim names: a sense (its word and current gloss), or a
  # concept (its label).
  defp meanings([]), do: %{}

  defp meanings(ids) do
    Repo.all(
      from r in AssertionRevision,
        left_join: s in Sense,
        on: s.object_id == r.object_object_id,
        left_join: l in Lexeme,
        on: l.object_id == s.lexeme_id,
        left_join: rev in SenseRevision,
        on: rev.sense_id == s.object_id and rev.is_current,
        left_join: e in Entity,
        on: e.object_id == r.object_object_id,
        where: r.id in ^ids,
        select:
          {r.id,
           %{
             sense_key: s.external_key,
             sense_revision_id: rev.id,
             gloss: coalesce(rev.gloss, e.preferred_label),
             lemma: l.lemma,
             slug: l.slug
           }}
    )
    |> Map.new()
  end

  # The published compositions that select each claim revision now, under
  # the enabled global default configuration: the only configuration a page
  # would ever read (ADR 0004). An internal test configuration's compositions
  # are never listed. A composition features the claim only if
  # `Published.current/1` shows that item, so a withheld one never is.
  #
  # No page shows a composition yet: the page binding is #194's and the
  # reader #156 Phase 2's. So `shown_on_page` is `false` for every entry, and
  # the surfaces say so rather than claim the item is on a page.
  defp featured([]), do: %{}

  defp featured(ids) do
    rows =
      Repo.all(
        from i in CompositionItem,
          join: c in Composition,
          on: c.current_published_version_id == i.composition_version_id,
          join: config in Configuration,
          on: config.id == c.curation_configuration_id,
          where: config.role == :global_default and config.state == :enabled,
          where: i.item_kind == :exemplar and i.assertion_revision_id in ^ids,
          select: {c.id, i.id, i.assertion_revision_id}
      )

    composition_ids = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    scopes = scopes(composition_ids)

    rows
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {composition_id, rows} ->
      case Published.current(composition_id) do
        {:ok, published} ->
          shown = MapSet.new(published.highlights, & &1.id)

          for {_composition, item_id, revision_id} <- rows, MapSet.member?(shown, item_id) do
            {revision_id, published, Map.get(scopes, composition_id, [])}
          end

        _withheld_or_unpublished ->
          []
      end
    end)
    |> then(fn entries ->
      authors =
        entries
        |> Enum.map(fn {_rid, published, _scope} -> published.version.created_by_actor_id end)
        |> authors()

      entries
      |> Enum.group_by(&elem(&1, 0), fn {_rid, published, scope} ->
        %{
          composition_id: published.composition.id,
          version: published.version.version,
          selected_by: Map.get(authors, published.version.created_by_actor_id, @no_author),
          published_at: published.receipt.committed_at,
          scope: scope,
          shown_on_page: false
        }
      end)
      |> Map.new(fn {id, entries} -> {id, Enum.sort_by(entries, & &1.composition_id)} end)
    end)
  end

  # The words a composition is for: its scope's member lexemes, never an
  # item's intended meaning.
  defp scopes([]), do: %{}

  defp scopes(composition_ids) do
    Repo.all(
      from m in CompositionMembership,
        join: l in Lexeme,
        on: l.object_id == m.object_id,
        where: m.composition_id in ^composition_ids,
        order_by: [m.composition_id, l.lemma],
        select: {m.composition_id, %{lemma: l.lemma, slug: l.slug}}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp authors([]), do: %{}

  defp authors(actor_ids) do
    Repo.all(from a in Actor, where: a.id in ^Enum.uniq(actor_ids))
    |> Map.new(&{&1.id, author_of(&1)})
  end

  # A version's author: a person, or (after #197) a model's bot.
  defp author(actor_id), do: Map.get(authors([actor_id]), actor_id, @no_author)

  defp author_of(%Actor{actor_kind: :user, label: label}), do: %{kind: :human, label: label}
  defp author_of(%Actor{actor_kind: :bot, label: label}), do: %{kind: :model, label: label}
  defp author_of(_actor), do: @no_author

  # Each contributing claim's source record URL, for an instance's sources.
  defp record_urls(items) do
    ids =
      items
      |> Enum.flat_map(fn
        %{layer: :instance, sources: sources} -> Enum.flat_map(sources, & &1.assertion_ids)
        _item -> []
      end)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Repo.all(
        from out in "source_assertion_outputs",
          join: rec in SourceRecord,
          on: rec.id == out.source_record_id,
          where: out.assertion_id in ^ids and is_nil(out.retired_at),
          distinct: out.assertion_id,
          order_by: [out.assertion_id, out.source_record_id],
          select: {out.assertion_id, rec.url}
      )
      |> Map.new()
    end
  end

  # For a composition item: its version, and its composition's receipts.
  defp compositions(items) do
    case for(%CompositionItem{composition_version_id: id} <- items, uniq: true, do: id) do
      [] ->
        %{}

      version_ids ->
        versions = Repo.all(from v in CompositionVersion, where: v.id in ^version_ids)
        composition_ids = Enum.map(versions, & &1.composition_id)

        receipts =
          Repo.all(
            from p in CompositionPublication,
              left_join: actor in Actor,
              on: actor.id == p.actor_id,
              where: p.composition_id in ^composition_ids,
              order_by: [p.composition_id, p.id],
              select: {p, actor.label}
          )
          |> Enum.group_by(fn {p, _label} -> p.composition_id end)

        Map.new(versions, fn v ->
          {v.id, %{version: v, receipts: Map.get(receipts, v.composition_id, [])}}
        end)
    end
  end

  # ── projecting ────────────────────────────────────────────────────────────

  defp project(%{layer: :exemplar, id: id, claim: %{revision_id: rid}} = item, records) do
    if MapSet.member?(records.visible, rid) do
      %__MODULE__{
        id: id,
        source: :none,
        nomination: nomination(records.claims[rid], rid, records),
        agent: agent(records.claims[rid].method),
        review: review(rid, records),
        selection: %{kind: :ranked, signals: item.signals},
        publication: :none,
        featured: Map.get(records.featured, rid, [])
      }
    end
  end

  defp project(%{layer: :instance, id: id} = item, records) do
    %__MODULE__{
      id: id,
      source: instance_sources(item, records),
      nomination: :none,
      agent: :none,
      review: :none,
      selection: %{kind: :ranked, signals: item.signals},
      publication: :none
    }
  end

  defp project(%CompositionItem{assertion_revision_id: rid} = item, records)
       when is_integer(rid) do
    if MapSet.member?(records.visible, rid) do
      %__MODULE__{
        id: "sel:#{item.id}",
        source: :none,
        nomination: nomination(records.claims[rid], rid, records),
        agent: agent(records.claims[rid].method),
        review: review(rid, records),
        selection: composed(item, records),
        publication: publication(item, records)
      }
    end
  end

  defp project(%CompositionItem{} = item, records) do
    %__MODULE__{
      id: "sel:#{item.id}",
      source: :none,
      nomination: :none,
      agent: :none,
      review: :none,
      selection: composed(item, records),
      publication: publication(item, records)
    }
  end

  defp instance_sources(%{sources: sources}, records) do
    for source <- sources, assertion_id <- source.assertion_ids do
      %{
        slug: source.slug,
        name: source.name,
        tier: source.tier,
        assertion_id: assertion_id,
        record_url: records.record_urls[assertion_id]
      }
    end
  end

  # A claim with no submitting account and no manifest is one the record is
  # silent about: its nominator is unknown, never "a contributor", and never
  # the claimant it cites.
  defp nomination(claim, rid, records) do
    metadata = claim.metadata || %{}
    submitter = claim.submitter

    if is_nil(metadata["curator"]) and submitter.kind not in [:user, :bot] do
      :unknown
    else
      %{
        by: %{
          kind: submitter.kind,
          label: nominator(metadata, submitter.label),
          actor_id: submitter.id
        },
        claimant: claimant(claim.claimant, submitter),
        origin: origin(metadata, claim),
        shelf: shelf(metadata, records.sources),
        manifest: manifest(metadata),
        rationale: claim.rationale,
        meaning: records.meanings[rid],
        evidence: Map.get(records.evidence, rid, []),
        at: claim.nominated_at
      }
    end
  end

  @doc """
  Who the claim cites as making it, when that is not the nominating account
  itself: `%{kind: :external | :unknown | ..., label}`, or `nil`.
  """
  def claimant(%{id: nil}, _submitter), do: nil
  def claimant(%{id: id}, %{id: id}), do: nil
  def claimant(%{kind: kind, label: label}, _submitter), do: %{kind: kind, label: label}

  # How the claim was nominated, as far as the record says. A manifest names
  # itself; a persona's method is an agent's. A claim an account submitted
  # with no manifest came through the form: `Contributions.propose/6` has two
  # callers, and the other, `Examples.Seeder`, always records its manifest.
  defp origin(%{"manifest" => manifest}, _claim) when is_binary(manifest), do: :manifest
  defp origin(_metadata, %{method: "persona:" <> _}), do: :agent
  defp origin(_metadata, %{submitter: %{kind: kind}}) when kind in [:user, :bot], do: :form
  defp origin(_metadata, _claim), do: :unknown

  # The shelf a form nomination was prefilled from, when the form recorded
  # one (`ConnectionLive`). Retention may since have deleted the result; the
  # provider is a `sources` row, which it does not.
  defp shelf(%{"provider" => slug} = metadata, sources) when is_binary(slug) do
    %{
      provider: slug,
      name: (sources[slug] && sources[slug].name) || slug,
      result_id: metadata["from_result"]
    }
  end

  defp shelf(_metadata, _sources), do: nil

  defp manifest(%{"manifest" => slug} = metadata) when is_binary(slug),
    do: %{slug: slug, checksum: metadata["manifest_checksum"], row: metadata["row"]}

  defp manifest(_metadata), do: nil

  # No model record exists before #197, so a persona's work is `:unknown`,
  # never a fabricated model, run or proposal.
  defp agent("curated"), do: :none
  defp agent(_method), do: :unknown

  defp review(rid, records) do
    case records.reviews[rid] do
      nil ->
        :none

      review ->
        %{
          state: review.state,
          by: %{label: review.label},
          decided_at: review.decided_at,
          context_changed?: Map.get(records.states, rid) == :changed_since_review
        }
    end
  end

  defp composed(%CompositionItem{} = item, records) do
    %{version: version} = Map.fetch!(records.compositions, item.composition_version_id)

    %{
      kind: :composed,
      composition_id: version.composition_id,
      version: version.version,
      role: item.role,
      position: item.position,
      selection_origin: item.selection_origin,
      selected_by: author(version.created_by_actor_id),
      note: item.note && %{text: item.note, author: item.note_author_label}
    }
  end

  # The latest receipt that published the item's version, and what came
  # after it: a later publication supersedes it, and a withdrawal takes it
  # down.
  defp publication(%CompositionItem{composition_version_id: version_id}, records) do
    %{receipts: receipts} = Map.fetch!(records.compositions, version_id)

    receipts
    |> Enum.reverse()
    |> Enum.split_while(fn {p, _label} ->
      not (p.action == :publish and p.published_version_id == version_id)
    end)
    |> case do
      {_later, []} ->
        :none

      {later, [{receipt, label} | _earlier]} ->
        later = Enum.reverse(later)
        next = Enum.find(later, fn {p, _label} -> p.previous_version_id == version_id end)

        %{
          receipt_id: receipt.id,
          authority_kind: receipt.authority_kind,
          actor: %{label: label},
          committed_at: receipt.committed_at,
          superseded_at: after_receipt(next, :publish),
          withdrawn_at: after_receipt(next, :withdraw)
        }
    end
  end

  defp after_receipt({%{action: action, committed_at: at}, _label}, action), do: at
  defp after_receipt(_next, _action), do: nil
end
