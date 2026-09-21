defmodule DevilsDictionary.DemoTest do
  @moduledoc """
  Fake-data mode's own rules (#71 §2.8, U3).

  The point of the mode is that it is unmistakable and cannot escape. The three
  things worth testing are the three that would make it dangerous if they broke:
  a sample that claims to be a real source, a sample that reaches the scorecard,
  and a sample that renders in production.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Demo
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Sources.Catalog
  alias DevilsDictionary.Sources.OnDemand

  describe "the samples" do
    test "every word in the index gets a set, interpolated with its own lemma" do
      %{cards: cards, evidence: evidence} = Demo.samples("staurogram")

      # Two since #136 retired the 📱 one: Webster 1913 and EB1911, the two
      # layers still nobody has written a module for.
      assert length(cards) == 2
      assert evidence != []

      bodies = Enum.map_join(cards, " ", &rendered/1)
      assert bodies =~ "staurogram"
      assert bodies =~ "STAUROGRAM"
      refute bodies =~ "{{word}}"
    end

    test "a word with a set of its own gets that one" do
      assert Demo.samples("oyster") |> rendered() =~ "Ostreidae"
      assert Demo.samples("cat") |> rendered() =~ "Felis domestica"
    end

    test "every sample says on its face that it is invented" do
      for lemma <- ~w(oyster cat joy nonesuch) do
        assert Demo.samples(lemma) |> rendered() =~ "invented for layout"
      end
    end

    test "no sample source is a real one — Johnson especially, who is real since S5" do
      # Both registries, because #136 put real rows in a second one. A source
      # the catalog does not list is still a source, and a sample wearing its
      # name is still the lie this test exists to catch.
      real =
        (Catalog.sources() ++ OnDemand.source_catalog())
        |> Enum.map(& &1.slug)
        |> MapSet.new()

      sampled = MapSet.new(Demo.source_slugs())

      assert MapSet.disjoint?(real, sampled),
             "a sample impersonates #{inspect(MapSet.intersection(real, sampled))}"

      refute "johnson" in Demo.source_slugs()
      assert "urban-dictionary" in real, "the on-demand registry is in the disjointness check"

      # The 📱 sample retired in #136: the tier it stood in for is real now.
      assert Enum.sort(Demo.source_slugs()) == ~w(eb1911 webster1913)
      refute Enum.any?(Demo.source_slugs(), &(&1 =~ "urban"))
    end

    test "a sample card renders through the real card contract" do
      [card | _] = Demo.samples("oyster").cards

      # `Word.source_card/1` reads every one of these, and `WordPage`'s own
      # cards carry them. A key missing here is a template crash in dev only.
      for key <- ~w(id source tier year pos kind entries groups thumbnail_url url)a do
        assert Map.has_key?(card, key), "a sample card has no #{key}"
      end

      assert card.sample?
      assert String.starts_with?(card.id, "card-sample-")
      assert card.tier in [:aristocracy, :middle, :plebs]
      assert is_binary(card.url) and card.url != ""
    end

    test "a sample cites no record, so nothing counts it as provenance" do
      for card <- Demo.samples("oyster").cards do
        assert WordPage.card_record_ids(card) == []
      end
    end
  end

  describe "decorate/2" do
    test "samples sort in by tier and year without disturbing the real order" do
      page = %WordPage{
        headword: %{lemma: "oyster", lexemes: [%{id: 1}]},
        cards: [
          %{id: "card-johnson", tier: :aristocracy, year: 1755},
          %{id: "card-bierce", tier: :aristocracy, year: 1911},
          %{id: "card-wikipedia", tier: :middle, year: 2001},
          %{id: "card-wiktionary", tier: :middle, year: 2004}
        ]
      }

      ids =
        page |> Demo.decorate(Demo.samples("oyster")) |> Map.fetch!(:cards) |> Enum.map(& &1.id)

      # The real four keep their order exactly; the samples land by tier.
      assert Enum.filter(ids, &(not String.starts_with?(&1, "card-sample"))) ==
               ~w(card-johnson card-bierce card-wikipedia card-wiktionary)

      assert Enum.find_index(ids, &(&1 == "card-sample-eb1911")) >
               Enum.find_index(ids, &(&1 == "card-johnson"))

      # Both samples are 👑 since #136 retired the 📱 one, so the foot of the
      # page belongs to the real 📚 cards again and every sample sits among the
      # dead, where its tier puts it.
      assert List.last(ids) == "card-wiktionary"

      # Every sample is ahead of every real 📚 card, which is what "among the
      # dead" means once there is no 📱 sample to sit at the bottom.
      last_sample =
        ids
        |> Enum.with_index()
        |> Enum.filter(&String.starts_with?(elem(&1, 0), "card-sample"))
        |> List.last()
        |> elem(1)

      assert last_sample < Enum.find_index(ids, &(&1 == "card-wikipedia"))
    end

    test "a miss gets no samples: there is no layout to check on a page with no word" do
      miss = %WordPage{headword: %{lemma: nil, lexemes: []}, cards: []}

      assert Demo.decorate(miss, Demo.samples("zzz")).cards == []
    end
  end

  describe "the gate" do
    test "on? wants exactly 1, not any truthy-looking thing" do
      assert Demo.on?(%{"demo" => "1"})
      refute Demo.on?(%{"demo" => "true"})
      refute Demo.on?(%{"demo" => "0"})
      refute Demo.on?(%{})
      refute Demo.on?(nil)
    end
  end

  defp rendered(%{cards: cards}), do: Enum.map_join(cards, " ", &rendered/1)

  defp rendered(card) do
    senses = card.groups |> Enum.flat_map(& &1.senses) |> Enum.map_join(" ", & &1.gloss)
    entries = Enum.map_join(card.entries, " ", & &1.body_html)
    "#{card.id} #{entries} #{senses}"
  end
end
