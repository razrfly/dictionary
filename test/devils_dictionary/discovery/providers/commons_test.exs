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

  describe "text/2 and the title — extmetadata is HTML" do
    test "hidden QuickStatements blocks and tags go, entities are decoded" do
      metadata = %{
        "DateTimeOriginal" => %{
          "value" =>
            ~s(1887<div style="display: none;">date QS:P571,+1887-00-00T00:00:00Z/9</div>)
        },
        "Artist" => %{
          "value" =>
            ~s(<bdi><a href="/wiki/Thure">Thure de Thulstrup</a></bdi> &amp; <span style="display:none">hidden</span>co)
        }
      }

      assert Commons.text(metadata, "DateTimeOriginal") == "1887"
      assert Commons.text(metadata, "Artist") == "Thure de Thulstrup & co"
      assert Commons.text(metadata, "Missing") == ""
    end

    test "a multi-language title block yields its English element; a description-sized one the file name" do
      # The shape measured on File:David - Napoleon crossing the Alps - Malmaison1.jpg.
      napoleon_name =
        ~s(<div class="fn">\n<div style="font-size:0.9em;display:inline-block;">French:  <div style="display:inline-block" dir="ltr" lang="fr"><i>Bonaparte franchissant les Alpes au Grand-Saint-Bernard&nbsp;<span class="noprint"><a href="https://www.wikidata.org/wiki/Q19801071#P1476"><img alt="Edit this at Wikidata" src="x"></a></span></i></div></div><br>) <>
          ~s(<div style="font-weight:bold;display:inline-block;"><div style="display:inline-block" dir="ltr" lang="en"><i>Napoleon Crossing the Alps</i></div></div>) <>
          ~s(<div style="display: none;">title QS:P1476,fr:"Bonaparte franchissant les Alpes au Grand-Saint-Bernard"</div>) <>
          ~s(<div style="display: none;">label QS:Len,"Napoleon Crossing the Alps"</div></div>)

      description_name =
        ~s(Second World War: Europe; "<a href="https://en.wikipedia.org/wiki/Into_the_Jaws_of_Death" class="extiw">Into the Jaws of Death</a> — U.S. Troops wading through water and Nazi gunfire”, <i>circa</i> 1944-06-06.)

      gettysburg_name =
        ~s(<div class="fn"><div style="font-weight:bold;display:inline-block;">Battle of Gettysburg</div></div>)

      with_name = fn pageid, title, name ->
        page(pageid, "pd", "Public domain")
        |> put_in(["imageinfo", Access.at(0), "extmetadata", "ObjectName"], %{"value" => name})
        |> Map.put("title", title)
      end

      request_fun = fn
        "search", _payload ->
          {:ok,
           %{
             "batchcomplete" => true,
             "query" => %{
               "pages" => [
                 with_name.(
                   1008,
                   "File:David_-_Napoleon_crossing_the_Alps_-_Malmaison1.jpg",
                   napoleon_name
                 ),
                 with_name.(
                   1009,
                   "File:Into the Jaws of Death 23-0455M edit.jpg",
                   description_name
                 ),
                 with_name.(
                   1010,
                   "File:Thure de Thulstrup - Battle of Gettysburg.jpg",
                   gettysburg_name
                 )
               ]
             }
           }}

        "entities", _payload ->
          {:ok, %{"entities" => Map.new(~w(M1008 M1009 M1010), &{&1, entity(["Q4991371"])})}}
      end

      assert {:ok, %{items: [napoleon, jaws, gettysburg]}} =
               Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun)

      assert napoleon.preview_metadata["title"] == "Napoleon Crossing the Alps"
      assert jaws.preview_metadata["title"] == "Into the Jaws of Death 23-0455M edit"
      assert gettysburg.preview_metadata["title"] == "Battle of Gettysburg"
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
      # MediaWiki reports `lag` as a float, but a whole number of seconds
      # arrives as an integer; both defer, never below the 5 s Retry-After.
      for {lag, seconds} <- [{7.2, 8}, {7, 7}, {0.445, 5}, {3, 5}] do
        request_fun = fn "search", _payload ->
          {:ok, %{"error" => %{"code" => "maxlag", "lag" => lag, "info" => "Waiting"}}}
        end

        assert {:deferred, "maxlag", ^seconds, %{"first" => 3}} =
                 Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun),
               "lag #{inspect(lag)} did not defer for #{seconds} s"
      end
    end

    test "the uploader is requested, and is the author when the file names no Artist" do
      parent = self()

      request_fun = fn
        "search", %{"params" => params} ->
          send(parent, {:search, params})

          bare =
            update_in(
              page(1011, "cc-by-4.0", "CC BY 4.0"),
              ["imageinfo", Access.at(0), "extmetadata"],
              &Map.delete(&1, "Artist")
            )

          {:ok, %{"batchcomplete" => true, "query" => %{"pages" => [bare]}}}

        "entities", _payload ->
          {:ok, %{"entities" => %{"M1011" => entity(["Q4991371"])}}}
      end

      assert {:ok, %{items: [item]}} =
               Commons.retrieve(@operation, @mapping, %{"first" => 3}, request_fun)

      assert item.preview_metadata["author"] == "Fixture"
      assert item.preview_metadata["artist"] == "Fixture · CC BY 4.0"

      assert_received {:search, params}
      assert "user" in String.split(params["iiprop"], "|")
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
