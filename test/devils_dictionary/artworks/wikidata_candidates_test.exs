defmodule DevilsDictionary.Artworks.WikidataCandidatesTest do
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Artworks.WikidataCandidates

  test "physical discovery requests are counted without hidden Req retries" do
    request_fun = fn options ->
      send(self(), {:request_options, options})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"results" => %{"bindings" => []}}
       }}
    end

    assert {:ok, [], %{requests: 1}} =
             WikidataCandidates.discover(
               limit: 1,
               request_limit: 1,
               remote: true,
               request_fun: request_fun
             )

    assert_receive {:request_options, options}
    assert options[:retry] == false
    refute Keyword.has_key?(options, :max_retries)
  end

  test "distinct P11005 values on one QID remain distinct artwork identities" do
    request_fun = fn _options ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => %{
             "bindings" => [
               binding("Q900100", "first-artsy-work"),
               binding("Q900100", "second-artsy-work")
             ]
           }
         }
       }}
    end

    assert {:ok, candidates, %{requests: 1}} =
             WikidataCandidates.discover(
               limit: 2,
               request_limit: 1,
               remote: true,
               request_fun: request_fun
             )

    assert Enum.map(candidates, & &1["artsy_artwork_slug"]) == [
             "first-artsy-work",
             "second-artsy-work"
           ]
  end

  defp binding(qid, artsy_slug) do
    %{
      "item" => %{"value" => "http://www.wikidata.org/entity/#{qid}"},
      "itemLabel" => %{"value" => "Fixture artwork"},
      "artsy" => %{"value" => artsy_slug}
    }
  end
end
