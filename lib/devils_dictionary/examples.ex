defmodule DevilsDictionary.Examples do
  @moduledoc """
  A word's examples: the named things filed under its meanings (#181).

  Two layers share this read model and never share a signal:

    * **instances** (layer 1, built here) — a named thing a *source* files
      under a meaning: WordNet's `instance_hypernym` between two senses, and
      Wikidata's P31 between two things, both stored as `instance_of`, instance
      → class. Source-listed: the source adjudicated it, this site did not, and
      a reviewer can still reject one (`Claims.visible/2` hides it then).
    * **exemplars** (layer 2, build 2) — a thing a *person* cites as an example
      of a meaning, with a why and evidence: an `illustrates` claim, read by
      `exemplars/3` through `Claims.visible/2` for the viewer, and backwards
      on the subject's page by `cited_as/2`. Written only through
      `Contributions.propose/6` (the form, or `mix dd.exemplars.seed`).

  A usage example — a sentence using the word — is neither, and is not read
  here: it belongs to the sense it illustrates and renders inside that card.

  ## The item

  `for_page/3` returns every item in `Rank.order/1`'s order, each:

      %{
        id: "inst:e<entity>" | "inst:s<synset>",   # stable across renders and re-absorbs
        layer: :instance,
        basis: :record,
        subject: %{kind: :lexeme | :entity, object_id, label, slug, entity_id,
                   entity_kind, aliases, enriched?, thumbnail: nil},
        target: %{kind: :sense | :entity, object_id, gloss, label},
        sources: [%{slug, name, tier, logo, kind: :sense | :entity, assertion_ids}],
        claim: nil,
        signals: %{source_count, best_tier, human_up: 0, human_down: 0,
                   bot_up: 0, bot_down: 0, evidence_count: 0, featured_at: nil},
        reason: "WordNet names it under “…”."
      }

  `thumbnail` is `nil` in build 1 on purpose: no surface draws one yet, and an
  entity's image is only shown after `SourceIdentity.Display` has checked the
  record that supplied it is still displayable — a query a page should not pay
  for a picture it does not draw. The band (#156) fills it when it lands.

  ## One thing, one item

  An item is **one named thing on this page**, however many edges name it:

    * WordNet files each *member* of a synset under each member of the class,
      so *dictator*'s 20 edges are six people — Hitler, Adolf Hitler and Der
      Fuhrer are one synset, and one chip. The synset is the thing; its members
      are aliases, and the chip is labelled by the fullest of them.
    * A synset whose senses `refers_to` exactly **one** entity is that entity,
      so when WordNet files *Peloponnesian War* under *war* and Wikidata files
      Q33745 as an instance of Q198, the page shows one chip with both sources
      (corroboration is sources agreeing, C4). Two entities, or none, and the
      synset stays itself: merging on a label is the identity-by-string mistake
      #74 exists to end.
    * A thing filed under two senses of the word is still one chip, under the
      first of them.

  ## Queries

  On a word page, WordNet's side costs no statement of its own: the edges
  arrive with `WordPage.relations/2`, which `union_all`s `instance_edges/2`
  into the relations query it already ran — the one object-side read the page
  makes. What remains is one query for Wikidata's instances of the things the
  page's senses `refers_to`, and one resolving WordNet's subjects to their
  things, which runs only when there are edges. Called without a page,
  `for_page/3` reads the senses and edges itself.

  No request leaves the application (C8): everything here is a registry read.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{AssertionEvidence, AssertionRevision, AssertionVote}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Examples.Rank
  alias DevilsDictionary.Registry.{ContentRevision, Entity, Lexeme, Sense, SenseRevision}

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Actor, SourceRecord}

  @instance_of "instance_of"
  @refers_to "refers_to"

  # How many of each register show before the rest fold. Twelve is the chip
  # cap every related-words group uses (`WordPage.chip_cap/0`), so the section
  # reads at the density the page already has.
  @cap %{instance: 12, exemplar: 6}

  @tier_rank %{aristocracy: 0, middle: 1, plebs: 2}

  # The verified QID of an entity, for an entity with no label — the same
  # lookup `Encyclopedia.link_views/1` makes.
  defmacrop qid(object_id) do
    quote do
      fragment(
        "(SELECT external_id FROM external_identifiers WHERE object_id = ? AND namespace = 'wikidata' AND status = 'verified' ORDER BY external_id LIMIT 1)",
        unquote(object_id)
      )
    end
  end

  @doc "How many items of each layer the section shows before its disclosure."
  def cap, do: @cap

  @doc """
  The examples for a page's lexemes, ordered, with exact totals beside the cap.

  Returns `%{items: [...], totals: %{instance: n, exemplar: n}, cap: cap(),
  sources: [...]}`, where `sources` is one row per source that named anything —
  the byline's material, composed from `sources` rows so the section names no
  source itself.

  Options, all of which a caller that has already read them passes so nothing
  is read twice:

    * `:senses` — the page's senses, each with `:id` and `:gloss`, in page order
    * `:edges` — `instance_edges/2`'s rows for those senses
    * `:sources` — the `sources` rows, keyed by id
  """
  def for_page(lexeme_ids, viewer \\ :public, opts \\ []) do
    ids = List.wrap(lexeme_ids)
    senses = Keyword.get_lazy(opts, :senses, fn -> senses(ids) end)
    sense_ids = Enum.map(senses, & &1.id)

    edges =
      Keyword.get_lazy(opts, :edges, fn ->
        sense_ids |> instance_edges(viewer) |> Repo.all()
      end)

    sources =
      Keyword.get_lazy(opts, :sources, fn -> Map.new(Sources.list_sources(), &{&1.id, &1}) end)

    glosses = Map.new(senses, &{&1.id, &1.gloss})
    sense_order = senses |> Enum.with_index() |> Map.new(fn {s, i} -> {s.id, i} end)

    # The record is read as the public reads it, whoever is looking: a
    # reviewer's view of a rejected instance is `/connections/:id`, not a chip.
    # Only the exemplars — the layer adjudicated here — read as the viewer.
    items =
      (instances(edges, sense_ids, :public, sources, glosses, sense_order) ++
         exemplars(ids, viewer, senses: senses, sources: sources))
      |> Enum.map(&check!/1)
      |> Rank.order()

    %{
      items: items,
      totals: %{
        instance: Enum.count(items, &(&1.layer == :instance)),
        exemplar: Enum.count(items, &(&1.layer == :exemplar))
      },
      cap: @cap,
      sources: summarise(items)
    }
  end

  @doc """
  The layer-2 read (#181 build 2): the `illustrates` claims whose object is
  one of these lexemes' senses, as items, through `Claims.visible/2` for the
  viewer.

  So the public never sees a person nominated here until a reviewer accepts
  it, and an `:internal` viewer (a contributor or reviewer) sees it marked
  `needs_review`. A claim a reviewer rejected or withdrew is on nobody's page:
  `:internal` hides nothing at the query, and this drops those two states
  after it, because the word page is not the review queue.

  Each item's `claim` carries what the card draws — the rationale, who
  nominated it (the manifest's curator when a manifest wrote it), the
  evidence with its URLs, the display review state — and its `signals` carry
  what `Rank.order/1` reads: votes (`assertion_votes`, split by actor kind,
  which build 3 will cache), the evidence count, and `featured_at`, nil until
  #105's features exist. `nominated_at` breaks ties by age.

  Options: `:senses` (the page's senses, as `for_page/3` has them) and
  `:sources` (the rows by id).
  """
  def exemplars(lexeme_ids, viewer, opts \\ []) do
    senses = Keyword.get_lazy(opts, :senses, fn -> senses(List.wrap(lexeme_ids)) end)
    sources = Keyword.get_lazy(opts, :sources, fn -> source_rows() end)

    case Enum.map(senses, & &1.id) do
      [] ->
        []

      sense_ids ->
        glosses = Map.new(senses, &{&1.id, &1.gloss})

        exemplar_query()
        |> where([r], r.object_object_id in ^sense_ids)
        |> Claims.visible(viewer)
        |> Repo.all()
        |> exemplar_items(sources, glosses)
    end
  end

  @doc """
  The reverse view (#181 wireframe 5, #105): every exemplar whose **subject**
  is this entity, grouped by the word whose sense it illustrates — each group
  `%{lexeme: %{object_id, lemma, slug}, items: [...]}`, its items in
  `Rank.order/1`'s order and the groups in the order of their best item.

  Public by default, like the rest of the entity page: a person's pending
  nominations are not on their page.
  """
  def cited_as(subject_ids, viewer \\ :public) do
    subject_ids = List.wrap(subject_ids)

    rows =
      exemplar_query()
      |> where([r], r.subject_object_id in ^subject_ids)
      |> Claims.visible(viewer)
      |> Repo.all()

    targets = Enum.map(rows, & &1.object_id) |> Enum.uniq()

    words =
      if targets == [] do
        %{}
      else
        Repo.all(
          from s in Sense,
            join: l in Lexeme,
            on: l.object_id == s.lexeme_id,
            left_join: rev in SenseRevision,
            on: rev.sense_id == s.object_id and rev.is_current,
            where: s.object_id in ^targets,
            select:
              {s.object_id,
               %{object_id: l.object_id, lemma: l.lemma, slug: l.slug, gloss: rev.gloss}}
        )
        |> Map.new()
      end

    glosses = Map.new(words, fn {sense_id, word} -> {sense_id, word.gloss} end)

    items = exemplar_items(rows, source_rows(), glosses)
    order = items |> Rank.order() |> Enum.with_index() |> Map.new(fn {i, n} -> {i.id, n} end)

    items
    |> Enum.filter(&Map.has_key?(words, &1.target.object_id))
    |> Enum.group_by(&Map.fetch!(words, &1.target.object_id).object_id)
    |> Enum.map(fn {_lexeme_id, [first | _] = group} ->
      word = Map.fetch!(words, first.target.object_id)

      %{
        lexeme: Map.take(word, [:object_id, :lemma, :slug]),
        items: Enum.sort_by(group, &Map.fetch!(order, &1.id))
      }
    end)
    |> Enum.sort_by(fn group -> Map.fetch!(order, hd(group.items).id) end)
  end

  @doc """
  What the record names this entity under (#181 wireframe 5, the second
  list): the words whose senses its own senses are filed under by WordNet,
  and the things Wikidata files it as an instance of. `[%{label, slug,
  object_id, kind: :lexeme | :entity, source}]`, each named once per source.
  """
  def named_under(entity_ids, viewer \\ :public) do
    entity_ids = List.wrap(entity_ids)
    sources = source_rows()

    # Its words' senses: the senses that `refers_to` it.
    subject_senses =
      from(link in AssertionRevision,
        join: p in assoc(link, :predicate),
        where: p.key == @refers_to and link.object_object_id in ^entity_ids,
        where: link.is_current and link.lifecycle_state == :active,
        select: link.subject_object_id
      )
      |> Claims.visible(viewer)
      |> Repo.all()

    subjects = entity_ids ++ subject_senses

    from(r in AssertionRevision,
      join: p in assoc(r, :predicate),
      join: a in assoc(r, :assertion),
      left_join: ts in Sense,
      on: ts.object_id == r.object_object_id,
      left_join: tl in Lexeme,
      on: tl.object_id == ts.lexeme_id,
      left_join: te in Entity,
      on: te.object_id == r.object_object_id,
      where: p.key == @instance_of and r.subject_object_id in ^subjects,
      where: r.is_current and r.lifecycle_state == :active,
      # Named *by the record* means a source named it: a claim with no source
      # is someone's, not the record's (CodeRabbit on #186).
      where: not is_nil(a.source_id),
      where: not is_nil(tl.object_id) or not is_nil(te.object_id),
      select: %{
        source_id: a.source_id,
        lexeme_id: tl.object_id,
        lemma: tl.lemma,
        slug: tl.slug,
        entity_id: te.object_id,
        entity_label: coalesce(te.preferred_label, qid(te.object_id))
      }
    )
    |> Claims.visible(viewer)
    |> Repo.all()
    |> Enum.map(fn row ->
      source = Map.fetch!(sources, row.source_id)
      source = %{slug: source.slug, name: source.name, tier: source.tier, logo: source.logo}

      if row.lexeme_id do
        %{
          kind: :lexeme,
          object_id: row.lexeme_id,
          label: row.lemma,
          slug: row.slug,
          source: source
        }
      else
        %{
          kind: :entity,
          object_id: row.entity_id,
          label: row.entity_label,
          slug: nil,
          source: source
        }
      end
    end)
    |> Enum.reject(&is_nil(&1.label))
    |> Enum.uniq_by(&{&1.kind, &1.object_id, &1.source.slug})
    |> Enum.sort_by(&{String.downcase(&1.label), &1.source.slug})
  end

  # ── layer 2 ──────────────────────────────────────────────────────────────

  @illustrates "illustrates"

  # One row per current, active `illustrates` revision, with the subject's
  # name and who nominated it. The caller adds the endpoint filter and the
  # viewer's visibility.
  defp exemplar_query do
    from r in AssertionRevision,
      join: p in assoc(r, :predicate),
      join: a in assoc(r, :assertion),
      left_join: e in Entity,
      on: e.object_id == r.subject_object_id,
      left_join: c in ContentRevision,
      on: c.content_id == r.subject_object_id and c.is_current,
      left_join: nominator in Actor,
      on: nominator.id == a.origin_actor_id,
      where: p.key == @illustrates and r.is_current and r.lifecycle_state == :active,
      select: %{
        assertion_id: a.id,
        revision_id: r.id,
        source_id: a.source_id,
        subject_object_id: r.subject_object_id,
        subject_kind: r.subject_kind,
        entity_kind: e.entity_kind,
        label: coalesce(e.preferred_label, c.headword),
        qid: qid(r.subject_object_id),
        object_id: r.object_object_id,
        object_kind: r.object_kind,
        rationale: r.rationale,
        method: r.method,
        metadata: r.metadata,
        nominated_at: r.inserted_at,
        nominator_id: nominator.id,
        nominator_label: nominator.label,
        nominator_kind: nominator.actor_kind
      }
  end

  defp exemplar_items([], _sources, _glosses), do: []

  defp exemplar_items(rows, sources, glosses) do
    revision_ids = Enum.map(rows, & &1.revision_id)
    states = Claims.display_review_states(revision_ids)
    evidence = evidence_for(revision_ids)
    votes = votes_for(revision_ids)

    rows
    |> Enum.reject(&(Map.fetch!(states, &1.revision_id) in Claims.hidden_decisions()))
    |> Enum.map(fn row ->
      state = Map.fetch!(states, row.revision_id)
      cited = Map.get(evidence, row.revision_id, [])
      tally = Map.get(votes, row.revision_id, %{})
      source = Map.get(sources, row.source_id)
      metadata = row.metadata || %{}
      gloss = glosses[row.object_id]
      nominated_by = nominator(row, metadata)

      %{
        id: "ex:#{row.assertion_id}",
        layer: :exemplar,
        basis: :cited,
        subject: %{
          kind: if(row.subject_kind == "content", do: :content, else: :entity),
          object_id: row.subject_object_id,
          label: row.label || row.qid || "##{row.subject_object_id}",
          slug: nil,
          entity_id: row.entity_kind && row.subject_object_id,
          entity_kind: row.entity_kind,
          qid: row.qid,
          aliases: [],
          enriched?: false,
          thumbnail: nil
        },
        target: %{
          kind: if(row.object_kind == "sense", do: :sense, else: :entity),
          object_id: row.object_id,
          gloss: gloss,
          label: nil
        },
        sources:
          if(source,
            do: [
              %{
                slug: source.slug,
                name: source.name,
                tier: source.tier,
                logo: Map.get(source, :logo),
                kind: :claim,
                classes: nil,
                assertion_ids: [row.assertion_id]
              }
            ],
            else: []
          ),
        claim: %{
          assertion_id: row.assertion_id,
          revision_id: row.revision_id,
          method: row.method,
          rationale: row.rationale,
          nominated_by: nominated_by,
          evidence: cited,
          evidence_count: length(cited),
          review_state: state,
          manifest:
            if(metadata["manifest"],
              do: %{slug: metadata["manifest"], row: metadata["row"]}
            )
        },
        signals: %{
          source_count: 0,
          best_tier: nil,
          human_up: Map.get(tally, :human_up, 0),
          human_down: Map.get(tally, :human_down, 0),
          bot_up: Map.get(tally, :bot_up, 0),
          bot_down: Map.get(tally, :bot_down, 0),
          evidence_count: Enum.count(cited, &(&1.role == :supports)),
          featured_at: nil,
          nominated_at: row.nominated_at
        },
        reason: exemplar_reason(nominated_by, gloss)
      }
    end)
  end

  # The card says who, in the words the nomination carried: a manifest names
  # its curator; a form nomination is the account's own label.
  defp nominator(row, metadata) do
    %{
      actor_id: row.nominator_id,
      label: metadata["curator"] || row.nominator_label,
      kind: row.nominator_kind
    }
  end

  defp exemplar_reason(%{label: label}, gloss) when is_binary(gloss),
    do: "Cited by #{label || "a contributor"} as an example of “#{gloss}”."

  defp exemplar_reason(%{label: label}, _gloss),
    do: "Cited by #{label || "a contributor"} as an example of this meaning."

  # Every evidence row, with the URL a `community` record holds and the
  # canonical URL a content revision has.
  defp evidence_for(revision_ids) do
    Repo.all(
      from ev in AssertionEvidence,
        left_join: srr in SourceRecordRevision,
        on: srr.id == ev.source_record_revision_id,
        left_join: sr in SourceRecord,
        on: sr.id == srr.source_record_id,
        left_join: cr in ContentRevision,
        on: cr.id == ev.content_revision_id,
        where: ev.assertion_revision_id in ^revision_ids,
        order_by: [ev.assertion_revision_id, ev.evidence_role, ev.id],
        select:
          {ev.assertion_revision_id,
           %{
             role: ev.evidence_role,
             url: coalesce(sr.url, cr.canonical_url),
             attribution: ev.attribution_text,
             locator: ev.locator
           }}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    # What supports a claim reads first; what contradicts it follows, shown
    # and never dropped. (The role sorts as text in SQL, which put
    # `contradicts` first.)
    |> Map.new(fn {id, rows} -> {id, Enum.sort_by(rows, &(&1.role != :supports))} end)
  end

  # Human and bot votes apart, never summed together (#105, #97).
  defp votes_for(revision_ids) do
    Repo.all(
      from v in AssertionVote,
        join: actor in Actor,
        on: actor.id == v.actor_id,
        where: v.assertion_revision_id in ^revision_ids,
        group_by: [v.assertion_revision_id, actor.actor_kind, v.value],
        select: {v.assertion_revision_id, actor.actor_kind, v.value, count(v.id)}
    )
    |> Enum.reduce(%{}, fn {revision_id, kind, value, n}, acc ->
      case tally_key(kind, value) do
        nil ->
          acc

        key ->
          Map.update(acc, revision_id, %{key => n}, &Map.update(&1, key, n, fn m -> m + n end))
      end
    end)
  end

  # Only a `user` actor is a person agreeing (#181 C6); an import or an
  # unknown claimant's vote counts as neither.
  defp tally_key(:user, value) when value > 0, do: :human_up
  defp tally_key(:user, _value), do: :human_down
  defp tally_key(:bot, value) when value > 0, do: :bot_up
  defp tally_key(:bot, _value), do: :bot_down
  defp tally_key(_kind, _value), do: nil

  defp source_rows, do: Map.new(Sources.list_sources(), &{&1.id, &1})

  @doc """
  WordNet's side of the instance layer, as a query: the current `instance_of`
  claims whose **object** is one of these senses — the named things filed under
  them.

  The one object-side read the word page makes, and the reason it is a query
  rather than a list: `WordPage.relations/2` `union_all`s it into the
  relations statement it already runs, so the edge costs the page no second
  round trip. The select is the relation row `WordPage` reads for every other
  edge, with the far end — the *subject* here — in `lemma`, `slug`, `pos` and
  `to_group_key`, plus `direction: "object"` so the two halves can be told
  apart after the union.
  """
  def instance_edges(sense_ids, viewer \\ :public) do
    from(r in AssertionRevision,
      join: p in assoc(r, :predicate),
      join: a in assoc(r, :assertion),
      join: fs in Sense,
      on: fs.object_id == r.subject_object_id,
      left_join: frev in SenseRevision,
      on: frev.sense_id == fs.object_id and frev.is_current,
      join: l in Lexeme,
      on: l.object_id == fs.lexeme_id,
      where: p.key == @instance_of and r.object_object_id in ^sense_ids,
      where: r.is_current and r.lifecycle_state == :active,
      select: %{
        direction: fragment("'object'"),
        type: p.key,
        source_id: a.source_id,
        assertion_id: a.id,
        subject_id: r.subject_object_id,
        target_id: r.object_object_id,
        from_lexeme_id: fs.lexeme_id,
        from_sense_id: fs.object_id,
        to_group_key: frev.group_key,
        weight: coalesce(r.confidence, 0.0),
        lemma: l.lemma,
        slug: l.slug,
        pos: l.part_of_speech,
        enriched?: not is_nil(l.enriched_at)
      }
    )
    |> Claims.visible(viewer)
  end

  # ── layer 1 ──────────────────────────────────────────────────────────────

  defp instances(edges, sense_ids, viewer, sources, glosses, sense_order) do
    things = subject_things(edges, viewer)

    wordnet =
      edges
      |> Enum.group_by(&(&1.to_group_key || "sense-#{&1.subject_id}"))
      |> Enum.map(fn {synset, rows} ->
        entities =
          rows |> Enum.flat_map(&Map.get(things, &1.subject_id, [])) |> Enum.uniq_by(& &1.id)

        family =
          case entities do
            [entity] -> {:entity, entity.id}
            _none_or_many -> {:synset, synset}
          end

        {family, %{edges: rows, entity: match?([_], entities) && hd(entities)}}
      end)

    wikidata =
      sense_ids
      |> class_instances(viewer)
      |> Enum.group_by(& &1.entity_id)
      |> Enum.map(fn {entity_id, rows} -> {{:entity, entity_id}, %{p31: rows}} end)

    (wordnet ++ wikidata)
    |> Enum.reduce(%{}, fn {family, part}, acc ->
      Map.update(acc, family, part, &Map.merge(&1, part, fn _k, a, b -> merge_part(a, b) end))
    end)
    |> Enum.map(fn {family, parts} -> instance(family, parts, sources, glosses, sense_order) end)
  end

  # Two synsets can resolve to one thing; their edges pool.
  defp merge_part(a, b) when is_list(a) and is_list(b), do: a ++ b
  defp merge_part(a, _b), do: a

  defp instance(family, parts, sources, glosses, sense_order) do
    edges = Map.get(parts, :edges, [])
    p31 = Map.get(parts, :p31, [])
    entity = Map.get(parts, :entity) || entity_of(p31)

    subject = subject(edges, p31, entity)

    targets =
      Enum.sort_by(edges, &{Map.get(sense_order, &1.target_id, 0), &1.target_id})

    target =
      case targets do
        [edge | _] ->
          %{kind: :sense, object_id: edge.target_id, gloss: glosses[edge.target_id], label: nil}

        [] ->
          row = hd(p31)
          %{kind: :entity, object_id: row.class_id, gloss: nil, label: row.class_label}
      end

    by_source =
      Enum.map(edges, &{&1.source_id, :sense, &1.assertion_id}) ++
        Enum.map(p31, &{&1.source_id, :entity, &1.assertion_id})

    item_sources =
      by_source
      |> Enum.group_by(fn {source_id, kind, _} -> {source_id, kind} end, &elem(&1, 2))
      |> Enum.map(fn {{source_id, kind}, assertion_ids} ->
        source = Map.fetch!(sources, source_id)

        %{
          slug: source.slug,
          name: source.name,
          tier: source.tier,
          logo: Map.get(source, :logo),
          kind: kind,
          classes: if(kind == :entity, do: p31 |> Enum.map(& &1.class_label) |> Enum.uniq()),
          assertion_ids: assertion_ids |> Enum.uniq() |> Enum.sort()
        }
      end)
      |> Enum.sort_by(&{Map.get(@tier_rank, &1.tier, 3), &1.slug, &1.kind})

    %{
      id: "inst:" <> family_id(family),
      layer: :instance,
      basis: :record,
      subject: subject,
      target: target,
      sources: item_sources,
      claim: nil,
      signals: %{
        source_count: item_sources |> Enum.uniq_by(& &1.slug) |> length(),
        best_tier:
          item_sources |> Enum.map(& &1.tier) |> Enum.min_by(&Map.get(@tier_rank, &1, 3)),
        human_up: 0,
        human_down: 0,
        bot_up: 0,
        bot_down: 0,
        evidence_count: 0,
        featured_at: nil
      },
      reason: reason(item_sources, target)
    }
  end

  defp family_id({:entity, id}), do: "e#{id}"
  defp family_id({:synset, key}), do: "s" <> String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")

  defp entity_of([]), do: nil
  defp entity_of([row | _]), do: %{id: row.entity_id, label: row.label, kind: row.entity_kind}

  # The chip names the thing and hops to a word when the thing has one. A
  # WordNet synset's members are all words; a Wikidata thing has one when a
  # sense `refers_to` it, and otherwise the chip goes to its entity page.
  defp subject([], [row | _], entity) do
    case row.slug do
      nil ->
        %{
          kind: :entity,
          object_id: entity.id,
          label: entity.label,
          slug: nil,
          entity_id: entity.id,
          entity_kind: entity.kind,
          aliases: [],
          enriched?: false,
          thumbnail: nil
        }

      slug ->
        %{
          kind: :lexeme,
          object_id: row.lexeme_id,
          label: row.lemma,
          slug: slug,
          entity_id: entity.id,
          entity_kind: entity.kind,
          aliases: [],
          enriched?: row.enriched?,
          thumbnail: nil
        }
    end
  end

  defp subject(edges, _p31, entity) do
    members = edges |> Enum.uniq_by(& &1.from_lexeme_id) |> Enum.sort_by(&member_rank/1)
    lead = named_by(members, entity) || hd(members)

    %{
      kind: :lexeme,
      object_id: lead.from_lexeme_id,
      label: lead.lemma,
      slug: lead.slug,
      entity_id: entity && entity.id,
      entity_kind: entity && entity.kind,
      aliases: members |> Enum.map(& &1.lemma) |> Enum.reject(&(&1 == lead.lemma)) |> Enum.uniq(),
      enriched?: lead.enriched?,
      thumbnail: nil
    }
  end

  # The member whose spelling is the thing's own name, when the thing has one.
  defp named_by(_members, nil), do: nil

  defp named_by(members, entity) do
    label = String.downcase(entity.label || "")
    Enum.find(members, &(String.downcase(&1.lemma) == label))
  end

  # The fullest name leads: *Adolf Hitler* over *Hitler* and *Der Fuhrer*,
  # *Francisco Franco* over *El Caudillo*, *Yom Kippur War* over the
  # *Arab-Israeli War* WordNet also uses for 1967. Words, then length, then
  # the lemma, so the choice is stable.
  defp member_rank(edge) do
    words = edge.lemma |> String.split(~r/\s+/, trim: true) |> length()
    {-words, -String.length(edge.lemma), edge.lemma}
  end

  # One sentence, from fields, full stop: who named it, and under what.
  defp reason(sources, target) do
    sources
    |> Enum.map(fn
      %{kind: :sense, name: name} when is_binary(target.gloss) ->
        "#{name} names it under “#{target.gloss}”"

      %{kind: :sense, name: name} ->
        "#{name} names it under a sense of this word"

      %{kind: :entity, name: name, classes: classes} ->
        "#{name} files it as an instance of #{Enum.join(classes, ", ")}"
    end)
    |> Enum.join("; ")
    |> Kernel.<>(".")
  end

  # ── the reads ────────────────────────────────────────────────────────────

  defp senses(lexeme_ids) do
    Repo.all(
      from s in Sense,
        left_join: rev in SenseRevision,
        on: rev.sense_id == s.object_id and rev.is_current,
        where: s.lexeme_id in ^lexeme_ids and s.identity_state == :active,
        order_by: [s.lexeme_id, rev.position, s.object_id],
        select: %{id: s.object_id, gloss: rev.gloss}
    )
  end

  # Each WordNet subject sense → the things it `refers_to`.
  defp subject_things([], _viewer), do: %{}

  defp subject_things(edges, viewer) do
    subjects = edges |> Enum.map(& &1.subject_id) |> Enum.uniq()

    from(r in AssertionRevision,
      join: p in assoc(r, :predicate),
      join: e in Entity,
      on: e.object_id == r.object_object_id,
      where: p.key == @refers_to and r.subject_object_id in ^subjects,
      where: r.is_current and r.lifecycle_state == :active,
      select:
        {r.subject_object_id, %{id: e.object_id, label: e.preferred_label, kind: e.entity_kind}}
    )
    |> Claims.visible(viewer)
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Wikidata's side: the things filed as instances (P31) of the things this
  # page's senses `refers_to` — sense-backed, never a word-level candidate,
  # because a title match "never propagates examples" (`Encyclopedia`). Each
  # with its word when a sense refers to it, chosen as the thing panel always
  # chose it: the most confident link, then the lowest lexeme id.
  defp class_instances([], _viewer), do: []

  defp class_instances(sense_ids, viewer) do
    # Two statements, not one. As a semi-join (`object_object_id IN
    # (subquery)`) the planner walked every current `instance_of` row before
    # filtering — 170–200 ms on *war* in `devils_dictionary_v2` — where the
    # things a page refers to are a handful of ids and the rows under them an
    # index lookup: 1–3 ms as two.
    sense_ids
    |> referred_things(viewer)
    |> instances_of(viewer)
  end

  defp referred_things(sense_ids, viewer) do
    from(link in AssertionRevision,
      join: p in assoc(link, :predicate),
      where: p.key == @refers_to and link.subject_object_id in ^sense_ids,
      where: link.is_current and link.lifecycle_state == :active,
      distinct: true,
      select: link.object_object_id
    )
    |> Claims.visible(viewer)
    |> Repo.all()
  end

  defp instances_of([], _viewer), do: []

  defp instances_of(classes, viewer) do
    word =
      from(link in AssertionRevision,
        join: p in assoc(link, :predicate),
        join: s in Sense,
        on: s.object_id == link.subject_object_id,
        join: lx in Lexeme,
        on: lx.object_id == s.lexeme_id,
        where: link.object_object_id == parent_as(:instance).subject_object_id,
        where: p.key == @refers_to and link.is_current and link.lifecycle_state == :active,
        order_by: [desc_nulls_last: link.confidence, asc: lx.object_id],
        limit: 1,
        select: %{
          lexeme_id: lx.object_id,
          lemma: lx.lemma,
          slug: lx.slug,
          enriched: not is_nil(lx.enriched_at)
        }
      )

    from(r in AssertionRevision,
      as: :instance,
      join: p in assoc(r, :predicate),
      join: a in assoc(r, :assertion),
      join: e in Entity,
      on: e.object_id == r.subject_object_id,
      join: c in Entity,
      on: c.object_id == r.object_object_id,
      left_lateral_join: w in subquery(word),
      on: true,
      where: p.key == @instance_of and r.object_object_id in ^classes,
      where: r.is_current and r.lifecycle_state == :active,
      # A thing with no English label still has its QID, and a chip has to
      # say something: `preferred_label` is nullable, and a nil label would
      # reach the ordering and the entity link. One with neither is left out.
      where: not is_nil(coalesce(e.preferred_label, qid(e.object_id))),
      select: %{
        source_id: a.source_id,
        assertion_id: a.id,
        entity_id: e.object_id,
        label: coalesce(e.preferred_label, qid(e.object_id)),
        entity_kind: e.entity_kind,
        class_id: c.object_id,
        class_label: coalesce(c.preferred_label, qid(c.object_id)),
        lexeme_id: w.lexeme_id,
        lemma: w.lemma,
        slug: w.slug,
        enriched?: coalesce(w.enriched, false)
      }
    )
    |> Claims.visible(viewer)
    |> Repo.all()
  end

  # ── the byline's material ────────────────────────────────────────────────

  # One row per source and way of naming, counted over items: *WordNet, 29
  # things under a sense*, *Wikidata, 16 instances of War, 1 of them a word*.
  defp summarise(items) do
    items
    |> Enum.filter(&(&1.layer == :instance))
    |> Enum.flat_map(fn item -> Enum.map(item.sources, &{&1, item}) end)
    |> Enum.group_by(fn {source, _item} -> {source.slug, source.kind} end)
    |> Enum.map(fn {_key, [{source, _} | _] = pairs} ->
      named = Enum.map(pairs, &elem(&1, 1))

      %{
        slug: source.slug,
        name: source.name,
        tier: source.tier,
        logo: source.logo,
        kind: source.kind,
        classes: pairs |> Enum.flat_map(&(elem(&1, 0).classes || [])) |> Enum.uniq(),
        count: length(named),
        words: Enum.count(named, &(&1.subject.kind == :lexeme))
      }
    end)
    |> Enum.sort_by(&{Map.get(@tier_rank, &1.tier, 3), &1.slug, &1.kind})
  end

  # ── conformance (C2) ─────────────────────────────────────────────────────

  @doc """
  Whether an item is an example of its own layer and nothing else.

  An instance never carries a claim or a rationale, and names at least one
  source; an exemplar never renders without a rationale. An item without a
  `layer` is neither. `for_page/3` runs every item through this, so a
  malformed one fails where it was made rather than on the page.
  """
  def check(%{layer: :instance, claim: nil, sources: [_ | _], reason: reason})
      when is_binary(reason),
      do: :ok

  def check(%{layer: :instance}), do: {:error, :instance_with_claim_or_without_source}

  def check(%{layer: :exemplar, claim: %{rationale: rationale}})
      when is_binary(rationale) and rationale != "",
      do: :ok

  def check(%{layer: :exemplar}), do: {:error, :exemplar_without_rationale}
  def check(_item), do: {:error, :no_layer}

  defp check!(item) do
    case check(item) do
      :ok -> item
      {:error, why} -> raise ArgumentError, "not an example (#{why}): #{inspect(item[:id])}"
    end
  end
end
