defmodule DevilsDictionary.Discovery.ConceptHopTest do
  @moduledoc """
  The concept hop's walk (#172 build A), over hand-written nodes in the shape
  `WikidataClient.hop_nodes/3` makes. The QIDs are real where the shape is
  (*coward* → *cowardice*) and fixture values elsewhere.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Clients.Wikidata, as: WikidataClient
  alias DevilsDictionary.Discovery.ConceptHop

  defp item(title, claims \\ %{}), do: %{"title" => title, "claims" => claims}

  # A fetch over a fixed graph that reports each batch it is asked for.
  defp fetch(graph) do
    test = self()

    fn qids ->
      send(test, {:fetched, qids})
      {:ok, Map.take(graph, qids)}
    end
  end

  defp fetched do
    receive do
      {:fetched, qids} -> [qids | fetched()]
    after
      0 -> []
    end
  end

  describe "one step" do
    test "coward has as its characteristic cowardice, whose page is Cowardice" do
      origins = %{"Q104605901" => item(nil, %{"P1552" => ["Q1401607"], "P279" => ["Q215627"]})}
      graph = %{"Q1401607" => item("Cowardice"), "Q215627" => item(nil)}

      assert {:ok, %{"Q104605901" => hit}} =
               ConceptHop.reach(["Q104605901"], origins, fetch(graph))

      assert hit == %{
               "qid" => "Q1401607",
               "title" => "Cowardice",
               "via" => [%{"property" => "P1552", "qid" => "Q1401607"}]
             }

      # One request for the whole step, whatever it reached.
      assert fetched() == [["Q1401607", "Q215627"]]
    end

    test "the properties are tried in the rule's order" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"], "P1552" => ["Q3"]})}
      graph = %{"Q2" => item("Broader"), "Q3" => item("Quality")}

      assert {:ok, %{"Q1" => %{"title" => "Quality"}}} =
               ConceptHop.reach(["Q1"], origins, fetch(graph))

      rule = %{"properties" => ["P279", "P1552"], "max_steps" => 2}

      assert {:ok, %{"Q1" => %{"title" => "Broader"}}} =
               ConceptHop.reach(["Q1"], origins, fetch(graph), rule: rule)
    end
  end

  describe "at most two steps" do
    # world war → war, one step further: Q1 ⊂ Q2 ⊂ Q3, and only Q3 has a page.
    test "a two-step hop resolves, with both steps on its path" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"]})}
      graph = %{"Q2" => item(nil, %{"P279" => ["Q3"]}), "Q3" => item("War")}

      assert {:ok, %{"Q1" => hit}} = ConceptHop.reach(["Q1"], origins, fetch(graph))
      assert hit["title"] == "War"

      assert hit["via"] == [
               %{"property" => "P279", "qid" => "Q2"},
               %{"property" => "P279", "qid" => "Q3"}
             ]

      assert ConceptHop.reached(hit["via"]) == ["P279", "P279"]
      assert fetched() == [["Q2"], ["Q3"]]
    end

    test "a third step is refused, and never fetched" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"]})}

      graph = %{
        "Q2" => item(nil, %{"P279" => ["Q3"]}),
        "Q3" => item(nil, %{"P279" => ["Q4"]}),
        "Q4" => item("Too far")
      }

      assert {:ok, hits} = ConceptHop.reach(["Q1"], origins, fetch(graph))
      assert hits == %{}
      # Two steps, two requests; Q4 is never asked for.
      assert fetched() == [["Q2"], ["Q3"]]
    end
  end

  describe "never onto a person or a work" do
    test "a hop to a human is refused, even with a page, and not walked through" do
      origins = %{"Q1" => item(nil, %{"P1552" => ["Q9068"]})}

      graph = %{
        # Voltaire has an author page, and is a human.
        "Q9068" => item("Voltaire", %{"P31" => ["Q5"], "P279" => ["Q7"]}),
        "Q7" => item("Past him")
      }

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(graph))
      assert fetched() == [["Q9068"]]
    end

    test "a hop to a creative work is refused" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"]})}
      graph = %{"Q2" => item("A novel", %{"P31" => ["Q7725634"]})}

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(graph))
    end

    test "an origin that is itself a person does not hop" do
      origins = %{"Q1" => item(nil, %{"P31" => ["Q5"], "P1552" => ["Q2"]})}

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(%{"Q2" => item("Q")}))
      assert fetched() == []
    end
  end

  describe "instance of" do
    test "lands only on a class" do
      origins = %{"Q1" => item(nil, %{"P31" => ["Q2", "Q3"]})}
      # Q2 is an individual (no P279); Q3 is a class.
      graph = %{"Q2" => item("Individual"), "Q3" => item("Cities", %{"P279" => ["Q4"]})}

      assert {:ok, %{"Q1" => %{"title" => "Cities"}}} =
               ConceptHop.reach(["Q1"], origins, fetch(graph))
    end

    test "is read only off an instance: a class's P31 is a metaclass" do
      # luthier ⊂ craftsperson, and luthier ∈ profession: the profession is
      # not what luthier means.
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"], "P31" => ["Q28640"]})}
      graph = %{"Q2" => item(nil), "Q28640" => item("Profession", %{"P279" => ["Q12737077"]})}

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(graph))
      assert fetched() == [["Q2"]]
    end

    test "ends a path: nothing is walked on from the class it reached" do
      # witch doctor ∈ occupation, occupation has characteristic labor.
      origins = %{"Q1" => item(nil, %{"P31" => ["Q2"]})}
      graph = %{"Q2" => item(nil, %{"P279" => ["Q3"], "P1552" => ["Q4"]}), "Q4" => item("Labor")}

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(graph))
      assert fetched() == [["Q2"]]
    end
  end

  describe "the walk" do
    test ":first stops at the first step that reaches any page" do
      origins = %{
        "Q1" => item(nil, %{"P279" => ["Q10"]}),
        "Q2" => item(nil, %{"P279" => ["Q20"]})
      }

      graph = %{
        "Q10" => item(nil, %{"P279" => ["Q11"]}),
        "Q11" => item("Far"),
        "Q20" => item("Near")
      }

      assert {:ok, hits} = ConceptHop.reach(["Q1", "Q2"], origins, fetch(graph), first: true)
      assert Map.keys(hits) == ["Q2"]
      assert fetched() == [["Q10", "Q20"]]

      # Without it, each origin walks to its own page.
      assert {:ok, %{"Q1" => %{"title" => "Far"}, "Q2" => %{"title" => "Near"}}} =
               ConceptHop.reach(["Q1", "Q2"], origins, fetch(graph))
    end

    test ":max_per_step caps what one step fetches" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2", "Q3", "Q4"]})}
      graph = %{"Q2" => item(nil), "Q3" => item(nil), "Q4" => item("Cut")}

      assert {:ok, %{}} = ConceptHop.reach(["Q1"], origins, fetch(graph), max_per_step: 2)
      assert [["Q2", "Q3"] | _] = fetched()
    end

    test "a fetch that defers is returned as it is" do
      origins = %{"Q1" => item(nil, %{"P279" => ["Q2"]})}
      deferred = {:deferred, "provider_retry_after", 60}

      assert ^deferred = ConceptHop.reach(["Q1"], origins, fn _qids -> deferred end)
    end
  end

  describe "the rule is data (C3)" do
    test "the list, its wording and the recipe's fingerprint" do
      assert ConceptHop.properties() == ~w(P1552 P279 P1269 P31)
      assert ConceptHop.wording("P1552") == "has as its characteristic"
      assert Enum.all?(ConceptHop.properties(), &is_binary(ConceptHop.wording(&1)))
      assert ConceptHop.wording("P50") == nil

      rule = ConceptHop.rule()
      assert ConceptHop.valid_rule?(rule)
      refute ConceptHop.valid_rule?(%{rule | "max_steps" => 3})
      refute ConceptHop.valid_rule?(%{rule | "properties" => ["P50"]})

      fingerprint = ConceptHop.fingerprint(rule)
      assert fingerprint == ConceptHop.fingerprint(ConceptHop.rule())
      refute fingerprint == ConceptHop.fingerprint(%{rule | "max_steps" => 1})
      refute fingerprint == ConceptHop.fingerprint(%{rule | "properties" => ~w(P1552 P279 P1269)})
      assert ConceptHop.fingerprint(nil) == nil
    end

    test "origins are concepts and events" do
      assert ConceptHop.origin?(:concept) and ConceptHop.origin?("event")
      refute ConceptHop.origin?(:person) or ConceptHop.origin?("work")
      refute ConceptHop.origin?(:taxon) or ConceptHop.origin?(nil)
    end
  end

  describe "WikidataClient.hop_nodes/3" do
    test "keeps the sitelink and the listed properties' item ids, and nothing else" do
      body = %{
        "entities" => %{
          "Q104605901" => %{
            "id" => "Q104605901",
            "sitelinks" => [],
            "claims" => %{
              "P1552" => [snak("P1552", "Q1401607")],
              "P18" => [%{"mainsnak" => %{"datavalue" => %{"value" => "Coward.jpg"}}}],
              "P279" => [snak("P279", "Q1", "deprecated"), snak("P279", "Q215627")]
            }
          },
          "Q1401607" => %{
            "id" => "Q1401607",
            "sitelinks" => %{"enwikiquote" => %{"title" => "Cowardice"}},
            "claims" => []
          },
          "Q404" => %{"id" => "Q404", "missing" => ""}
        }
      }

      assert WikidataClient.hop_nodes(body, "enwikiquote", ConceptHop.claim_properties()) == %{
               "Q104605901" => %{
                 "title" => nil,
                 "claims" => %{"P1552" => ["Q1401607"], "P279" => ["Q215627"]}
               },
               "Q1401607" => %{"title" => "Cowardice", "claims" => %{}}
             }

      assert WikidataClient.sitelink_params(["Q1"], "enwikiquote", claims: true)[:props] ==
               "sitelinks|claims"

      assert WikidataClient.sitelink_params(["Q1"], "enwikiquote")[:props] == "sitelinks"
    end
  end

  defp snak(property, id, rank \\ "normal"),
    do: %{
      "rank" => rank,
      "mainsnak" => %{
        "property" => property,
        "datavalue" => %{"type" => "wikibase-entityid", "value" => %{"id" => id}}
      }
    }
end
