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
end
