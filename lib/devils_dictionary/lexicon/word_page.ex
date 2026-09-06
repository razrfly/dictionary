defmodule DevilsDictionary.Lexicon.WordPage do
  @moduledoc """
  Everything `/define/:slug` renders, assembled in one round of queries.

  Issue #71 §7 and §8a.4: the templates do no logic. `build/2` takes what
  `Lexicon.lookup/2` resolved and returns a `%WordPage{}` whose every field is
  already ordered, grouped, capped and rendered — markdown included. A template
  that has to decide something is a template that will decide it differently
  next time.

  ## The placement rule

  The one idea worth understanding here. A relation that carries
  `from_sense_id` belongs to **that sense** and renders inside its source card;
  a relation without one belongs to the **part of speech** and renders in the
  page-level *Related words* block. This is the S0 audit's per-sense rule made
  physical: WordNet hangs its edges off senses, so *cat*'s tracked-vehicle
  sense keeps *tracked vehicle* to itself instead of the animal listing it
  among its broader words. Wiktionary is mixed — its antonyms and most synonyms
  are sense-scoped, its derived and coordinate edges are not.

  ## Seven queries

  Sources; senses; entries (by lexeme **or** by the primary concept, which is
  how Wikipedia's summary arrives); the primary concept; relations; the WordNet
  chain; the trail's lemmas. All of them keyed by the lexeme ids `lookup/2`
  returned, none of them in a loop.

  The chain is the one that had to be built rather than borrowed, and its shape
  matters: walking lexeme to lexeme gives *oyster › bivalve › allocation ›
  abstract entity*, because a lemma reached through one synset carries every
  other synset it belongs to. The walk is sense → synset instead —
  `senses.group_key` to `lexical_relations.to_group_key` over `hypernym`,
  re-entering through any sense of the parent synset — and it takes exactly one
  parent per step (`CROSS JOIN LATERAL … LIMIT 1`), so one synset yields one
  linear chain rather than the fan-out a plain recursive CTE produces.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Lexicon.{Entry, LexicalRelation, Lexeme, Sense}
  alias DevilsDictionary.Markdown
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  defstruct headword: nil, cards: [], related: [], trail: []

  @chip_cap 12
  @gloss_cap 3
  @chain_depth 8
  @trail_cap 12

  # #71 §7's map, as data. Every `lexical_relations.type` lands in exactly one
  # group; `see_also` splits by source because "Johnson says see" and "Bierce
  # says see" are different claims, and WordNet's fold into `related`.
  @groups %{
    synonym: :similar,
    coordinate: :similar,
    antonym: :opposite,
    hypernym: :broader,
    hyponym: :narrower,
    meronym: :parts,
    holonym: :part_of,
    derived: :family,
    related: :family,
    alt_of: :variants,
    form_of: :variants,
    see_also: :says_see,
    other: :related
  }

  # The order §9 grades: "every group in §7's map that the word has, in that
  # order".
  @group_order [
    :similar,
    :opposite,
    :broader,
    :narrower,
    :parts,
    :part_of,
    :family,
    :variants,
    :says_see,
    :related
  ]

  @group_labels %{
    similar: "similar",
    opposite: "opposite",
    broader: "broader",
    narrower: "narrower",
    parts: "parts",
    part_of: "part of",
    family: "family",
    variants: "variants",
    says_see: "says see",
    related: "related"
  }

  @tier_rank %{aristocracy: 0, middle: 1, plebs: 2}
  @pos_rank ~w(noun verb adj adjective adv adverb)

  @doc "The group keys in render order."
  def group_order, do: @group_order

  @doc "The human label for a group key."
  def group_label(group), do: Map.fetch!(@group_labels, group)

  @doc "How many chips a group shows before its “+N”."
  def chip_cap, do: @chip_cap

  @doc "How many glosses a sense card shows before “show N more”."
  def gloss_cap, do: @gloss_cap

  @doc """
  Builds the page from a `Lexicon.lookup/2` result.

  `opts[:trail]` is a list of slugs already walked. A lookup that found nothing
  still returns a struct — `/define/zzzz` is a page that says *no such word*,
  never a raise, because X1 renders 200 random index rows and the index is
  mostly bare.
  """
  def build(lookup, opts \\ [])

  def build(%{lexemes: []} = lookup, opts) do
    %__MODULE__{
      headword: %{
        lemma: lookup[:matched],
        slug: nil,
        lexemes: [],
        via: :none,
        matched: lookup[:matched],
        also: []
      },
      trail: trail(opts[:trail])
    }
  end

  def build(%{lexemes: lexemes} = lookup, opts) do
    ids = Enum.map(lexemes, & &1.id)
    sources = Map.new(Sources.list_sources(), &{&1.id, &1})
    concept = primary_concept(lexemes)

    senses = senses(ids)
    entries = entries(ids, concept)
    relations = relations(ids)
    chains = chains(senses, sources)

    by_lexeme = Map.new(lexemes, &{&1.id, &1})
    {sense_scoped, pos_scoped} = Enum.split_with(relations, &(&1.from_sense_id != nil))

    %__MODULE__{
      headword: headword(lexemes, lookup, sources),
      cards: cards(senses, entries, sense_scoped, chains, sources, concept, by_lexeme),
      related: related(pos_scoped, by_lexeme, sources),
      trail: trail(opts[:trail])
    }
  end

  # ── headword ─────────────────────────────────────────────────────────────

  defp headword([first | _] = lexemes, lookup, sources) do
    %{
      lemma: first.lemma,
      slug: first.slug,
      via: lookup[:via],
      matched: lookup[:matched],
      also: Enum.map(lookup[:also] || [], &%{lemma: &1.lemma, slug: &1.slug, pos: &1.pos}),
      forms: forms(lexemes),
      pronunciations: pronunciations(lexemes),
      etymologies: etymologies(lexemes, sources),
      lexemes:
        lexemes
        |> Enum.sort_by(&pos_rank(&1.pos))
        |> Enum.map(fn l ->
          %{
            id: l.id,
            pos: l.pos,
            etymology: l.etymology,
            etymology_source: source_name(sources, l.etymology_source_id),
            enriched?: not is_nil(l.enriched_at),
            canonical: l.canonical_lexeme_id
          }
        end)
    }
  end

  # Forms are the union across every part of speech — the reader wants the
  # word's inflections, not a column per pos — deduplicated and stripped of the
  # lemma itself.
  defp forms(lexemes) do
    lexemes
    |> Enum.flat_map(& &1.forms)
    |> Enum.map(&(&1["form"] || &1[:form]))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reject(fn form -> Enum.any?(lexemes, &(&1.lemma == form)) end)
    |> Enum.uniq()
  end

  # *cat* carries fourteen pronunciation rows and two distinct IPA strings: the
  # rest are audio recordings of the same two. Keep the ones that actually say
  # how the word sounds, one per spelling, three at most.
  defp pronunciations(lexemes) do
    lexemes
    |> Enum.flat_map(& &1.pronunciations)
    |> Enum.map(&{&1["ipa"], &1["tags"]})
    |> Enum.reject(fn {ipa, _tags} -> is_nil(ipa) or ipa == "" end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(3)
    |> Enum.map(fn {ipa, tags} -> %{ipa: ipa, tags: tags || []} end)
  end

  # Wiktionary files an etymology per part of speech, and for *oyster* it is the
  # same paragraph three times. One paragraph, with the parts of speech it
  # covers named beside it.
  defp etymologies(lexemes, sources) do
    lexemes
    |> Enum.reject(&(is_nil(&1.etymology) or &1.etymology == ""))
    |> Enum.group_by(& &1.etymology)
    |> Enum.map(fn {text, group} ->
      %{
        text: text,
        source: source_name(sources, hd(group).etymology_source_id),
        parts: group |> Enum.map(& &1.pos) |> Enum.sort_by(&pos_rank/1)
      }
    end)
    |> Enum.sort_by(&pos_rank(hd(&1.parts)))
  end

  defp source_name(_sources, nil), do: nil
  defp source_name(sources, id), do: sources[id] && sources[id].name

  # ── cards ────────────────────────────────────────────────────────────────

  defp senses(ids) do
    Repo.all(
      from s in Sense,
        left_join: rec in SourceRecord,
        on: rec.id == s.source_record_id,
        where: s.lexeme_id in ^ids,
        order_by: [asc: s.position, asc: s.id],
        select: %{
          id: s.id,
          lexeme_id: s.lexeme_id,
          source_id: s.source_id,
          group_key: s.group_key,
          gloss: s.gloss,
          url: s.url,
          tags: s.tags,
          position: s.position,
          external_id: s.external_id,
          record_id: rec.id,
          record_url: rec.url
        }
    )
  end

  # One query for both kinds of entry: the 👑 authors hang theirs off a lexeme,
  # Wikipedia hangs its summary off a concept. The schema's check constraint
  # makes that an exclusive or, so the two can never collide.
  defp entries(ids, concept) do
    # The concept half is added as a clause rather than parameterised with a
    # nil: Postgres cannot infer the type of a bare `$n IS NULL` and refuses the
    # statement outright.
    scope =
      case concept do
        nil -> dynamic([e], e.lexeme_id in ^ids)
        %{id: id} -> dynamic([e], e.lexeme_id in ^ids or e.concept_id == ^id)
      end

    Repo.all(
      from e in Entry,
        left_join: rec in SourceRecord,
        on: rec.id == e.source_record_id,
        where: ^scope,
        order_by: [asc: e.position, asc: e.id],
        select: %{
          id: e.id,
          lexeme_id: e.lexeme_id,
          concept_id: e.concept_id,
          source_id: e.source_id,
          headword: e.headword,
          pos: e.pos,
          body: e.body,
          body_format: e.body_format,
          url: e.url,
          thumbnail_url: e.thumbnail_url,
          year: e.year,
          record_id: rec.id,
          record_url: rec.url
        }
    )
  end

  # The thing the word names is U1b's card. Here it exists only to reach
  # Wikipedia's summary, so one lookup off the nominal lexeme is enough.
  defp primary_concept(lexemes) do
    lexeme = Enum.find(lexemes, &(&1.pos == "noun")) || hd(lexemes)
    Encyclopedia.primary_concept(lexeme.id)
  end

  defp cards(senses, entries, sense_scoped, chains, sources, concept, by_lexeme) do
    relations_by_sense = Enum.group_by(sense_scoped, & &1.from_sense_id)

    entry_cards =
      entries
      |> Enum.group_by(&{&1.source_id, pos_of(by_lexeme, &1.lexeme_id)})
      |> Enum.map(fn {{source_id, pos}, rows} ->
        source = sources[source_id]

        %{
          source: source,
          tier: source.tier,
          year: source.era_year,
          pos: pos,
          kind: :entry,
          entries:
            Enum.map(rows, fn e ->
              %{
                headword: e.headword,
                marker: e.pos,
                body_html: Markdown.to_html(e.body, e.body_format),
                year: e.year,
                url: link_out(e, source, nil, concept),
                record_id: e.record_id
              }
            end),
          groups: [],
          thumbnail_url: Enum.find_value(rows, & &1.thumbnail_url),
          url: rows |> hd() |> link_out(source, nil, concept)
        }
      end)

    sense_cards =
      senses
      |> Enum.group_by(&{&1.source_id, pos_of(by_lexeme, &1.lexeme_id)})
      |> Enum.map(fn {{source_id, pos}, rows} ->
        source = sources[source_id]
        lemma = lemma_of(by_lexeme, rows)

        %{
          source: source,
          tier: source.tier,
          year: source.era_year,
          pos: pos,
          kind: :senses,
          entries: [],
          groups: sense_groups(rows, source, lemma, relations_by_sense, chains, sources),
          thumbnail_url: nil,
          url: rows |> hd() |> link_out(source, lemma, concept)
        }
      end)

    (entry_cards ++ sense_cards)
    |> Enum.sort_by(&{@tier_rank[&1.tier], &1.year || 0, pos_rank(&1.pos), &1.source.slug})
    |> with_ids()
  end

  # A source that contributes one card is named by its slug alone
  # (`#card-bierce`); a source that contributes several needs the part of
  # speech to tell them apart (`#card-wiktionary-noun`). Cards are keyed by
  # source and part of speech, never by lexeme, which is what keeps the id
  # unique: `/define/cat` resolves *cat*, *Cat* and *CAT* — three nominal
  # lexemes — and keying by lexeme gave two cards both calling themselves
  # `#card-wordnet-noun`.
  defp with_ids(cards) do
    counts = Enum.frequencies_by(cards, & &1.source.slug)

    Enum.map(cards, fn card ->
      id =
        case counts[card.source.slug] do
          1 -> "card-#{card.source.slug}"
          _ -> "card-#{card.source.slug}-#{card.pos || "x"}"
        end

      Map.put(card, :id, id)
    end)
  end

  # Grouping by `group_key` does both jobs at once: WordNet's synsets become one
  # block each, and Wiktionary — which has no group key — falls into a single
  # nil group holding its numbered list.
  defp sense_groups(rows, source, lemma, relations_by_sense, chains, sources) do
    rows
    |> Enum.group_by(& &1.group_key)
    |> Enum.sort_by(fn {_key, senses} -> senses |> hd() |> Map.get(:position) end)
    |> Enum.map(fn {group_key, senses} ->
      chain = Map.get(chains, group_key, [])

      relations =
        senses
        |> Enum.flat_map(&Map.get(relations_by_sense, &1.id, []))
        |> group_chips(sources)
        # The chain is the broader relation, walked all the way up: its first
        # step is exactly what the :broader chips would say. Showing both puts
        # *bivalve* on the page twice, once as a chain and once as a chip.
        |> then(&if(chain == [], do: &1, else: Map.delete(&1, :broader)))

      %{
        group_key: group_key,
        gloss: group_key && senses |> hd() |> Map.get(:gloss),
        chain: chain,
        relations: relations,
        senses:
          Enum.map(senses, fn s ->
            %{
              id: s.id,
              gloss: s.gloss,
              tags: s.tags,
              url: link_out(s, source, lemma, nil),
              record_id: s.record_id
            }
          end)
      }
    end)
  end

  # Wikipedia's entry hangs off a concept and has no part of speech at all; the
  # 👑 authors' `entries.pos` is the *printed* grammar marker ("n", "n. s."),
  # never our own vocabulary. Both answers come from the lexeme or not at all.
  defp pos_of(_by_lexeme, nil), do: nil
  defp pos_of(by_lexeme, lexeme_id), do: by_lexeme[lexeme_id] && by_lexeme[lexeme_id].pos

  # The lemma a card's `url_template` gets filled with. Where several
  # capitalisations share a part of speech the enriched one wins, then the
  # lowercase one — `en.wiktionary.org/wiki/cat`, not `/wiki/CAT`.
  defp lemma_of(by_lexeme, rows) do
    rows
    |> Enum.map(&by_lexeme[&1.lexeme_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{is_nil(&1.enriched_at), &1.lemma})
    |> List.first()
    |> then(&(&1 && &1.lemma))
  end

  # ── links out ────────────────────────────────────────────────────────────

  @doc """
  Where a card's ↗ points — **U6**, and the same three answers A9 accepts, in
  the same order: the row's own url, the url of the record it was materialized
  from, then the source's `url_template`. Every sense and entry in the database
  today carries its own url, so the fallbacks are a safety net rather than the
  common path — but a card with no answer at all is a bug, not a missing icon.
  """
  def link_out(row, source, lemma \\ nil, concept \\ nil)

  def link_out(%{url: url}, _source, _lemma, _concept) when is_binary(url) and url != "", do: url

  def link_out(%{record_url: url}, _source, _lemma, _concept) when is_binary(url) and url != "",
    do: url

  def link_out(row, source, lemma, concept), do: fill_template(source, row, lemma, concept)

  defp fill_template(%{url_template: nil} = source, _row, _lemma, _concept), do: source.homepage

  defp fill_template(source, row, lemma, concept) do
    source.url_template
    |> String.replace("{external_id}", to_string(row[:external_id] || ""))
    |> String.replace("{lemma}", to_string(lemma || ""))
    |> String.replace("{title}", to_string((concept && concept.wikipedia_title) || lemma || ""))
  end

  # ── relations ────────────────────────────────────────────────────────────

  # Only resolved targets: a chip that points nowhere is a dead end, and #71 §2
  # says every chip lands on a page.
  defp relations(ids) do
    Repo.all(
      from r in LexicalRelation,
        join: t in Lexeme,
        on: t.id == r.to_lexeme_id,
        where: r.from_lexeme_id in ^ids and not is_nil(r.to_lexeme_id),
        select: %{
          type: r.type,
          source_id: r.source_id,
          from_lexeme_id: r.from_lexeme_id,
          from_sense_id: r.from_sense_id,
          to_group_key: r.to_group_key,
          weight: r.weight,
          lemma: t.lemma,
          slug: t.slug,
          pos: t.pos,
          enriched?: not is_nil(t.enriched_at)
        }
    )
  end

  defp related(pos_scoped, by_lexeme, sources) do
    pos_scoped
    |> Enum.group_by(& &1.from_lexeme_id)
    |> Enum.map(fn {lexeme_id, rows} ->
      groups = group_chips(rows, sources)

      %{
        pos: by_lexeme[lexeme_id] && by_lexeme[lexeme_id].pos,
        groups: groups,
        counts: Map.new(groups, fn {group, chips} -> {group, total_of(chips)} end)
      }
    end)
    |> Enum.reject(&(&1.groups == %{}))
    |> Enum.sort_by(&pos_rank(&1.pos))
  end

  defp group_chips(rows, sources) do
    rows
    |> Enum.group_by(&Map.fetch!(@groups, &1.type))
    |> Enum.flat_map(fn
      {:says_see, rows} -> says_see(rows, sources)
      {group, rows} -> [{group, rows}]
    end)
    # WordNet's `see_also` and its `other` edges both land on :related, and a
    # word can hold both. Merging the rows before capping is the difference
    # between a group of twelve and a group of twelve that silently lost half
    # its members to `Map.new/1`.
    |> Enum.reduce(%{}, fn {group, rows}, acc ->
      Map.update(acc, group, rows, &(&1 ++ rows))
    end)
    |> Map.new(fn {group, rows} -> {group, chips(rows)} end)
    |> Map.reject(fn {_group, chips} -> chips.total == 0 end)
  end

  # "Johnson says see" and "Bierce says see" are different claims, so `see_also`
  # becomes one group per 👑 source. WordNet's cross-references are not an
  # author's opinion and fold into `related`.
  defp says_see(rows, sources) do
    {authored, institutional} =
      Enum.split_with(rows, fn r ->
        sources[r.source_id] && sources[r.source_id].tier == :aristocracy
      end)

    per_author =
      authored
      |> Enum.group_by(& &1.source_id)
      |> Enum.map(fn {source_id, rows} -> {{:says_see, sources[source_id]}, rows} end)

    per_author ++ [{:related, institutional}]
  end

  # A WordNet synset is one chip, not one chip per member: `to_group_key`
  # collapses them, and the row with the most weight names it.
  defp chips(rows) do
    rows
    |> Enum.sort_by(&{-&1.weight, &1.lemma})
    |> Enum.uniq_by(&(&1.to_group_key || &1.slug))
    |> Enum.uniq_by(& &1.slug)
    |> Enum.sort_by(&{!&1.enriched?, -&1.weight, &1.lemma})
    |> Enum.map(fn r ->
      %{
        lemma: r.lemma,
        slug: r.slug,
        pos: r.pos,
        enriched?: r.enriched?,
        source: r.source_id,
        relation: r.type,
        weight: r.weight
      }
    end)
    |> cap()
  end

  # The cap travels with the chips so the template never has to know it: a group
  # renders what it is given and prints `total - length(shown)` as its “+N”.
  defp cap(chips) do
    %{shown: Enum.take(chips, @chip_cap), total: length(chips), rest: Enum.drop(chips, @chip_cap)}
  end

  defp total_of(%{total: total}), do: total

  # ── chain ────────────────────────────────────────────────────────────────

  defp chains(senses, sources) do
    wordnet = Enum.find_value(sources, fn {_id, s} -> s.slug == "wordnet" && s end)
    sense_ids = for s <- senses, s.source_id == (wordnet && wordnet.id), do: s.id

    case sense_ids do
      [] -> %{}
      ids -> walk_chain(ids, wordnet.id)
    end
  end

  @chain_sql """
  WITH RECURSIVE walk AS (
    SELECT s.group_key AS root, s.group_key AS group_key, 0 AS depth,
           ARRAY[s.group_key]::text[] AS path
    FROM senses s
    WHERE s.id = ANY($1) AND s.group_key IS NOT NULL
    UNION ALL
    SELECT w.root, p.to_group_key, w.depth + 1, w.path || p.to_group_key::text
    FROM walk w
    CROSS JOIN LATERAL (
      SELECT r.to_group_key
      FROM senses s2
      JOIN lexical_relations r ON r.from_sense_id = s2.id
      WHERE s2.group_key = w.group_key AND s2.source_id = $2
        AND r.type = 'hypernym' AND r.to_group_key IS NOT NULL
      ORDER BY r.weight DESC, r.to_group_key
      LIMIT 1
    ) p
    WHERE w.depth < $3 AND NOT (p.to_group_key::text = ANY(w.path))
  )
  SELECT w.root, w.depth, rep.lemma, rep.slug, rep.enriched
  FROM walk w
  JOIN LATERAL (
    SELECT l.lemma, l.slug, (l.enriched_at IS NOT NULL) AS enriched
    FROM senses s3
    JOIN lexemes l ON l.id = s3.lexeme_id
    WHERE s3.group_key = w.group_key AND s3.source_id = $2
    ORDER BY s3.position, l.lemma
    LIMIT 1
  ) rep ON TRUE
  WHERE w.depth > 0
  ORDER BY w.root, w.depth
  """

  defp walk_chain(sense_ids, wordnet_id) do
    %{rows: rows} = Repo.query!(@chain_sql, [sense_ids, wordnet_id, @chain_depth])

    rows
    |> Enum.group_by(fn [root | _] -> root end)
    |> Map.new(fn {root, rows} ->
      {root,
       Enum.map(rows, fn [_root, depth, lemma, slug, enriched] ->
         %{depth: depth, lemma: lemma, slug: slug, enriched?: enriched}
       end)}
    end)
  end

  # ── trail ────────────────────────────────────────────────────────────────

  # Slugs, in the URL, so a walk is shareable and survives a reload. Capped and
  # deduplicated here rather than trusted: the trail is user input.
  defp trail(nil), do: []
  defp trail([]), do: []

  defp trail(slugs) do
    slugs = slugs |> Enum.uniq() |> Enum.take(-@trail_cap)

    # One slug can hold several capitalisations — *oyster*, *Oyster*, *OYSTER*.
    # The trail wants the word as the page titles it: the enriched row first,
    # then the lowercase one, so a walk reads `oyster › bivalve`, not `Oyster ›
    # bivalve`.
    lemmas =
      Repo.all(
        from l in Lexeme,
          where: l.slug in ^slugs,
          distinct: l.slug,
          order_by: [asc: l.slug, asc: fragment("? IS NULL", l.enriched_at), asc: l.lemma],
          select: {l.slug, l.lemma}
      )
      |> Map.new()

    Enum.map(slugs, &%{slug: &1, lemma: Map.get(lemmas, &1, &1)})
  end

  defp pos_rank(nil), do: {length(@pos_rank), ""}

  defp pos_rank(pos) do
    case Enum.find_index(@pos_rank, &(&1 == pos)) do
      nil -> {length(@pos_rank), pos}
      i -> {i, pos}
    end
  end
end
