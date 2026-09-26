defmodule DevilsDictionary.Curation.LeadPolicy do
  @moduledoc """
  Who may lead a curated opening. An editorial rule, written down once (#156,
  #193): **an applicable *Devil's Dictionary* entry by Ambrose Bierce leads.**
  It is not a preference a selection can outweigh, a persona can argue with or
  a panel can vote on.

    * Where the page carries a Bierce entry, only that entry may lead. A
      selection naming any other lead is refused
      (`:priority_source_available`), and a selection naming no lead is
      reported (`:priority_source_missing`). Neither is quietly corrected: a
      reader withholds, it never substitutes.
    * Where it does not, a person may choose another sourced definition from
      the page (`:manual_fallback`), or leave the lead empty. What the automatic
      fallback order should be is still an open product decision, so there is
      none here.
    * A lead is always an entry this page already shows. That is what makes
      *read the whole entry* a link to the card rather than a promise.

  This module is the one place the opening names a source. The component
  branches on the lead's `policy`, never on a slug.
  """

  @priority_source "bierce"

  @doc "The slug of the source whose applicable entry always leads."
  def priority_source, do: @priority_source

  @doc """
  The priority source's entries on this page, as `%{content_id, card_id}`.
  Sample cards (`?demo=1`) carry no content id and never count.
  """
  def applicable(page) do
    for card <- page.cards,
        card.source.slug == @priority_source,
        entry <- card.entries,
        id = Map.get(entry, :content_id),
        not is_nil(id),
        do: %{content_id: id, card_id: card.id}
  end

  @doc """
  The card and entry on this page that hold content object `content_id`, as
  `{card, entry}`, or `nil`.
  """
  def page_entry(page, content_id) do
    Enum.find_value(page.cards, fn card ->
      case Enum.find(card.entries, &(Map.get(&1, :content_id) == content_id)) do
        nil -> nil
        entry -> {card, entry}
      end
    end)
  end

  @doc """
  Whether content object `content_id` may lead this page, and under which
  rule: `{:ok, :priority_source}`, `{:ok, :manual_fallback}`, or
  `{:error, :not_on_page | :priority_source_available}`.
  """
  def check(page, content_id) do
    applicable = applicable(page)

    cond do
      is_nil(page_entry(page, content_id)) -> {:error, :not_on_page}
      Enum.any?(applicable, &(&1.content_id == content_id)) -> {:ok, :priority_source}
      applicable != [] -> {:error, :priority_source_available}
      true -> {:ok, :manual_fallback}
    end
  end

  @doc """
  What a selection with **no** lead means on this page: `:ok` where nothing
  applicable exists, `{:error, :priority_source_missing}` where a Bierce
  entry does and was left out.
  """
  def check_empty(page) do
    if applicable(page) == [], do: :ok, else: {:error, :priority_source_missing}
  end

  @doc "The rule a lead was admitted under, as the page states it to a reader."
  def statement(:priority_source),
    do: "Bierce first: where The Devil’s Dictionary defines a word, its entry leads."

  def statement(:manual_fallback),
    do:
      "The Devil’s Dictionary has no entry for this word, so another sourced definition was selected by hand."
end
