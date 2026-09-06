defmodule DevilsDictionary.Lexicon do
  @moduledoc """
  Words. Schemas and queries for `lexemes` (lang · lemma · pos, the full English
  index), `senses`, `entries`, `lexical_relations`, `scopes` and `scope_lexemes`.
  Dictionaries attach here. Spec: issue #69 §4.
  """

  import Ecto.Query, warn: false

  alias DevilsDictionary.Lexicon.{Browse, Lexeme, Scope, ScopeLexeme, Sense}
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

  # ── lexemes ──────────────────────────────────────────────────────────────

  def get_lexeme(lang \\ "en", lemma, pos) do
    Repo.get_by(Lexeme, lang: lang, lemma: lemma, pos: pos)
  end

  @doc """
  Every lexeme sharing a slug — what `/define/:slug` renders, across every part
  of speech and every casing.
  """
  def list_by_slug(slug) do
    Repo.all(from l in Lexeme, where: l.slug == ^slug, order_by: [l.lemma, l.pos])
  end

  @doc """
  Case-insensitive lookup by lemma, using the `lower(lemma)` index.
  """
  def list_by_lemma(lemma, lang \\ "en") do
    down = String.downcase(lemma)

    Repo.all(
      from l in Lexeme,
        where: l.lang == ^lang and fragment("lower(?)", l.lemma) == ^down,
        order_by: l.pos
    )
  end

  def count_lexemes(lang \\ "en") do
    Repo.aggregate(from(l in Lexeme, where: l.lang == ^lang), :count)
  end

  @doc """
  Resolves what someone typed (or a `/define/:slug` segment) to lexemes.

  Three steps, in order, stopping at the first that finds anything:

    1. the slug or the lemma itself
    2. `canonical_lexeme_id` — *oistre* is a variant spelling of *oyster*
    3. `forms` — *monkeys* is listed among *monkey*'s inflections

  Step 3 is why the index pass stores `forms` on every bare row: an inflected
  form does not need a record of its own to land on the right page, and the
  `lexemes_forms_index` GIN index makes the containment lookup cheap. Scorecard
  row X3 is both step 2 and step 3.

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

    cond do
      matches != [] and Enum.any?(matches, &enriched?/1) ->
        resolve_canonical(matches, word, :lemma)

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

  defp enriched?(lexeme),
    do: not is_nil(lexeme.enriched_at) or not is_nil(lexeme.canonical_lexeme_id)

  defp by_lemma_or_slug(word, lang) do
    down = String.downcase(word)

    Repo.all(
      from l in Lexeme,
        where:
          l.lang == ^lang and
            (fragment("lower(?)", l.lemma) == ^down or l.slug == ^down),
        order_by: [l.lemma, l.pos]
    )
  end

  # `forms` is a jsonb array of objects, so containment finds "monkeys" inside
  # [%{"form" => "monkeys", "tags" => ["plural"]}] whatever else the object
  # carries. Exact case first, since `US` and `us` are different words.
  defp by_form(word, lang) do
    case do_by_form(word, lang) do
      [] -> do_by_form(String.downcase(word), lang)
      lexemes -> lexemes
    end
  end

  defp do_by_form("", _lang), do: []

  defp do_by_form(form, lang) do
    contains = [%{"form" => form}]

    Repo.all(
      from l in Lexeme,
        where: l.lang == ^lang and fragment("? @> ?", l.forms, ^contains),
        order_by: [l.lemma, l.pos]
    )
  end

  # A page shows the canonical word, not the variant that led there. Only
  # redirect when every match agrees, so an ambiguous word keeps its own page.
  defp resolve_canonical(lexemes, word, via) do
    case lexemes |> Enum.map(& &1.canonical_lexeme_id) |> Enum.uniq() do
      [id] when is_integer(id) ->
        %{
          lexemes: Repo.all(from l in Lexeme, where: l.id == ^id, order_by: [l.lemma, l.pos]),
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
        where: s.source_id == ^source_id and not is_nil(s.group_key),
        select: count(s.group_key, :distinct)
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

  def get_scope_by_slug!(slug), do: Repo.get_by!(Scope, slug: slug)
  def get_scope_by_slug(slug), do: Repo.get_by(Scope, slug: slug)

  def update_scope(%Scope{} = scope, attrs) do
    scope |> Scope.changeset(attrs) |> Repo.update!()
  end

  def count_scope_lexemes(%Scope{id: id}) do
    Repo.aggregate(from(sl in ScopeLexeme, where: sl.scope_id == ^id), :count)
  end

  @doc """
  Counts scope members per reason tag. This is what `mix dd.scope.build` prints
  and what scorecard row A4 reports.
  """
  def scope_reason_counts(%Scope{id: id}) do
    Repo.all(
      from sl in ScopeLexeme,
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
      from(sl in ScopeLexeme,
        where: sl.scope_id == ^id and fragment("cardinality(?) = 0", sl.reasons)
      ),
      :count
    )
  end
end
