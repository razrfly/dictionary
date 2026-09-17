defmodule DevilsDictionary.Lexicon do
  @moduledoc """
  Words. Queries over `lexemes` (language · lemma · part of speech, the full
  English index), `lexeme_forms`, `senses` with their revisions, `scopes` and
  `scope_lexeme_members`. Dictionaries attach here. Spec: issue #69 §4.

  A word is addressed by its `object_id`. `slug` is a cosmetic label and
  deliberately not unique — #74 ADR decision 10, and the reason `C++` no longer
  lands on `/define/c`.
  """

  import Ecto.Query, warn: false

  alias DevilsDictionary.Lexicon.{Browse, Scope, ScopeMember}
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Lexeme, LexemeForm, Sense, SenseRevision}
  alias DevilsDictionary.Repo

  @doc """
  Trigram search over the index. See `DevilsDictionary.Lexicon.Browse.search/2`.
  """
  defdelegate search(query, opts \\ []), to: Browse

  @doc """
  One page of a scope's lexemes with the coverage its badges need. See
  `DevilsDictionary.Lexicon.Browse.browse/2`.
  """
  defdelegate browse(scope_slug, opts \\ []), to: Browse

  @doc """
  A random draw over the index. See
  `DevilsDictionary.Lexicon.Browse.random_lexemes/1`.
  """
  defdelegate random_lexemes(opts \\ []), to: Browse

  @doc """
  One enriched word from either scope — *Surprise me*. See
  `DevilsDictionary.Lexicon.Browse.random_word/0`.
  """
  defdelegate random_word(), to: Browse

  # ── lexemes ──────────────────────────────────────────────────────────────

  def get_lexeme(lang \\ "en", lemma, pos) do
    Registry.lexeme_by_key(lang, lemma, pos)
  end

  @doc """
  A word by its identity — what `/words/:id/:slug` renders.

  The canonical lookup. Takes a string because it arrives from a URL, and
  returns nil rather than raising on anything that is not an id: an address bar
  is user input.
  """
  def by_object_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {object_id, ""} -> by_object_id(object_id)
      _ -> nil
    end
  end

  def by_object_id(id) when is_integer(id), do: Repo.get(Lexeme, id)
  def by_object_id(_), do: nil

  @doc """
  Every lexeme sharing a slug — what `/define/:slug` renders, across every part
  of speech and every casing.
  """
  def list_by_slug(slug) do
    Repo.all(from l in Lexeme, where: l.slug == ^slug, order_by: [l.lemma, l.part_of_speech])
  end

  @doc """
  Case-insensitive lookup by lemma, using the `lower(lemma)` index.
  """
  def list_by_lemma(lemma, lang \\ "en") do
    down = String.downcase(lemma)

    Repo.all(
      from l in Lexeme,
        where: l.language_tag == ^lang and fragment("lower(?)", l.lemma) == ^down,
        order_by: l.part_of_speech
    )
  end

  def count_lexemes(lang \\ "en") do
    Repo.aggregate(from(l in Lexeme, where: l.language_tag == ^lang), :count)
  end

  @doc """
  Resolves what someone typed (or a `/define/:slug` segment) to lexemes.

  Three steps, in order, stopping at the first that finds anything:

    1. the slug or the lemma itself
    2. `canonical_lexeme_id` — *oistre* is a variant spelling of *oyster*
    3. `lexeme_forms` — *monkeys* is listed among *monkey*'s inflections

  Step 3 is why the index pass records a form row for every bare word: an
  inflected form does not need a record of its own to land on the right page,
  and the `lower(written_form)` index makes the lookup cheap. Scorecard row X3
  is both step 2 and step 3.

  The subtlety is step 3. *monkeys* has an index row of its own — the dump lists
  534,780 form-of entries as headwords — so a plain lemma match finds it and
  stops, on a page with nothing on it. The index pass marks those rows
  `metadata.form_of`, so a **bare** match (no senses, no entries, no canonical
  target) that is only a form-of entry is not good enough to stop at: if some
  other word claims the string as one of its forms, that word is the answer. A
  bare row that is a headword in its own right, matched in its exact casing,
  keeps its page, and the words that list the string among their forms come
  back under `also`. A bare row in another casing (*CATS* for *cats*) does not
  outrank a forms match.

  Returns `%{lexemes: [...], via: :lemma | :canonical | :form | :none,
  matched: term}`, with `via` telling the word page whether to show a
  "redirected from" line.
  """
  def lookup(word, lang \\ "en") do
    word = String.trim(word || "")
    matches = by_lemma_or_slug(word, lang)

    # Exact case only: a bare "CATS" must not answer for "cats".
    headwords = Enum.reject(matches, &(form_of_entry?(&1) or &1.lemma != word))
    non_form_matches = Enum.reject(matches, &form_of_entry?/1)

    cond do
      Enum.any?(headwords, &enriched?/1) ->
        # Enrichment belongs to the record, not to a case-folded spelling. A
        # genuine exact-case headword keeps its page, but an enriched `CATS`
        # name/noun row must not hijack the lowercase inflection `cats` before
        # `by_form/2` can resolve it to `cat`.
        # Once the exact spelling establishes that this is a headword page,
        # keep its case variants together (for example `cat` and the acronym
        # `CAT`) so source cards and sense groups are not silently split.
        resolve_canonical(non_form_matches, word, :lemma)

      headwords != [] ->
        # Bare, but a headword in its own right: it keeps its page. Whatever
        # lists the string as one of its forms is offered alongside.
        headwords
        |> resolve_canonical(word, :lemma)
        |> Map.put(:also, by_form(word, lang))

      (forms = by_form(word, lang)) != [] ->
        resolve_canonical(forms, word, :form)

      matches != [] ->
        resolve_canonical(matches, word, :lemma)

      true ->
        %{lexemes: [], via: :none, matched: nil}
    end
  end

  defp form_of_entry?(lexeme), do: lexeme.metadata["form_of"] == true

  defp bare_form_of?(lexeme), do: form_of_entry?(lexeme) and not enriched?(lexeme)

  defp enriched?(lexeme),
    do: not is_nil(lexeme.enriched_at) or not is_nil(lexeme.canonical_lexeme_id)

  @doc """
  Every lexeme on the page one lexeme belongs to, as a query of object ids.

  The scope is the one `lookup/2` already uses — same language, matching lemma
  (case-folded) or matching slug — asked of a **lexeme id** rather than of a
  string a reader typed, because that is what a discovery target, a mapping and
  a catalog read all hold. `by_lemma_or_slug/2` cannot answer it: it anchors on
  the input word, so the same page reached by `/words/:id/:slug` and by
  `/define/:slug` would resolve to different sets.

  It is a query and not a list so a caller can join senses onto it in one round
  trip; `page_lexeme_ids/1` is the list.
  """
  def page_scope(object_id) when is_integer(object_id) do
    from l in Lexeme,
      join: target in Lexeme,
      on: target.object_id == ^object_id,
      where:
        l.language_tag == target.language_tag and
          (fragment("lower(?) = lower(?)", l.lemma, target.lemma) or l.slug == target.slug),
      select: l.object_id
  end

  @doc "The page's lexeme ids, sorted, so the set is the same however it is read."
  def page_lexeme_ids(object_id) when is_integer(object_id) do
    object_id |> page_scope() |> Repo.all() |> Enum.sort()
  end

  defp by_lemma_or_slug(word, lang) do
    down = String.downcase(word)

    Repo.all(
      from l in Lexeme,
        where:
          l.language_tag == ^lang and
            (fragment("lower(?)", l.lemma) == ^down or l.slug == ^down),
        order_by: [l.lemma, l.part_of_speech]
    )
  end

  # Forms are rows in `lexeme_forms` now, each carrying the source revision that
  # attested it, so this is a join rather than a JSONB containment test. Exact
  # case first, since `US` and `us` are different words; the fallback uses the
  # `lower(written_form)` index.
  defp by_form(word, lang) do
    case do_by_form(word, lang, :exact) do
      [] -> do_by_form(String.downcase(word), lang, :folded)
      lexemes -> lexemes
    end
  end

  defp do_by_form("", _lang, _casing), do: []

  defp do_by_form(form, lang, casing) do
    query =
      from l in Lexeme,
        join: f in LexemeForm,
        on: f.lexeme_id == l.object_id,
        where: l.language_tag == ^lang,
        distinct: true,
        order_by: [l.lemma, l.part_of_speech]

    query
    |> match_form(casing, form)
    |> Repo.all()
  end

  defp match_form(query, :exact, form), do: where(query, [_l, f], f.written_form == ^form)

  defp match_form(query, :folded, form),
    do: where(query, [_l, f], fragment("lower(?)", f.written_form) == ^form)

  # A page shows the canonical word, not the variant that led there. Only
  # redirect when every match agrees, so an ambiguous word keeps its own page.
  defp resolve_canonical(lexemes, word, via) do
    # A bare form-of index row has no opinion about where the word belongs,
    # because nobody wrote one — the index pass only flagged it. It must not
    # veto a row that does have one: `geese` has a bare Wiktionary row beside
    # Johnson's "The plural of goose", and the bare row was winning the
    # disagreement. `spat` still keeps its page, because `spat/noun` is a real
    # headword rather than a bare row.
    deciding =
      case Enum.reject(lexemes, &bare_form_of?/1) do
        [] -> lexemes
        rest -> rest
      end

    case deciding |> Enum.map(& &1.canonical_lexeme_id) |> Enum.uniq() do
      [id] when is_integer(id) ->
        %{
          lexemes:
            Repo.all(
              from l in Lexeme,
                where: l.object_id == ^id,
                order_by: [l.lemma, l.part_of_speech]
            ),
          via: :canonical,
          matched: word
        }

      _ ->
        %{lexemes: lexemes, via: via, matched: word}
    end
  end

  # ── senses ───────────────────────────────────────────────────────────────

  def count_senses, do: Repo.aggregate(Sense, :count)

  @doc """
  Distinct `group_key` values for a source — WordNet's synset count (A2).
  """
  def count_sense_groups(source_id) do
    Repo.one(
      from s in Sense,
        join: r in SenseRevision,
        on: r.sense_id == s.object_id and r.is_current,
        where: s.source_id == ^source_id and not is_nil(r.group_key),
        select: count(r.group_key, :distinct)
    )
  end

  @doc """
  Distinct lexemes carrying at least one sense from a source (A2's second half).
  """
  def count_lexemes_with_senses(source_id) do
    Repo.one(
      from s in Sense,
        where: s.source_id == ^source_id,
        select: count(s.lexeme_id, :distinct)
    )
  end

  # ── scopes ───────────────────────────────────────────────────────────────

  def list_scopes, do: Repo.all(from s in Scope, order_by: s.slug)

  def get_scope_by_slug!(slug), do: Repo.get_by!(Scope, slug: slug)
  def get_scope_by_slug(slug), do: Repo.get_by(Scope, slug: slug)

  @doc """
  The slugs, comma-joined, for the "you have to pick one" messages.

  Every entry point that used to fall back to `animals` now says what it could
  have been given instead (#77 §2). Read rather than hardcoded, because a scope
  is data — the list is right the day a fourth one is added.
  """
  def scope_slugs do
    case Repo.all(from s in Scope, order_by: s.slug, select: s.slug) do
      [] -> "none — no scopes exist yet; see mix dd.scope.new"
      slugs -> Enum.join(slugs, ", ")
    end
  end

  @doc """
  The scopes a word belongs to, by lexeme id.

  **No longer read by the word page.** It backed U2's *in Animals* / *not in
  Animals or Emotions* line, which #77 §1 removed: scope names are internal, and
  the line linked a public page at what is now an ops surface. Kept as an
  ordinary read — browse and the ops pages are the callers a scope-membership
  question belongs to.

  One indexed query over `scope_lexemes`, and deliberately **not** part of
  `WordPage.build/2`: X1 builds two hundred pages a scorecard and would pay for
  a line only the headword renders. Scope membership is a browse concept
  visiting a scope-free page (#71 §10), which is exactly why it is fetched
  beside the page rather than inside it.

  Returns `[%{slug, name}]`, ordered by slug.
  """
  def scopes_for(lexeme_ids) when is_list(lexeme_ids) do
    if lexeme_ids == [] do
      []
    else
      Repo.all(
        from sl in ScopeMember,
          join: s in Scope,
          on: s.id == sl.scope_id,
          where: sl.lexeme_id in ^lexeme_ids,
          distinct: true,
          order_by: s.slug,
          select: %{slug: s.slug, name: s.name}
      )
    end
  end

  @doc """
  Creates or updates a scope row from its slug, name and rules.

  A scope is data, not code (scorecard E2): `mix dd.scope.new` writes the row,
  `mix dd.scope.build` applies its rules. `Sources.Catalog.scopes/0` seeds
  `animals` only because the first scope has to come from somewhere.

  Upserts on the slug so re-running with amended rules is safe; existing
  `scope_lexemes` are untouched, and `mix dd.scope.build --reset` is how a
  narrowed rule set drops the members it no longer matches.
  """
  def create_scope(attrs) do
    %Scope{}
    |> Scope.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :rules, :updated_at]},
      conflict_target: :slug,
      returning: true
    )
  end

  def update_scope(%Scope{} = scope, attrs) do
    scope |> Scope.changeset(attrs) |> Repo.update!()
  end

  def count_scope_lexemes(%Scope{id: id}) do
    Repo.aggregate(from(sl in ScopeMember, where: sl.scope_id == ^id), :count)
  end

  @doc """
  Counts scope members per reason tag. This is what `mix dd.scope.build` prints
  and what scorecard row A4 reports.
  """
  def scope_reason_counts(%Scope{id: id}) do
    Repo.all(
      from sl in ScopeMember,
        where: sl.scope_id == ^id,
        select: {fragment("unnest(?)", sl.reasons), count()},
        group_by: fragment("unnest(?)", sl.reasons)
    )
    |> Map.new()
  end

  @doc """
  Scope rows carrying no reason at all. A4 requires this to be zero.
  """
  def count_scope_lexemes_without_reason(%Scope{id: id}) do
    Repo.aggregate(
      from(sl in ScopeMember,
        where: sl.scope_id == ^id and fragment("cardinality(?) = 0", sl.reasons)
      ),
      :count
    )
  end
end
