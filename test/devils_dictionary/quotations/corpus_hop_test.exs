defmodule DevilsDictionary.Quotations.CorpusHopTest do
  @moduledoc """
  The corpus's reasons for a line built with the concept hop (#172 build A):
  a line found on *Cowardice* (reached from coward) and on *Voltaire* (his
  own page) folds to one row, and each concept's reason names the page that
  concept was found on — not the folded row's one `"page"` (CodeRabbit on
  #184).
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Corpus.Seeder
  alias DevilsDictionary.Discovery.MatchReason
  alias DevilsDictionary.Quotations.Corpus
  alias DevilsDictionary.QuotesCorpusFixtures

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes})
  end

  defp page!(ctx, lemma, entity_id) do
    word = word!(ctx, lemma, ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity_id, %{confidence: 0.95})
    word
  end

  test "coward's reason is the hop to Cowardice; Voltaire's is his own page", ctx do
    coward = concept!("Q104605901", "coward")
    manifest = QuotesCorpusFixtures.hop_manifest()
    [row] = Enum.filter(manifest["rows"], &("Q104605901" in &1["concept_qids"]))
    assert row["concept_pages"] == %{"Q104605901" => "Cowardice", "Q9068" => "Voltaire"}
    {:ok, _} = Seeder.run(manifest)

    coward_word = page!(ctx, "coward", coward.object_id)

    [item] =
      Corpus.shelf_items([coward_word.object_id])
      |> Enum.filter(&(&1.external_id == row["fingerprint"]))

    by_from =
      Map.new(item.match_details["sitelinks"], &{&1["from"] || &1["qid"], &1})

    assert %{"qid" => "Q1401607", "title" => "Cowardice", "reached" => ["P1552"]} =
             by_from["Q104605901"]

    assert %{"qid" => "Q9068", "title" => "Voltaire"} = by_from["Q9068"]

    sentences =
      item.match_details
      |> Map.put("query", "coward")
      |> MatchReason.from_result("coward")
      |> Enum.map(&MatchReason.describe/1)

    assert ("From Wikiquote's page “Cowardice”, the concept a sense of “coward” has as its " <>
              "characteristic (Q1401607).") in sentences

    assert ("From Wikiquote's page “Voltaire”, the page of the concept this meaning refers to " <>
              "(Q9068).") in sentences

    refute Enum.any?(sentences, &(&1 =~ "“Cowardice”, the page of the concept"))
  end
end
