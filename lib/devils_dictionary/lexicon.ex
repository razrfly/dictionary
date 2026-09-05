defmodule DevilsDictionary.Lexicon do
  @moduledoc """
  Words. Schemas and queries for `lexemes` (lang · lemma · pos, the full English
  index), `senses`, `entries`, `lexical_relations`, `scopes` and `scope_lexemes`.
  Dictionaries attach here. Spec: issue #69 §4.
  """

  import Ecto.Query, warn: false

  alias DevilsDictionary.Lexicon.{Lexeme, Scope, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo

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
