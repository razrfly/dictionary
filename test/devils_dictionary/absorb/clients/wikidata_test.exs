defmodule DevilsDictionary.Absorb.Clients.WikidataTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Absorb.Clients.Wikidata
  alias DevilsDictionary.Fixtures

  defp stub(body), do: Req.Test.stub(Clients, fn conn -> Req.Test.json(conn, body) end)

  defp cat, do: Fixtures.raw("wikidata", "cat") |> Enum.find(&(&1["id"] == "Q146"))

  test "a QID Wikidata does not know is simply absent from the map" do
    stub(%{
      "entities" => %{
        "Q146" => %{"id" => "Q146", "labels" => %{}},
        "Q99999999999" => %{"id" => "Q99999999999", "missing" => ""}
      }
    })

    assert {:ok, entities} = Wikidata.fetch(["Q146", "Q99999999999"], rate_limit_ms: 0)
    assert Map.keys(entities) == ["Q146"]
  end

  test "fetch_one is not_found rather than an empty success" do
    stub(%{"entities" => %{"Q1" => %{"id" => "Q1", "missing" => ""}}})
    assert {:error, :not_found} = Wikidata.fetch_one("Q1", rate_limit_ms: 0)
  end

  test "an empty request costs no call at all" do
    Req.Test.stub(Clients, fn _conn -> raise "should not be called" end)
    assert {:ok, %{}} = Wikidata.fetch([])
  end

  test "the batch limit is the API's, and it is 50" do
    assert Wikidata.batch_size() == 50
  end

  describe "claim readers" do
    test "entity_ids skips a statement with no value" do
      entity = %{
        "claims" => %{
          "P171" => [
            %{"mainsnak" => %{"snaktype" => "novalue"}},
            %{"mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q228283"}}}}
          ]
        }
      }

      assert Wikidata.entity_ids(entity, "P171") == ["Q228283"]
    end

    test "strings reads plain values and monolingual text, filtered by language" do
      assert Wikidata.string(cat(), "P8814") == "02124460-n"
      assert Wikidata.string(cat(), "P5063") == "i46593"

      felis = Fixtures.raw("wikidata", "cat") |> Enum.find(&(&1["id"] == "Q20980826"))
      names = Wikidata.strings(felis, "P1843", "en")
      assert "cat" in names
      refute "kissa" in names
    end

    test "an unknown property is empty, not a crash" do
      assert Wikidata.entity_ids(cat(), "P999999") == []
      assert Wikidata.string(cat(), "P999999") == nil
    end
  end
end
