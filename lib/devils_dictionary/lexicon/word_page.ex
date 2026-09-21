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
  `from_sense_id` belongs to **that sense** and renders under it, inside its
  source card; a relation without one belongs to the **part of speech** and
  renders in the page-level *Related words* block. This is the S0 audit's
  per-sense rule made physical: WordNet hangs its edges off senses, so *cat*'s
  tracked-vehicle sense keeps *tracked vehicle* to itself instead of the animal
  listing it among its broader words. Wiktionary is mixed — its antonyms and
  most synonyms are sense-scoped, its derived and coordinate edges are not.

  *Under the sense*, not under the card. U1a grouped the chips one level up,
  which is the same thing for WordNet — one synset is one group is one sense —
  and wrong for Wiktionary, whose senses all share the nil group: *cat* listed
  *kitty* and *tabby* beside *bloke* and *prostitute*.

  ## Batched page queries

  Sources; senses; content (by lexeme **or** by the primary entity, which is how
  Wikipedia's summary arrives); the content's authors; the primary entity; relations; the WordNet
  chain; the trail's lemmas. All of them keyed by the lexeme ids `lookup/2`
  returned, none of them in a loop.

  The chain is the one that had to be built rather than borrowed, and its shape
  matters: walking lexeme to lexeme gives *oyster › bivalve › allocation ›
  abstract entity*, because a lemma reached through one synset carries every
  other synset it belongs to. The walk is sense → synset instead —
  `sense_revisions.group_key` to the parent sense's `group_key` over the
  `hypernym` predicate, re-entering through any sense of the parent synset — and
  it takes exactly one parent per step (`CROSS JOIN LATERAL … LIMIT 1`), so one
  synset yields one linear chain rather than the fan-out a plain recursive CTE
  produces.

  ## Ported to the encyclopedia model

  `entries` became `content_items` + `content_revisions` reached by a `defines`
  or `about` assertion; `lexical_relations` became assertions on the
  source-native predicates; `concepts` became `entities`. What each of the two
  rules above says is unchanged, and so is every cap, order and id.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Markdown

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    Lexeme,
    LexemeForm,
    Sense,
    SenseRevision
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  defstruct headword: nil, cards: [], source_groups: [], related: nil, thing: nil, trail: []

  @chip_cap 12
  # Above this, a group's “+N” is a scrolling list rather than a wall of chips.
  # `family` is 281 chips on *love* and 261 on *set*, and a disclosure that
  # opens to five screens of them is a disclosure that ends the page (#133 R4).
  # 48 is four rows of twelve — the cap again, four times over — which is as
  # much as opens without the rest of the rail leaving the viewport.
  @scroll_cap 48
  @gloss_cap 3
  # A `name` or a `suffix` lexeme is not the word: *Love County* is what the
  # proper noun *Love* is derived from, not what *love* is related to. Their
  # rows fold into one `names` group rather than into the word's own.
  @other_lexemes ~w(name suffix)

  # #131 Phase 1's measured limits. They live here rather than in a component
  # because a cap is a decision about the content, and a component that decides
  # will decide differently next time (#71 §8a.4).
  #
  # `@entry_whole` is the "keep short content whole" rule with a number on it:
  # Bierce on *love* is 428 characters and Johnson on *nepotism* 292, and a
  # fold that reaches either is a fold working against the page's reason to
  # exist. Above it an entry previews `@entry_preview` characters — about four
  # lines at 1280 against the 47rem prose column, eight at 375 — and discloses
  # the remainder. The preview is the *opening of the original*, split at a
  # block boundary: nothing is rewritten, reordered, dropped or shown twice.
  @entry_whole 600
  @entry_preview 360
  # Forms are unbounded in the corpus — `little` has 66, `fuck` 40 — and so are
  # sense groups: WordNet files *love* under six synsets, each bringing a
  # relation row and a broader chain. Bounding the length of an item is not
  # bounding how many of them a source may file.
  @form_cap 8
  @group_cap 3
  # Two origins is what `love` has and what a rail can carry open; `set` files
  # five, and five paragraphs of descent above the source list is the rail
  # becoming the page.
  @origin_cap 2
  # The same shape as `@entry_whole` / `@entry_preview` above, for the same
  # reason and at the rail's scale. An origin at or under `@origin_whole` is
  # shown whole — Wiktionary's `name` origin for *love* is 88 characters and a
  # fold that reaches it is a fold working against the thing #133 R5 is trying
  # to put on screen. A longer one is cut to `@origin_budget` and discloses the
  # remainder. R5 expected `nepotism` to fall on the whole side; it does not,
  # because its origin is 274 characters, not the short one the issue assumed.
  #
  # The two numbers are measured, not chosen. The rail is 22.5rem and its type
  # renders at 7.64px a character, so a line holds about 47 of them and R5's
  # "no more than two visual lines" is ~94 — less the `origin (noun, verb)`
  # label and the `… 1,170 more` that follows, which is where 64 comes from.
  # R5 says "a budget of ~150" and draws a wireframe whose head is 84
  # characters; both cannot hold at 47 characters a line, and the two-line
  # measurement is the one with a number on it.
  @origin_whole 150
  @origin_budget 64
  @chain_depth 8
  @trail_cap 12

  # #71 §7's map, as data. Every `lexical_relations.type` lands in exactly one
  # group; `see_also` splits by source because "Johnson says see" and "Bierce
  # says see" are different claims, and WordNet's fold into `related`.
  # Keys are predicate keys, which are strings, because a predicate is a row in
  # a data file now rather than a member of an enum. A predicate this map does
  # not name renders under :related rather than raising — `priv/predicates/` is
  # allowed to grow without this file changing, which is what E1 measures.
  @groups %{
    "synonym" => :similar,
    "coordinate" => :similar,
    "antonym" => :opposite,
    "hypernym" => :broader,
    "hyponym" => :narrower,
    "meronym" => :parts,
    "holonym" => :part_of,
    "derived" => :family,
    "related" => :family,
    "alt_of" => :variants,
    "form_of" => :variants,
    "see_also" => :says_see,
    "other" => :related
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
    :related,
    # Last, and not one of #71 §7's relation kinds: the other lexemes that
    # share this spelling, folded here by `names/2` (#133 R4).
    :names
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
    related: "related",
    names: "names"
  }

  @tier_rank %{aristocracy: 0, middle: 1, plebs: 2}
  @pos_rank ~w(noun verb adj adjective adv adverb)

  @doc "The group keys in render order."
  def group_order, do: @group_order

  @doc "The human label for a group key."
  def group_label(group), do: Map.fetch!(@group_labels, group)

  @doc "How many chips a group shows before its “+N”."
  def chip_cap, do: @chip_cap

  @doc "The group size above which the “+N” opens a scrolling list."
  def scroll_cap, do: @scroll_cap

  @doc "How many glosses a sense card shows before “show N more”."
  def gloss_cap, do: @gloss_cap

  @doc "Characters of entry text at or under which an entry is shown whole."
  def entry_whole, do: @entry_whole

  @doc "Characters a longer entry previews before its disclosure."
  def entry_preview, do: @entry_preview

  @doc "How many forms the headword shows before “+N more”."
  def form_cap, do: @form_cap

  @doc "How many sense groups a card shows before its own disclosure."
  def group_cap, do: @group_cap

  @doc "How many origins the rail shows open before folding the rest into one line."
  def origin_cap, do: @origin_cap

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
    lexemes = rank_lexemes(lexemes)
    ids = Enum.map(lexemes, & &1.object_id)
    sources = Map.new(Sources.list_sources(), &{&1.id, &1})

    # The entity for the walks that need one, the flattened view for everything
    # that renders. `Encyclopedia.view/1` is the single place identity and
    # description are put back together.
    entity = primary_concept(lexemes)
    concept = Encyclopedia.view(entity)

    senses = senses(ids)
    # Relations and content both reach past the word to its meanings, so the
    # sense ids are gathered once from the senses query rather than asked for
    # twice.
    sense_ids = Enum.map(senses, & &1.id)

    entries = entries(ids, sense_ids, concept)
    relations = relations(ids, sense_ids)
    chains = chains(senses, sources)

    by_lexeme = Map.new(lexemes, &{&1.object_id, &1})
    {sense_scoped, pos_scoped} = Enum.split_with(relations, &(&1.from_sense_id != nil))

    cards = cards(senses, entries, sense_scoped, chains, sources, concept, by_lexeme)

    %__MODULE__{
      headword: headword(lexemes, lookup, sources),
      cards: cards,
      source_groups: source_groups(cards),
      related:
        pos_scoped
        |> related(by_lexeme, sources, hd(lexemes).lemma)
        |> sense_link(cards),
      thing: thing(entity, ids, sources),
      trail: trail(opts[:trail])
    }
  end

  # The bare lemma opens the page. `/define/dog` is seven rows and the lexeme
  # query orders them by lemma, where the database's collation puts `'dog`
  # (#1547258) ahead of `dog` (#51134) — so the page led with an apostrophe, and
  # so did everything downstream of it, including the lexeme a discovery target
  # names. The slug is what the reader actually asked for, so the row whose
  # lemma *is* the slug wins, then the row that differs from it only in case,
  # then everything else. 17,403 English pages had a bare row that a decorated
  # one was beating.
  #
  # Ranking here, once, rather than in each consumer is what makes `headword/3`'s
  # first row, `primary_concept/1`'s first noun and
  # `Discovery.target_for_page/3`'s `object_id` agree without any of them
  # knowing about the others. The sort is stable and keyed only on the lemma's
  # rank, so within a tier the query's `[lemma, part_of_speech]` order survives,
  # and `headword/3`'s own stable sort by `pos_rank/1` then keeps the bare lemma
  # first *within* its part of speech, which is where the reader meets it.
  defp rank_lexemes(lexemes), do: Enum.sort_by(lexemes, &lemma_rank(&1.lemma, &1.slug))

  defp lemma_rank(lemma, slug) do
    cond do
      lemma == slug -> 0
      String.downcase(lemma) == slug -> 1
      true -> 2
    end
  end

  # ── headword ─────────────────────────────────────────────────────────────

  defp headword([first | _] = lexemes, lookup, sources) do
    %{
      lemma: first.lemma,
      slug: first.slug,
      via: lookup[:via],
      matched: lookup[:matched],
      also:
        Enum.map(
          lookup[:also] || [],
          &%{lemma: &1.lemma, slug: &1.slug, pos: &1.part_of_speech}
        ),
      forms: forms(lexemes),
      pronunciations: pronunciations(lexemes),
      pronunciations_all: pronunciations_all(lexemes),
      etymologies: etymologies(lexemes, sources),
      parts: parts(lexemes),
      lexemes:
        lexemes
        |> Enum.sort_by(&pos_rank(&1.part_of_speech))
        |> Enum.map(fn l ->
          %{
            id: l.object_id,
            language: l.language_tag,
            pos: l.part_of_speech,
            etymology: l.etymology,
            etymology_source: source_name(sources, l.etymology_source_id),
            enriched?: not is_nil(l.enriched_at),
            canonical: l.canonical_lexeme_id
          }
        end)
    }
  end

  # The parts-of-speech line, and only that line. `lexemes` stays whole — the
  # discovery target counts it and the provenance drawer walks it — but the line
  # a reader looks at wants one entry per *word*, and R6's case rule is what
  # decides which rows are the same word: `love`, `Love` and `LoVe` are one
  # noun, one verb and one name, not five labels of which two say `name`.
  #
  # The same fold as `WordLive.choices/2`, so the line and the links it carries
  # can never disagree about how many words the slug names. `C++`, `C+` and `c`
  # differ by more than case and all three keep their place.
  defp parts(lexemes) do
    lexemes
    |> Enum.sort_by(&pos_rank(&1.part_of_speech))
    |> Enum.uniq_by(&{String.downcase(&1.lemma), &1.part_of_speech})
    |> Enum.map(
      &%{id: &1.object_id, pos: &1.part_of_speech, enriched?: not is_nil(&1.enriched_at)}
    )
  end

  # Forms are the union across every part of speech — the reader wants the
  # word's inflections, not a column per pos — deduplicated and stripped of the
  # lemma itself.
  #
  # A row per form now, rather than a JSONB array on the lexeme, so each one
  # carries the source revision that attested it. That is one more query on a
  # page that already runs seven, and it is what makes "which source says
  # *oysters* is the plural" answerable at all.
  defp forms(lexemes) do
    ids = Enum.map(lexemes, & &1.object_id)
    lemmas = MapSet.new(lexemes, & &1.lemma)

    Repo.all(
      from f in LexemeForm,
        where: f.lexeme_id in ^ids,
        order_by: [asc: f.written_form],
        distinct: true,
        select: f.written_form
    )
    |> Enum.reject(&(is_nil(&1) or &1 == "" or MapSet.member?(lemmas, &1)))
  end

  # *cat* carries fourteen pronunciation rows and two distinct IPA strings: the
  # rest are audio recordings of the same two. Keep the ones that actually say
  # how the word sounds, one per spelling, three at most.
  #
  # The column is jsonb and the schema field is a map, so the list lives under
  # `"items"`. A bare JSON array is legal jsonb but not a legal Ecto `:map`, and
  # a wrapper key is a smaller lie than a custom type.
  defp pronunciations(lexemes) do
    lexemes
    |> Enum.flat_map(&(&1.pronunciations["items"] || []))
    |> Enum.map(&{&1["ipa"], &1["tags"]})
    |> Enum.reject(fn {ipa, _tags} -> is_nil(ipa) or ipa == "" end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(3)
    |> Enum.map(fn {ipa, tags} -> %{ipa: ipa, tags: tags || []} end)
  end

  # Every spelling and recording the word carries, for the disclosure behind
  # the three. `love` holds nine spellings and three recordings and the
  # headword has always shown three of them without saying so; the tags were
  # built here and rendered nowhere (#131 Phase 1 inventory, item 7). Empty
  # when there is nothing the headword is not already showing, so a word with
  # one accent grows no control.
  defp pronunciations_all(lexemes) do
    rows =
      lexemes
      |> Enum.flat_map(&(&1.pronunciations["items"] || []))
      |> Enum.map(
        &%{ipa: presence(&1["ipa"]), tags: &1["tags"] || [], audio: presence(&1["audio"])}
      )
      |> Enum.reject(&(is_nil(&1.ipa) and is_nil(&1.audio)))
      |> Enum.uniq_by(&{&1.ipa, &1.audio})

    if length(rows) <= 3, do: [], else: rows
  end

  # Wiktionary files an etymology per part of speech, and for *oyster* it is the
  # same paragraph three times. One paragraph, with the parts of speech it
  # covers named beside it.
  defp etymologies(lexemes, sources) do
    lexemes
    |> Enum.reject(&(is_nil(&1.etymology) or &1.etymology == ""))
    |> Enum.group_by(& &1.etymology)
    |> Enum.map(fn {text, group} ->
      {first, rest} = clause_cut(text)

      %{
        text: text,
        first: first,
        rest: rest,
        source: source_name(sources, hd(group).etymology_source_id),
        parts: group |> Enum.map(& &1.part_of_speech) |> Enum.sort_by(&pos_rank/1)
      }
    end)
    |> Enum.sort_by(&pos_rank(hd(&1.parts)))
  end

  # What a closed card says about itself: how much is behind it, and the
  # source's own opening words. Both are facts about the content rather than
  # about the layout, so they are decided here — and `opening` is a *deterministic
  # excerpt of the original*, never a summary of it (#131: no rewritten text).
  defp summarise(card) do
    senses = Enum.reduce(card.groups, 0, fn group, n -> n + length(group.senses) end)

    Map.merge(card, %{
      senses: senses,
      chars: Enum.reduce(card.entries, 0, &(&2 + &1.chars)),
      opening: opening(card)
    })
  end

  defp opening(%{groups: [%{senses: [sense | _]} | _]}), do: sense.gloss

  defp opening(%{entries: [entry | _]}) do
    entry.preview_html |> text_of() |> String.slice(0, 220)
  end

  defp opening(_card), do: nil

  defp text_of(html) do
    html
    |> String.replace(~r{<[^>]+>}, " ")
    |> String.replace(~r{\s+}, " ")
    |> String.trim()
  end

  # Where one clause of a descent ends and the next begins. Wiktionary's
  # etymologies are chains — *from X, from Y, from Z* — and the joins are the
  # only punctuation in them, so they are the only places a cut reads as a
  # pause rather than as damage.
  @clause_break ~r/(?<=,)\s+(?=[Ff]rom\b)|(?<=;)\s+|(?<=\.)\s+(?=\p{Lu})/u

  @doc """
  An origin's opening clauses, and whatever follows them.

  A **sentence** cut is no cut at all here: Wiktionary writes a whole descent
  as one sentence — *love*'s is 1,200 characters of *from … from … from*
  without a full stop — so `first_sentence/1` returned the paragraph it was
  asked to shorten, four lines of it, which is #133 R5's complaint.

  An origin at or under `@origin_whole` characters is returned whole. A longer
  one is cut by clause: the last `, from`, `;` or sentence end at or before
  `budget` characters. Nothing is rewritten and nothing is lost — the head ends
  on its own punctuation, the remainder is the rest of the original verbatim,
  and joining the two back together reproduces it.

  A clause longer than the budget on its own — an origin with no joins in it at
  all — falls back to the last word boundary, because a rail line that cannot
  be cut is a rail line that decides how tall the rail is.
  """
  def clause_cut(text, budget \\ @origin_budget)

  def clause_cut(text, budget) when is_binary(text) do
    if String.length(text) <= @origin_whole do
      {text, nil}
    else
      {head, rest} = split_clauses(Regex.split(@clause_break, text), budget)

      case Enum.join(rest, " ") do
        "" -> {head, nil}
        rest -> {head, rest}
      end
    end
  end

  defp split_clauses(parts, budget) do
    {taken, rest} = Enum.split(parts, fitting(parts, budget))
    head = Enum.join(taken, " ")

    if String.length(head) <= budget do
      {head, rest}
    else
      {word_head, word_rest} = word_cut(head, budget)
      {word_head, Enum.reject([word_rest | rest], &(&1 == ""))}
    end
  end

  # How many clauses fit. The first is always taken — a head of nothing is not
  # a cut — and the rest while the running length, separators included, stays
  # inside the budget.
  defp fitting(parts, budget) do
    parts
    |> Enum.reduce_while({0, 0}, fn part, {count, len} ->
      len = if count == 0, do: String.length(part), else: len + 1 + String.length(part)

      cond do
        count == 0 -> {:cont, {1, len}}
        len <= budget -> {:cont, {count + 1, len}}
        true -> {:halt, {count, len}}
      end
    end)
    |> elem(0)
  end

  defp word_cut(text, budget) do
    case text |> String.slice(0, budget) |> String.split(" ") do
      [_one] ->
        {String.slice(text, 0, budget),
         text |> String.slice(budget..-1//1) |> String.trim_leading()}

      words ->
        head = words |> Enum.drop(-1) |> Enum.join(" ")

        {head, text |> String.slice(String.length(head)..-1//1) |> String.trim_leading()}
    end
  end

  # ── folding an entry ──────────────────────────────────────────────────────

  # Void elements never close, so a depth counter has to know them or it will
  # count a `<br>` as an unterminated block and swallow the rest of the entry.
  @void ~w(area base br col embed hr img input link meta param source track wbr)

  @doc """
  Splits rendered entry HTML into what a card shows closed and what its
  disclosure holds.

  `body_html` stays whole and is what the ⓘ drawer and the source page render,
  so the fold adds a view rather than replacing one. `preview_html` is the
  opening of the original up to the first block boundary at or past
  `entry_preview/0` characters; `rest_html` is everything after it, verbatim.
  An entry at or under `entry_whole/0` characters has no `rest_html` at all.
  """
  def fold(body_html) do
    chars = text_length(body_html)

    if chars <= @entry_whole do
      %{
        body_html: body_html,
        preview_html: body_html,
        rest_html: nil,
        rest_chars: 0,
        chars: chars
      }
    else
      {head, rest} = split_html(body_html, @entry_preview)

      %{
        body_html: body_html,
        preview_html: head,
        rest_html: presence(rest),
        rest_chars: text_length(rest),
        chars: chars
      }
    end
  end

  defp split_html(html, budget) do
    blocks = blocks(html)
    {head, rest} = take_to_budget(blocks, budget)

    # One block longer than the whole budget — Wikipedia files its summary as a
    # single paragraph — splits at a sentence end instead, so a long paragraph
    # is not an exemption from the fold.
    case head do
      [only] when rest != [] or true ->
        if text_length(only) > budget * 2 do
          case split_sentence(only, budget) do
            {a, b} -> {a, b <> Enum.join(rest)}
            nil -> {Enum.join(head), Enum.join(rest)}
          end
        else
          {Enum.join(head), Enum.join(rest)}
        end

      _ ->
        {Enum.join(head), Enum.join(rest)}
    end
  end

  defp take_to_budget(blocks, budget) do
    {taken, _chars} =
      Enum.reduce_while(blocks, {[], 0}, fn block, {taken, chars} ->
        chars = chars + text_length(block)
        taken = [block | taken]
        if chars >= budget, do: {:halt, {taken, chars}}, else: {:cont, {taken, chars}}
      end)

    taken = Enum.reverse(taken)
    {taken, Enum.drop(blocks, length(taken))}
  end

  # The top-level block elements of rendered markdown, in order. Markdown
  # output is flat — paragraphs, blockquotes, lists, headings — so a depth
  # counter over the tags is enough, and it can never cut inside one.
  defp blocks(html) do
    {out, _depth, start} =
      ~r{<(/?)([a-zA-Z0-9]+)([^>]*)>}
      |> Regex.scan(html, return: :index)
      |> Enum.reduce({[], 0, 0}, fn [{ms, ml}, {_cs, cl}, {ts, tl}, {as, al}],
                                    {out, depth, start} ->
        tag = html |> binary_part(ts, tl) |> String.downcase()
        closing? = cl > 0
        self_closing? = tag in @void or String.ends_with?(binary_part(html, as, al), "/")

        cond do
          self_closing? -> {out, depth, start}
          not closing? and depth == 0 -> {out, 1, ms}
          not closing? -> {out, depth + 1, start}
          depth <= 1 -> {[binary_part(html, start, ms + ml - start) | out], 0, ms + ml}
          true -> {out, depth - 1, start}
        end
      end)

    trailing = binary_part(html, start, byte_size(html) - start)
    out = if String.trim(trailing) == "", do: out, else: [trailing | out]

    case Enum.reverse(out) do
      [] -> [html]
      blocks -> blocks
    end
  end

  # Splits one block after the first sentence end at or past `budget`
  # characters of its text. The scan only breaks at a full stop that sits
  # outside a tag, so a tag is never cut in half.
  defp split_sentence(block, budget) do
    with [_, open, inner, close] <-
           Regex.run(~r{\A(<[a-zA-Z0-9]+[^>]*>)(.*)(</[a-zA-Z0-9]+>)\s*\z}s, block),
         {:ok, at} <- sentence_end(inner, budget) do
      {open <> binary_part(inner, 0, at) <> close,
       open <> String.trim(binary_part(inner, at, byte_size(inner) - at)) <> close}
    else
      _ -> nil
    end
  end

  defp sentence_end(inner, budget) do
    inner
    |> String.to_charlist()
    |> Enum.reduce_while({0, 0, false}, fn char, {index, text, in_tag?} ->
      size = char |> List.wrap() |> to_string() |> byte_size()

      cond do
        char == ?< -> {:cont, {index + size, text, true}}
        char == ?> -> {:cont, {index + size, text, false}}
        in_tag? -> {:cont, {index + size, text, true}}
        char == ?. and text + 1 >= budget -> {:halt, {:ok, index + size}}
        true -> {:cont, {index + size, text + 1, false}}
      end
    end)
    |> case do
      {:ok, at} -> {:ok, at}
      _ -> :none
    end
  end

  defp text_length(html) when is_binary(html) do
    html
    |> String.replace(~r{<[^>]+>}, "")
    |> String.replace(~r{&[a-zA-Z]+;|&#\d+;}, "x")
    |> String.replace(~r{\s+}, " ")
    |> String.trim()
    |> String.length()
  end

  defp text_length(_html), do: 0

  defp presence(""), do: nil
  defp presence(value), do: value

  defp source_name(_sources, nil), do: nil
  defp source_name(sources, id), do: sources[id] && sources[id].name

  # ── cards ────────────────────────────────────────────────────────────────

  # The text is on the current revision; the identity is on the sense. The two
  # joins are the price of a source being able to reword a meaning without the
  # meaning becoming a different one, which is the whole point of #74.
  #
  # `external_key` is selected as `external_id` because it is only ever used to
  # fill a source's `url_template` — provenance, exactly as the schema says, and
  # never identity.
  defp senses(ids) do
    Repo.all(
      from s in Sense,
        join: rev in SenseRevision,
        on: rev.sense_id == s.object_id and rev.is_current,
        left_join: srr in SourceRecordRevision,
        on: srr.id == rev.source_record_revision_id,
        left_join: rec in SourceRecord,
        on: rec.id == srr.source_record_id,
        where: s.lexeme_id in ^ids and s.identity_state != :retired,
        order_by: [asc: rev.position, asc: s.object_id],
        select: %{
          id: s.object_id,
          lexeme_id: s.lexeme_id,
          source_id: s.source_id,
          group_key: rev.group_key,
          gloss: rev.gloss,
          url: rev.url,
          tags: rev.tags,
          position: rev.position,
          external_id: s.external_key,
          record_id: rec.id,
          record_url: rec.url
        }
    )
  end

  # One query for both kinds of published prose: the 👑 authors' definitions
  # reach the word through `defines`, Wikipedia's summary reaches the thing
  # through `about`. In MVP-0 these were two nullable columns on one `entries`
  # row with a check constraint making them exclusive; they are now two
  # predicates, which says the same thing and says it in the endpoint rules.
  #
  # `defines` may name a lexeme *or* a source sense — §C allows both — so the
  # sense ids are in the target list too, and the row reports the lexeme either
  # way so `pos_of/2` still works.
  defp entries(lexeme_ids, sense_ids, concept) do
    defined = lexeme_ids ++ sense_ids
    about = if concept, do: [concept.object_id], else: []

    Repo.all(
      from ci in ContentItem,
        join: cr in ContentRevision,
        on: cr.content_id == ci.object_id and cr.is_current,
        join: link in AssertionRevision,
        on: link.subject_object_id == ci.object_id and link.is_current,
        join: pr in assoc(link, :predicate),
        left_join: target in Sense,
        on: target.object_id == link.object_object_id,
        left_join: srr in SourceRecordRevision,
        on: srr.id == cr.source_record_revision_id,
        left_join: rec in SourceRecord,
        on: rec.id == srr.source_record_id,
        where: link.lifecycle_state == :active and cr.lifecycle_state == :active,
        where:
          (pr.key == "defines" and link.object_object_id in ^defined) or
            (pr.key == "about" and link.object_object_id in ^about),
        order_by: [asc: cr.position, asc: ci.object_id],
        select: %{
          id: ci.object_id,
          lexeme_id:
            fragment(
              "CASE WHEN ? = 'defines' THEN COALESCE(?, ?) END",
              pr.key,
              target.lexeme_id,
              link.object_object_id
            ),
          concept_id: fragment("CASE WHEN ? = 'about' THEN ? END", pr.key, link.object_object_id),
          source_id: ci.source_id,
          headword: cr.headword,
          pos: fragment("? ->> 'pos_marker'", cr.metadata),
          body: cr.body,
          body_format: cr.body_format,
          url: cr.canonical_url,
          thumbnail_url: fragment("? ->> 'thumbnail_url'", cr.metadata),
          year: cr.year,
          record_id: rec.id,
          record_url: rec.url
        }
    )
    |> Enum.uniq_by(& &1.id)
    |> attach_authors()
  end

  defp attach_authors(entries) do
    ids = Enum.map(entries, & &1.id)

    authors =
      Repo.all(
        from(r in AssertionRevision,
          join: p in assoc(r, :predicate),
          join: e in Entity,
          on: e.object_id == r.object_object_id,
          where:
            r.subject_object_id in ^ids and r.is_current and
              r.lifecycle_state == :active and
              p.key == "authored_by",
          order_by: [asc: e.preferred_label, asc: e.object_id],
          select: {r.subject_object_id, %{id: e.object_id, label: e.preferred_label}}
        )
        |> DevilsDictionary.Claims.visible(:public)
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(entries, &Map.put(&1, :authors, Map.get(authors, &1.id, [])))
  end

  # The thing the word names. One lookup off the nominal lexeme: a word is a
  # word, and *oyster* the verb names nothing the noun does not.
  defp primary_concept(lexemes) do
    lexeme = Enum.find(lexemes, &(&1.part_of_speech == "noun")) || hd(lexemes)
    Encyclopedia.primary_entity(lexeme.object_id)
  end

  # ── the thing side (#71 §2.4, U1b) ───────────────────────────────────────

  # Three queries, and only for a word that names something — which most of the
  # index does not. X1 renders 200 random lexemes and 150 of them are bare, so
  # the nil clause is the common path and the page pays nothing for it.
  #
  # The disagreement and the *may refer to* list are asked for even without a
  # primary concept: a word whose every link is a 0.40 candidate has no thing
  # to show and still has possibilities worth naming.
  defp thing(nil, ids, _sources) do
    case Encyclopedia.candidates_for(ids) do
      %{disagreement: [], may_refer_to: []} -> nil
      candidates -> Map.merge(empty_thing(), candidates)
    end
  end

  defp thing(%Entity{} = entity, ids, sources) do
    buckets = Encyclopedia.kinds_and_examples(entity.object_id, @chip_cap)
    candidates = Encyclopedia.candidates_for(ids)
    concept = Encyclopedia.view(entity)

    %{
      concept: concept,
      chain: Encyclopedia.chain(entity, @chain_depth),
      kinds: bucket(buckets, :kind),
      examples: bucket(buckets, :example),
      wikipedia_url: concept_url(sources, "wikipedia", concept),
      wikidata_url: concept_url(sources, "wikidata", concept)
    }
    |> Map.merge(candidates)
  end

  # `kinds_and_examples/2` reports the exact total beside a capped list; the
  # panel calls the capped half `shown`.
  defp bucket(buckets, key) do
    case Map.get(buckets, key) do
      nil -> none()
      %{total: total, items: items} -> %{shown: items, total: total}
    end
  end

  defp empty_thing do
    %{
      concept: nil,
      chain: [],
      kinds: none(),
      examples: none(),
      wikipedia_url: nil,
      wikidata_url: nil
    }
  end

  defp none, do: %{shown: [], total: 0}

  # The thing's two links out, filled from what the concept knows and nothing
  # invented: Wikidata is keyed by the QID, Wikipedia by the article title. A
  # concept with no title has no article — 20,527 of them were introduced by a
  # sitelink someone else's page mentioned — and gets no link rather than a URL
  # ending in a slash.
  defp concept_url(sources, slug, concept) do
    with {_id, source} <- Enum.find(sources, fn {_id, s} -> s.slug == slug end) || :none,
         title when is_binary(title) <- concept.wikipedia_title || concept.label do
      fill_template(source, %{external_id: concept.qid}, title, concept)
    else
      _ -> nil
    end
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
              e.body
              |> Markdown.to_html(e.body_format)
              |> fold()
              |> Map.merge(%{
                authors: e.authors,
                headword: e.headword,
                marker: e.pos,
                year: e.year,
                url: link_out(e, source, nil, concept),
                record_id: e.record_id
              })
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
    |> Enum.sort_by(&{@tier_rank[&1.tier], &1.year || 0, &1.source.slug, pos_rank(&1.pos)})
    |> Enum.map(&summarise/1)
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

  # One row per source, for the rail — the rail's whole job is "who has spoken",
  # and before this it answered with one row per *entry*, nine under a heading
  # that said five (#133 R2).
  #
  # `chunk_by/2` rather than `group_by/2` because the cards are already in the
  # order the page renders them, and R1's sort key puts every entry a source
  # filed next to its siblings: tier and year come from the source itself, so a
  # source cannot reappear in a later chunk. Grouping here rather than in the
  # template is #71 §8a.4 — a component that groups is a component that will
  # group differently from the accordion beside it.
  #
  # A card with no part of speech is not a dictionary entry at all: Wikipedia's
  # content hangs off the concept, never off a lexeme, so `pos_of/2` returns
  # nil. That is the honest label for the right-hand column, and it is what
  # tells the reader an encyclopedia article is not a ninth sense.
  defp source_groups(cards) do
    cards
    |> Enum.chunk_by(& &1.source.slug)
    |> Enum.map(fn [first | _] = group ->
      %{
        slug: first.source.slug,
        source: first.source,
        tier: first.tier,
        card_id: first.id,
        parts: Enum.map(group, &%{label: &1.pos || "article", card_id: &1.id})
      }
    end)
  end

  # Grouping by `group_key` does both jobs at once: WordNet's synsets become one
  # block each, and Wiktionary — which has no group key — falls into a single
  # nil group holding its numbered list.
  #
  # The chain belongs to the group, because it is the synset's walk upward. The
  # chips belong to the **sense**: grouping them one level higher was the U1a
  # audit's half-kept rule, and it put *cat*'s slang synonyms (*bloke*, *guy*)
  # beside its feline ones, since every Wiktionary sense shares the nil group.
  defp sense_groups(rows, source, lemma, relations_by_sense, chains, sources) do
    rows
    |> Enum.group_by(& &1.group_key)
    |> Enum.sort_by(fn {_key, senses} -> senses |> hd() |> Map.get(:position) end)
    |> Enum.map(fn {group_key, senses} ->
      chain = Map.get(chains, group_key, [])

      %{
        group_key: group_key,
        gloss: group_key && senses |> hd() |> Map.get(:gloss),
        chain: chain,
        senses:
          Enum.map(senses, fn s ->
            %{
              id: s.id,
              gloss: s.gloss,
              tags: s.tags,
              url: link_out(s, source, lemma, nil),
              record_id: s.record_id,
              relations:
                relations_by_sense
                |> Map.get(s.id, [])
                |> group_chips(sources)
                # The chain is the broader relation, walked all the way up: its
                # first step is exactly what the :broader chips would say.
                # Showing both puts *bivalve* on the page twice, once as a
                # chain and once as a chip.
                |> then(&if(chain == [], do: &1, else: Map.delete(&1, :broader)))
            }
          end)
      }
    end)
  end

  # Wikipedia's entry hangs off a concept and has no part of speech at all; the
  # 👑 authors' `entries.pos` is the *printed* grammar marker ("n", "n. s."),
  # never our own vocabulary. Both answers come from the lexeme or not at all.
  defp pos_of(_by_lexeme, nil), do: nil

  defp pos_of(by_lexeme, lexeme_id),
    do: by_lexeme[lexeme_id] && by_lexeme[lexeme_id].part_of_speech

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

  # ── provenance (#71 §2.6, U2) ────────────────────────────────────────────

  @raw_cap 24_000

  @doc """
  What the ⓘ drawer shows for one card, or for the thing panel.

  `ref` is the `?provenance=` parameter: `"card:<card-id>"`, optionally with the
  index of the record to open (`"card:card-wordnet-noun:3"`), or `"thing"`. It
  is resolved **against the page that was just built**, so an id nobody put
  there opens nothing and costs nothing — the alternative, a bare
  `source_records.id` in the URL, is an enumerable handle on a table the app
  does not otherwise expose.

  Two queries at most: the cited records' metadata in one (`Sources.records/1`),
  and the `raw` of the single record the reader opened. A WordNet card cites one
  record per synset — twenty is ordinary — so loading every payload would make a
  panel out of a download.

  Returns `nil` when the ref names nothing on this page.
  """
  def provenance(page, ref)

  def provenance(_page, ref) when ref in [nil, ""], do: nil

  def provenance(page, ref) when is_binary(ref) do
    case String.split(ref, ":") do
      ["card", id] -> card_provenance(page, id, 0)
      ["card", id, n] -> card_provenance(page, id, to_index(n))
      ["thing"] -> thing_provenance(page, 0)
      ["thing", n] -> thing_provenance(page, to_index(n))
      _ -> nil
    end
  end

  defp to_index(n) do
    case Integer.parse(n) do
      {i, ""} when i >= 0 -> i
      _ -> 0
    end
  end

  defp card_provenance(page, card_id, index) do
    case Enum.find(page.cards, &(&1.id == card_id)) do
      nil ->
        nil

      card ->
        drawer(
          "card:#{card.id}",
          card.source.name,
          card.source,
          card_record_ids(card),
          index,
          page
        )
    end
  end

  @doc """
  The `source_records` ids a card cites, in the order it cites them — its
  entries first, then its senses, synset by synset. Public because **U3** counts
  them (`Health.Pages.cards_provenance/0`).
  """
  def card_record_ids(card) do
    senses = Enum.flat_map(card.groups, & &1.senses)

    (card.entries ++ senses)
    |> Enum.map(& &1.record_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The thing side has no `source_record_id` to follow: a concept is keyed by
  # its QID, and the two sources that attest it record it under `"Q…"` and
  # `"concept:Q…"`. A convention, not a foreign key — which is why U3 grades
  # cards and reports the panel.
  defp thing_provenance(%{thing: nil}, _index), do: nil
  defp thing_provenance(%{thing: %{concept: nil}}, _index), do: nil

  defp thing_provenance(%{thing: %{concept: concept}} = page, index) do
    titles =
      ["concept:" <> concept.qid] ++
        case concept.wikipedia_title do
          nil -> []
          title -> [title, String.downcase(title)]
        end

    records =
      [
        first_record("wikidata", [concept.qid]),
        first_record("wikipedia", titles)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    drawer("thing", concept.label || concept.qid, nil, Enum.map(records, & &1.id), index, page)
  end

  # A concept's Wikipedia record was written either by the concepts pass, keyed
  # `concept:Q…`, or by the title probe, keyed by the lemma it probed with —
  # which is lowercase where the article is not. Three candidates, the first
  # that answers.
  defp first_record(source_slug, candidates) do
    Enum.find_value(candidates, &Sources.record_by_external_id(source_slug, &1))
  end

  # `source` is the card's — one card is one source. The thing panel's records
  # come from two (Wikidata CC0, Wikipedia CC BY-SA), so every record carries
  # its own source and the panel's header carries none.
  defp drawer(ref, title, source, record_ids, index, page) do
    sources = Map.new(Sources.list_sources(), &{&1.id, &1})

    records =
      record_ids
      |> Sources.records()
      |> Enum.with_index(fn record, i ->
        record |> Map.put(:index, i) |> Map.put(:source, sources[record.source_id])
      end)

    index = if index < length(records), do: index, else: 0
    open = Enum.at(records, index)

    %{
      ref: ref,
      title: title,
      source: source || (open && open.source),
      records: records,
      open: open && index,
      raw: raw_payload(open),
      links: concept_links(page)
    }
  end

  defp raw_payload(nil), do: nil

  defp raw_payload(record) do
    json =
      case Sources.raw(record.id) do
        nil -> "null"
        raw -> raw |> Jason.encode_to_iodata!(pretty: true) |> IO.iodata_to_binary()
      end

    bytes = byte_size(json)

    %{
      record_id: record.id,
      json: binary_part(json, 0, min(bytes, @raw_cap)),
      bytes: bytes,
      shown: min(bytes, @raw_cap),
      truncated?: bytes > @raw_cap
    }
  end

  # The word → thing joins, with the method and the confidence that made them:
  # the drawer's last line in #71 §5's W4. Read off the nominal lexeme, the same
  # one `primary_concept/1` asks, because a word is a word.
  #
  # `status` is the derived review state, not a stored column — an importer
  # cannot write it, which is the fix for a rejected link returning to `auto` on
  # the next run. The predicate is shown too, because a sense-backed
  # `refers_to` and a spelling-level `lexeme_entity_candidate` are different
  # claims and the drawer is exactly where that distinction is worth printing.
  defp concept_links(%{headword: %{lexemes: []}}), do: []

  defp concept_links(%{headword: %{lexemes: lexemes}}) do
    lexeme = Enum.find(lexemes, &(&1.pos == "noun")) || hd(lexemes)

    lexeme.id
    |> Encyclopedia.link_views()
    |> Enum.map(&%{&1 | status: String.to_existing_atom(&1.status)})
    # One claim per row. The same thing is linked once per sense that names it,
    # so *cat* asserts `Q146 · wiktionary_qid · 0.95` twice and the drawer would
    # print the same sentence twice.
    |> Enum.uniq_by(&{&1.qid, &1.method, &1.confidence, &1.status})
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
  # says every chip lands on a page. In this model that condition is free —
  # an edge with no target word is still in `pending_relations` and is not an
  # assertion at all.
  #
  # Both endpoints may be a lexeme or a sense (§C's three declared pairs), so
  # each end is left-joined to `senses` and the coalesce falls through to the
  # object itself where it is a word. `from_sense_id` is what the placement rule
  # reads: present means the edge belongs to that meaning, absent means it
  # belongs to the part of speech.
  defp relations(lexeme_ids, sense_ids) do
    subjects = lexeme_ids ++ sense_ids

    Repo.all(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        left_join: fs in Sense,
        on: fs.object_id == r.subject_object_id,
        left_join: ts in Sense,
        on: ts.object_id == r.object_object_id,
        left_join: trev in SenseRevision,
        on: trev.sense_id == ts.object_id and trev.is_current,
        join: t in Lexeme,
        on: t.object_id == coalesce(ts.lexeme_id, r.object_object_id),
        join: a in assoc(r, :assertion),
        where: r.subject_object_id in ^subjects,
        where: r.is_current and r.lifecycle_state == :active,
        where: p.source_native,
        select: %{
          type: p.key,
          source_id: a.source_id,
          from_lexeme_id: coalesce(fs.lexeme_id, r.subject_object_id),
          from_sense_id: fs.object_id,
          to_group_key: trev.group_key,
          weight: coalesce(r.confidence, 0.0),
          lemma: t.lemma,
          slug: t.slug,
          pos: t.part_of_speech,
          enriched?: not is_nil(t.enriched_at)
        }
    )
  end

  # One block, grouped by relation rather than by lexeme (#133 R4).
  #
  # Grouping by `from_lexeme_id` was the data's key, not the reader's: *love*
  # showed a `Related words · verb` block and a `Related words · name` block
  # and no noun block at all — the noun's relations are sense-scoped and render
  # inside the WordNet and Wiktionary cards — and *set* showed five blocks, two
  # of which called themselves `#related-adj` because two adjective lexemes
  # share the slug. Part of speech is a property of a chip, not the thing that
  # splits the page.
  #
  # Every lexeme's rows are merged **before** `chips/1` caps them, so the cap
  # is twelve of the word's *similar* chips rather than twelve per lexeme.
  defp related(pos_scoped, by_lexeme, sources, lemma) do
    {other, own} =
      Enum.split_with(pos_scoped, &(pos_of(by_lexeme, &1.from_lexeme_id) in @other_lexemes))

    groups = Map.merge(group_chips(own, sources), names(other, lemma))

    if groups == %{} do
      nil
    else
      %{
        groups: groups,
        counts: Map.new(groups, fn {group, chips} -> {group, total_of(chips)} end),
        # Filled by `build/2`, which is the only place that has seen the cards.
        sense_link: nil
      }
    end
  end

  # The `name` and `suffix` lexemes' rows, as one group rendered last. Their
  # own relation kinds are dropped on the way in on purpose: *Set animal* is a
  # thing the proper noun *Set* is derived from, and filing it under the verb
  # *set*'s `family` would be the page claiming a relation nobody asserted.
  # On `love` and `set` every such row is `derived` anyway.
  #
  # A chip that is a case-only variant of the headword goes: `LoVe` beside
  # `love` is a Wiktionary spelling of the same identity, not a word to walk
  # to. The same rule Phase 1 gave `WordLive.choices/2` (#133 R6).
  defp names([], _lemma), do: %{}

  defp names(rows, lemma) do
    chips =
      rows
      |> Enum.reject(&case_variant?(&1.lemma, lemma))
      |> chips()

    if chips.total == 0, do: %{}, else: %{names: chips}
  end

  defp case_variant?(_lemma, nil), do: false

  defp case_variant?(lemma, headword),
    do: String.downcase(lemma) == String.downcase(headword)

  # The line that answers "where did the noun go". A page whose block holds one
  # group or none, while its cards carry sense-scoped chips, points at the first
  # card that has any; anything richer than that does not need the sentence.
  defp sense_link(nil, _cards), do: nil

  defp sense_link(%{groups: groups} = related, cards) when map_size(groups) < 2 do
    %{related | sense_link: Enum.find_value(cards, &(has_chips?(&1) && &1.id))}
  end

  defp sense_link(related, _cards), do: related

  defp has_chips?(card) do
    Enum.any?(card.groups, fn group ->
      Enum.any?(group.senses, &(&1.relations != %{}))
    end)
  end

  defp group_chips(rows, sources) do
    rows
    |> Enum.group_by(&Map.get(@groups, &1.type, :related))
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
  #
  # So do the two render decisions that depend on the *whole* group rather than
  # on one chip (#71 §8a.4). `tags?` is whether the group holds more than one
  # part of speech — merging the lexemes put `wish (v)` beside `emotion` under
  # *broader*, and a tag on every chip of a noun-only group is noise. `scroll?`
  # is whether the “+N” opens a scrolling list instead of a wall.
  defp cap(chips) do
    %{
      shown: Enum.take(chips, @chip_cap),
      total: length(chips),
      rest: Enum.drop(chips, @chip_cap),
      tags?: chips |> Enum.map(& &1.pos) |> Enum.uniq() |> length() > 1,
      scroll?: length(chips) > @scroll_cap
    }
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
    SELECT rev.group_key AS root, rev.group_key AS group_key, 0 AS depth,
           ARRAY[rev.group_key]::text[] AS path
    FROM senses s
    JOIN sense_revisions rev ON rev.sense_id = s.object_id AND rev.is_current
    WHERE s.object_id = ANY($1) AND rev.group_key IS NOT NULL
    UNION ALL
    SELECT w.root, p.to_group_key, w.depth + 1, w.path || p.to_group_key::text
    FROM walk w
    CROSS JOIN LATERAL (
      SELECT trev.group_key AS to_group_key
      FROM senses s2
      JOIN sense_revisions srev ON srev.sense_id = s2.object_id AND srev.is_current
      JOIN assertion_revisions r ON r.subject_object_id = s2.object_id
                                AND r.is_current AND r.lifecycle_state = 'active'
      JOIN predicates pr ON pr.id = r.predicate_id AND pr.key = 'hypernym'
      JOIN senses ts ON ts.object_id = r.object_object_id
      JOIN sense_revisions trev ON trev.sense_id = ts.object_id AND trev.is_current
      WHERE srev.group_key = w.group_key AND s2.source_id = $2
        AND trev.group_key IS NOT NULL
      ORDER BY r.confidence DESC NULLS LAST, trev.group_key
      LIMIT 1
    ) p
    WHERE w.depth < $3 AND NOT (p.to_group_key::text = ANY(w.path))
  )
  SELECT w.root, w.depth, rep.lemma, rep.slug, rep.enriched
  FROM walk w
  JOIN LATERAL (
    SELECT l.lemma, l.slug, (l.enriched_at IS NOT NULL) AS enriched
    FROM senses s3
    JOIN sense_revisions r3 ON r3.sense_id = s3.object_id AND r3.is_current
    JOIN lexemes l ON l.object_id = s3.lexeme_id
    WHERE r3.group_key = w.group_key AND s3.source_id = $2
    ORDER BY r3.position, l.lemma
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
