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
        nomination: %{by, origin, shelf, manifest, rationale, meaning, evidence, at}
                    | :none | :unknown,
        agent: :none | :unknown,
        review: %{state, by, decided_at, context_changed?} | :none,
        selection: %{kind: :ranked, signals} | %{kind: :composed, ...},
        publication: %{receipt_id, authority_kind, actor, committed_at,
                       superseded_at, withdrawn_at} | :none,
        featured: [%{composition_id, version, position, selected_by, published_at, page}]
      }

  | Stage | Read from | `:none` means | `:unknown` means |
  |---|---|---|---|
  | `source` | `assertions.source_id`, `source_assertion_outputs` → `source_records.url` | not source-listed (an exemplar) | never |
  | `nomination` | the claim's actors, the revision's `rationale`, `metadata` and `method`, `assertion_evidence`, `assertions.inserted_at` | not cited (an instance) | a claim with no actor and no manifest |
  | `agent` | the revision's `method` (and #197's records, once they exist) | human work (`curated`) or a source's | a persona's method, or no method recorded |
  | `review` | the latest `assertion_reviews` row, and its context against what is displayed | no review yet | never |
  | `selection` | `Rank.order/1`'s signals, or the composition item and its version's author | — | never |
  | `publication` | the receipt that published the item's version | unpublished | never |

  `featured` is the reverse of selection (#212 decision 3): the published
  openings that show this claim now, read through `Published.current/1`, so
  a withheld item is never listed. An example's card reads its "Opening" row
  from it, and the person page its "featured in" line.

  ## Who may see what

  A claim is read through `Claims.visible/2` for the viewer, and a claim the
  viewer may not see has no provenance at all (`nil`): no stage, no count, no
  label. Every attribution is an actor's public label, never an account id or
  an email. `nomination.by` follows the card's rule, `nominator/3`.

  Only a receipt's `committed_at` is a publication time; a row's update time
  never is.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionReview, AssertionRevision}

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionPublication,
    CompositionVersion,
    Published
  }

  alias DevilsDictionary.Examples
  alias DevilsDictionary.Registry.{Entity, Lexeme, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, Source, SourceRecord}

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
  Who a nomination is by, as every surface names it: a manifest's curator,
  else the claimant's label, else the submitter's. `nil` when the record
  names nobody.
  """
  def nominator(metadata, claimant_label, submitter_label),
    do: (metadata || %{})["curator"] || claimant_label || submitter_label

  # ── loading ───────────────────────────────────────────────────────────────

  defp load(items, viewer) do
    ids =
      items
      |> Enum.flat_map(&claim_revisions/1)
      |> Enum.uniq()
      |> visible(viewer)

    %{
      visible: MapSet.new(ids),
      claims: claims(ids),
      reviews: reviews(ids),
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

  # The published openings that show each claim revision now. A composition
  # is a candidate when its published version holds an exemplar naming the
  # revision, and it features the claim only if `Published.current/1` shows
  # that item.
  defp featured([]), do: %{}

  defp featured(ids) do
    Repo.all(
      from i in CompositionItem,
        join: c in Composition,
        on: c.current_published_version_id == i.composition_version_id,
        where: i.item_kind == :exemplar and i.assertion_revision_id in ^ids,
        select: {c.id, i.id, i.assertion_revision_id}
    )
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {composition_id, rows} ->
      case Published.current(composition_id) do
        {:ok, published} ->
          shown = Map.new(published.highlights, &{&1.id, &1})

          for {_composition, item_id, revision_id} <- rows, Map.has_key?(shown, item_id) do
            {revision_id, featured_entry(published, shown[item_id])}
          end

        _withheld_or_unpublished ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, entries} -> {id, Enum.sort_by(entries, & &1.composition_id)} end)
  end

  defp featured_entry(published, item) do
    %{
      composition_id: published.composition.id,
      version: published.version.version,
      position: item.position,
      selected_by: author(published.version.created_by_actor_id),
      published_at: published.receipt.committed_at,
      page: page(item)
    }
  end

  # The word whose page the opening is on: the item's intended meaning.
  defp page(%CompositionItem{meaning_lexeme_id: id}) when is_integer(id), do: word(id)

  defp page(%CompositionItem{meaning_sense_revision_id: id}) when is_integer(id) do
    from(r in SenseRevision,
      join: s in Sense,
      on: s.object_id == r.sense_id,
      where: r.id == ^id,
      select: s.lexeme_id
    )
    |> Repo.one()
    |> word()
  end

  defp page(_item), do: nil

  defp word(nil), do: nil

  defp word(lexeme_id) do
    Repo.one(
      from l in Lexeme, where: l.object_id == ^lexeme_id, select: %{lemma: l.lemma, slug: l.slug}
    )
  end

  # A version's author: a person, or (after #197) a model's bot.
  defp author(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{actor_kind: :user, label: label} -> %{kind: :human, label: label}
      %Actor{actor_kind: :bot, label: label} -> %{kind: :model, label: label}
      _other -> %{kind: :unknown, label: nil}
    end
  end

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

  # A claim with no actor and no manifest is one the record is silent about:
  # its nominator is unknown, never "a contributor".
  defp nomination(claim, rid, records) do
    metadata = claim.metadata || %{}
    label = nominator(metadata, claim.claimant.label, claim.submitter.label)
    actor = if claim.claimant.id, do: claim.claimant, else: claim.submitter

    if is_nil(label) and is_nil(actor.id) do
      :unknown
    else
      %{
        by: %{kind: actor.kind || :unknown, label: label, actor_id: actor.id},
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
  defp agent("persona:" <> _), do: :unknown
  defp agent(nil), do: :unknown
  defp agent(_method), do: :none

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
