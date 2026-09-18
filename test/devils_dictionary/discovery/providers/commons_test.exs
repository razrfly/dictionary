defmodule DevilsDictionary.Discovery.Providers.CommonsTest do
  @moduledoc """
  The parts of the Commons provider the conformance suite cannot see from the
  outside: the licence gate, the statements gate, the lag refusal that arrives
  as a 200, and the cursor's round trip through MediaWiki's `continue` object.
  Everything else is `DevilsDictionary.Discovery.Conformance`'s.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Providers.Commons

  @operation "depicts_qid_discovery"
  @mapping %{
    "term" => "soldier",
    "language" => "en",
    "relevance" => "term",
    "resolution_strategy" => "depicts_qid_v1",
    "entities" => [%{"qid" => "Q4991371", "label" => "soldier"}]
  }

  describe "licence/1 — read from the hydrated file, never from the query" do
    test "keeps CC0, CC BY, CC BY-SA and public-domain codes" do
      for {code, short} <- [
            {"pd", "Public domain"},
            {"cc0", "CC0"},
            {"cc-by-4.0", "CC BY 4.0"},
            {"cc-by-2.0", "CC BY 2.0"},
            {"cc-by-sa-3.0", "CC BY-SA 3.0"},
            {"cc-by-sa-4.0", "CC BY-SA 4.0"}
          ] do
        assert {:ok, ^short} = Commons.licence(metadata(code, short))
      end
    end

    test "refuses everything else, including Commons's own Attribution template" do
      for {code, short} <- [
            {nil, "Attribution"},
            {"gfdl", "GFDL"},
            {"cc-by-nc-sa-3.0", "CC BY-NC-SA 3.0"},
            {"cc-by-nd-4.0", "CC BY-ND 4.0"},
            {"cc-by-nc-2.0", "CC BY-NC 2.0"},
            {nil, nil}
          ] do
        assert :error = Commons.licence(metadata(code, short)),
               "#{inspect({code, short})} was admitted"
      end
    end

    test "falls back to the short name when the code is absent" do
      assert {:ok, "Public domain"} = Commons.licence(metadata(nil, "Public domain"))
      assert {:ok, "CC BY-SA 4.0"} = Commons.licence(metadata(nil, "CC BY-SA 4.0"))
      assert {:ok, "CC BY 3.0"} = Commons.licence(metadata(nil, "CC BY 3.0"))
    end
  end

  describe "depicted/2 — the statements dispose" do
    test "keeps the QIDs in the page's index and nothing else" do
      entity = %{
        "statements" => %{
          "P180" => [
            snak("Q4991371"),
            snak("Q11446"),
            %{"mainsnak" => %{"snaktype" => "somevalue"}}
          ]
        }
      }

      assert [%{"qid" => "Q4991371", "entity_label" => "soldier", "relation" => "exact"}] =
               Commons.depicted(entity, %{"Q4991371" => %{"label" => "soldier"}})
    end

    test "an entity with no statements, or none at all, names nothing" do
      assert [] = Commons.depicted(%{"id" => "M1", "type" => "mediainfo"}, %{"Q1" => %{}})
      assert [] = Commons.depicted(nil, %{"Q1" => %{}})
    end
  end

  describe "retrieve/4" do
    test "a lag refusal is a 200 with an error body, and the run is deferred" do
      request_fun = fn "search", _payload ->
        {:ok, %{"error" => %{"code" => "maxlag", "lag" => 7.2, "info" => "Waiting"}}}
      end

      assert {:deferred, "maxlag", 8, %{"first" => 3}} =
               Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun)
    end

    test "sends maxlag, the OR'd QIDs and the page size, and hands back MediaWiki's continue" do
      parent = self()

      request_fun = fn
        "search", %{"endpoint" => "search", "params" => params} ->
          send(parent, {:search, params})

          {:ok,
           %{
             "batchcomplete" => true,
             "continue" => %{"gsroffset" => 3, "continue" => "gsroffset||"},
             "query" => %{"pages" => [page(1001, "pd", "Public domain")]}
           }}

        "entities", %{"endpoint" => "entities", "ids" => ids} ->
          send(parent, {:entities, ids})
          {:ok, %{"entities" => %{"M1001" => entity(["Q4991371"])}}}
      end

      mapping =
        put_in(@mapping["entities"], [
          %{"qid" => "Q4991371", "label" => "soldier"},
          %{"qid" => "Q198", "label" => "War"}
        ])

      assert {:ok, page} = Commons.retrieve(@operation, mapping, %{"first" => 3}, request_fun)
      assert page.next_cursor == ~s({"continue":"gsroffset||","gsroffset":3})
      assert page.completion_reason == :results
      assert [%{external_namespace: "commons_file", external_id: "1001"} = item] = page.items

      assert item.match_details == %{
               "kind" => "depiction",
               "depicts" => [
                 %{
                   "qid" => "Q4991371",
                   "relation" => "exact",
                   "entity_qid" => "Q4991371",
                   "entity_label" => "soldier"
                 }
               ]
             }

      assert item.preview_metadata["artist"] == "Fixture · Public domain"
      assert item.preview_metadata["license"] == "Public domain"
      assert item.preview_metadata["year"] == "1916"
      assert item.preview_metadata["content_type"] == "image"

      assert_received {:search, params}
      assert params["gsrsearch"] == "haswbstatement:P180=Q4991371|P180=Q198 filetype:bitmap"
      assert params["gsrlimit"] == "3"
      refute Map.has_key?(params, "gsroffset")
      assert_received {:entities, "M1001"}

      [method: :get, url: _, params: sent, headers: _] =
        Commons.request_options(%{"endpoint" => "search", "params" => params})

      assert sent["maxlag"] == "5"
      assert sent["format"] == "json"
    end

    test "a handed-back cursor becomes the continue parameters of the next search" do
      parent = self()

      request_fun = fn
        "search", %{"params" => params} ->
          send(parent, {:search, params})
          {:ok, %{"batchcomplete" => true}}
      end

      cursor = ~s({"continue":"gsroffset||","gsroffset":3})

      assert {:ok, %{items: [], next_cursor: nil, completion_reason: :no_results}} =
               Commons.retrieve(
                 @operation,
                 @mapping,
                 %{"first" => 3, "after" => cursor},
                 request_fun
               )

      assert_received {:search, %{"gsroffset" => "3", "continue" => "gsroffset||"}}
    end

    test "a cursor this provider never issued is refused" do
      request_fun = fn _stage, _payload -> flunk("no request should be made") end

      assert {:error, "malformed_cursor"} =
               Commons.retrieve(
                 @operation,
                 @mapping,
                 %{"first" => 3, "after" => "not-json"},
                 request_fun
               )

      assert {:error, "malformed_cursor"} =
               Commons.retrieve(
                 @operation,
                 @mapping,
                 %{"first" => 3, "after" => ~s({"iistart":"x"})},
                 request_fun
               )
    end

    test "a window with nothing displayable spends no entities request" do
      request_fun = fn
        "search", _payload ->
          {:ok,
           %{"batchcomplete" => true, "query" => %{"pages" => [page(1003, nil, "Attribution")]}}}

        "entities", _payload ->
          flunk("nothing displayable, nothing to hydrate")
      end

      assert {:ok, %{items: [], completion_reason: :no_results}} =
               Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun)
    end

    test "a video that depicts the QID is not an image" do
      request_fun = fn
        "search", _payload ->
          video =
            put_in(
              page(1007, "cc-by-sa-4.0", "CC BY-SA 4.0"),
              ["imageinfo", Access.at(0), "mime"],
              "video/webm"
            )

          {:ok, %{"batchcomplete" => true, "query" => %{"pages" => [video]}}}
      end

      assert {:ok, %{items: []}} =
               Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun)
    end
  end

  defp metadata(code, short) do
    %{}
    |> then(&if(code, do: Map.put(&1, "License", %{"value" => code}), else: &1))
    |> then(&if(short, do: Map.put(&1, "LicenseShortName", %{"value" => short}), else: &1))
  end

  defp snak(qid) do
    %{"mainsnak" => %{"snaktype" => "value", "datavalue" => %{"value" => %{"id" => qid}}}}
  end

  defp entity(qids),
    do: %{
      "id" => "M",
      "type" => "mediainfo",
      "statements" => %{"P180" => Enum.map(qids, &snak/1)}
    }

  defp page(pageid, code, short) do
    %{
      "pageid" => pageid,
      "ns" => 6,
      "title" => "File:Fixture #{pageid}.jpg",
      "imageinfo" => [
        %{
          "mime" => "image/jpeg",
          "user" => "Fixture",
          "thumburl" => "https://thumb.commons.test/#{pageid}/640px.jpg",
          "descriptionurl" => "https://commons.test/wiki/File:Fixture_#{pageid}.jpg",
          "extmetadata" =>
            metadata(code, short)
            |> Map.put("Artist", %{"value" => ~s(<a href="/wiki/User:Fixture">Fixture</a>)})
            |> Map.put("DateTimeOriginal", %{
              "value" => ~s(1916-07-01<div style="display:none">date QS:P571</div>)
            })
        }
      ]
    }
  end
end
