defmodule DevilsDictionary.Artworks.Corpus.BuildersTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Artworks.Corpus.{MetHighlights, WikidataFamous}

  defp response(body), do: {:ok, %Req.Response{status: 200, body: body}}

  defp met_object(id, attrs) do
    Map.merge(
      %{
        "objectID" => id,
        "title" => "Object #{id}",
        "isPublicDomain" => true,
        "primaryImageSmall" => "https://images.example.test/#{id}.jpg",
        "creditLine" => "Fixture bequest, 1900",
        "objectDate" => "ca. 1780",
        "artistDisplayName" => "Fixture Painter",
        "objectURL" => "https://www.metmuseum.org/art/collection/search/#{id}",
        "tags" => [
          %{"term" => "Soldiers", "Wikidata_URL" => "https://www.wikidata.org/wiki/Q4991371"}
        ]
      },
      attrs
    )
  end

  describe "met-highlights" do
    test "pages the id list, gates on the hydrated object and never asks for image bytes" do
      {:ok, requests} = Agent.start_link(fn -> [] end)

      request_fun = fn options ->
        url = Keyword.fetch!(options, :url)
        Agent.update(requests, &[url | &1])

        cond do
          String.contains?(url, "/search") ->
            case options |> Keyword.fetch!(:params) |> Map.fetch!("offset") do
              "0" -> response(%{"total" => 3, "objectIDs" => [11, 12]})
              _ -> response(%{"total" => 3, "objectIDs" => [13]})
            end

          String.ends_with?(url, "/11") ->
            response(met_object(11, %{}))

          String.ends_with?(url, "/12") ->
            # A highlight that is not public domain: the search cannot exclude it,
            # so the hydrated object has to.
            response(met_object(12, %{"isPublicDomain" => false, "primaryImageSmall" => ""}))

          String.ends_with?(url, "/13") ->
            response(
              met_object(13, %{
                "objectWikidata_URL" => "https://www.wikidata.org/wiki/Q90000",
                "tags" => nil
              })
            )
        end
      end

      assert {:ok, manifest, ledger} =
               MetHighlights.build(
                 request_fun: request_fun,
                 interval_ms: 0,
                 progress: progress_path()
               )

      assert Enum.map(manifest["rows"], & &1["met_object_id"]) == ["11", "13"]
      assert ledger.hydrated == 3
      assert ledger.public_domain_kept == 2
      assert ledger.not_public_domain == 1
      assert ledger.met_requests == 5
      assert ledger.search_requests == 2
      assert ledger.image_bytes_downloaded == 0

      [kept, without_tags] = manifest["rows"]
      assert kept["tags"] == [%{"term" => "Soldiers", "qid" => "Q4991371"}]
      assert kept["credit_line"] == "Fixture bequest, 1900"
      assert kept["image_url"] == "https://images.example.test/11.jpg"
      assert without_tags["qid"] == "Q90000"
      assert without_tags["tags"] == []

      urls = Agent.get(requests, & &1)
      assert Enum.all?(urls, &String.starts_with?(&1, "https://collectionapi.metmuseum.org/"))
      refute Enum.any?(urls, &String.contains?(&1, "images.example.test"))
    end

    test "a refused object is retried on the Met's own floor and then counted" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      request_fun = fn options ->
        url = Keyword.fetch!(options, :url)

        if String.contains?(url, "/search") do
          case options |> Keyword.fetch!(:params) |> Map.fetch!("offset") do
            "0" -> response(%{"total" => 1, "objectIDs" => [21]})
            _ -> response(%{"total" => 1, "objectIDs" => []})
          end
        else
          count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          if count < 3,
            do: {:ok, %Req.Response{status: 403, body: ""}},
            else: response(met_object(21, %{}))
        end
      end

      assert {:ok, manifest, ledger} =
               MetHighlights.build(
                 request_fun: request_fun,
                 interval_ms: 0,
                 progress: progress_path()
               )

      assert Enum.map(manifest["rows"], & &1["met_object_id"]) == ["21"]
      assert ledger.retries == 2
      assert ledger.refused_403 == 2
      assert ledger.failed == 0
    end

    test "a hydration already in the progress file costs no request" do
      path = progress_path()

      File.write!(
        path,
        Jason.encode!(%{
          "met_object_id" => "31",
          "public_domain" => true,
          "title" => "Cached highlight",
          "tags" => [],
          "image_url" => "https://images.example.test/31.jpg"
        }) <> "\n"
      )

      request_fun = fn options ->
        url = Keyword.fetch!(options, :url)
        assert String.contains?(url, "/search"), "a cached object must not be re-hydrated"

        case options |> Keyword.fetch!(:params) |> Map.fetch!("offset") do
          "0" -> response(%{"total" => 1, "objectIDs" => [31]})
          _ -> response(%{"total" => 1, "objectIDs" => []})
        end
      end

      assert {:ok, manifest, ledger} =
               MetHighlights.build(request_fun: request_fun, interval_ms: 0, progress: path)

      assert Enum.map(manifest["rows"], & &1["title"]) == ["Cached highlight"]
      assert ledger.hydrations == 0
    end
  end

  describe "wikidata-famous" do
    defp binding(qid, sitelinks, file) do
      %{
        "item" => %{"value" => "http://www.wikidata.org/entity/#{qid}"},
        "sitelinks" => %{"value" => Integer.to_string(sitelinks)},
        "image" => %{"value" => "http://commons.wikimedia.org/wiki/Special:FilePath/#{file}"}
      }
    end

    defp described(qid, label, creators, depicts) do
      %{
        "item" => %{"value" => "http://www.wikidata.org/entity/#{qid}"},
        "label" => %{"value" => label},
        "inception" => %{"value" => "1503-01-01T00:00:00Z"},
        "creators" => %{"value" => creators},
        "depicts" => %{"value" => depicts}
      }
    end

    defp famous_stub(selection, description) do
      fn options ->
        query = options |> Keyword.fetch!(:params) |> Keyword.fetch!(:query)

        if String.contains?(query, "VALUES ?item") do
          response(%{"results" => %{"bindings" => description}})
        else
          counts =
            Regex.run(~r/VALUES \?sitelinks \{ ([^}]+) \}/, query)
            |> List.last()
            |> String.split(" ", trim: true)
            |> Enum.map(&String.to_integer/1)

          response(%{
            "results" => %{
              "bindings" => Enum.filter(selection, &(count(&1) in counts))
            }
          })
        end
      end
    end

    defp count(binding), do: binding["sitelinks"]["value"] |> String.to_integer()

    test "the paged walk keeps the Mona Lisa, its creator and its depictions" do
      selection = [
        binding("Q12418", 146, "Mona Lisa.jpg"),
        binding("Q45585", 31, "Nachtwacht.jpg")
      ]

      description = [
        described("Q12418", "Mona Lisa", "Q762~Leonardo da Vinci", "Q26513196~Lisa del Giocondo"),
        described("Q45585", "The Night Watch", "Q5598~Rembrandt", "")
      ]

      assert {:ok, manifest, ledger} =
               WikidataFamous.build(
                 min_sitelinks: 30,
                 interval_ms: 0,
                 request_fun: famous_stub(selection, description)
               )

      assert Enum.map(manifest["rows"], & &1["qid"]) == ["Q12418", "Q45585"]
      assert ledger.mona_lisa_present
      assert ledger.paintings == 2
      assert ledger.with_creator == 2
      assert ledger.with_depicts == 1
      assert ledger.image_bytes_downloaded == 0

      mona = hd(manifest["rows"])
      assert mona["creators"] == [%{"qid" => "Q762", "term" => "Leonardo da Vinci"}]
      assert mona["depicts"] == [%{"qid" => "Q26513196", "term" => "Lisa del Giocondo"}]
      assert mona["date"] == "1503"
      assert mona["credit_line"] == "Mona Lisa.jpg · Wikimedia Commons"

      assert String.starts_with?(
               mona["image_url"],
               "https://upload.wikimedia.org/wikipedia/commons/"
             )

      refute String.contains?(mona["image_url"], "Special:FilePath")
    end

    test "a set without the Mona Lisa in it is not the famous set" do
      selection = [binding("Q45585", 31, "Nachtwacht.jpg")]
      description = [described("Q45585", "The Night Watch", "Q5598~Rembrandt", "")]

      assert {:error, reason} =
               WikidataFamous.build(
                 min_sitelinks: 30,
                 interval_ms: 0,
                 request_fun: famous_stub(selection, description)
               )

      assert reason =~ "smoke test failed"
    end

    test "chunks are asked for high counts first, a few crowded counts at a time" do
      chunks = WikidataFamous.chunks(10)

      # The sparse top of the range is one request; the crowded bottom is asked
      # three counts at a time, because cost tracks how many entities hold a
      # count and not how many counts are named.
      assert 146 in hd(chunks)
      assert 400 in hd(chunks)
      assert List.last(chunks) == [10, 11, 12]
      assert Enum.all?(Enum.drop(chunks, 1), &(length(&1) <= 10))
      assert chunks |> List.flatten() |> Enum.sort() == Enum.to_list(10..400)
    end
  end

  defp progress_path do
    path =
      Path.join(System.tmp_dir!(), "corpus-progress-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
