defmodule DevilsDictionary.Curation.LeadPolicyTest do
  @moduledoc """
  Bierce first (#156, #193): where the page carries an applicable Devil's
  Dictionary entry, only that entry may lead, and nothing else can outrank it.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.LeadPolicy

  defp card(slug, id, content_ids) do
    %{
      id: id,
      source: %{slug: slug},
      entries: Enum.map(content_ids, &%{content_id: &1}),
      groups: []
    }
  end

  defp page(cards), do: %{cards: cards}

  test "Bierce's entry leads under the priority rule" do
    page = page([card("johnson", "card-johnson", [10]), card("bierce", "card-bierce", [20])])

    assert LeadPolicy.check(page, 20) == {:ok, :priority_source}
    assert LeadPolicy.applicable(page) == [%{content_id: 20, card_id: "card-bierce"}]
  end

  test "no other entry may lead while an applicable Bierce entry is on the page" do
    page = page([card("johnson", "card-johnson", [10]), card("bierce", "card-bierce", [20])])

    assert LeadPolicy.check(page, 10) == {:error, :priority_source_available}
    assert LeadPolicy.check_empty(page) == {:error, :priority_source_missing}
  end

  test "without Bierce, another entry on the page may lead as a manual fallback" do
    page = page([card("johnson", "card-johnson", [10])])

    assert LeadPolicy.check(page, 10) == {:ok, :manual_fallback}
    assert LeadPolicy.check_empty(page) == :ok
  end

  test "a lead is always an entry this page shows" do
    page = page([card("johnson", "card-johnson", [10])])

    assert LeadPolicy.check(page, 99) == {:error, :not_on_page}
    assert LeadPolicy.page_entry(page, 10) |> elem(0) |> Map.get(:id) == "card-johnson"
  end

  test "a sample card carries no content id and never counts as applicable" do
    sample = %{id: "card-sample-webster", source: %{slug: "bierce"}, entries: [%{}], groups: []}

    assert LeadPolicy.applicable(page([sample])) == []
  end

  test "the rule a reader sees names the priority, and the fallback says what it is" do
    # A preference about voice, and it says it is not a claim of truth.
    assert LeadPolicy.statement(:priority_source) =~ "Editorial preference"

    assert LeadPolicy.statement(:priority_source) =~
             "not a claim that the entry is literally true"

    assert LeadPolicy.statement(:manual_fallback) =~ "no entry for this word"
  end

  test "the priority source's lead is satire; a fallback is a sourced definition" do
    assert LeadPolicy.register(:priority_source) == :satire
    assert LeadPolicy.register(:manual_fallback) == :definition
  end
end
