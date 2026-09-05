defmodule DevilsDictionary.Absorb.Clients.WikipediaTest do
  @moduledoc """
  The client's whole job is turning one batched response back into an answer
  per requested title. Everything interesting is in that mapping, and none of
  it needs a network (scorecard O3).
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Absorb.Clients.Wikipedia

  defp stub(body) do
    Req.Test.stub(Clients, fn conn -> Req.Test.json(conn, body) end)
  end

  defp page(title, attrs \\ %{}) do
    Map.merge(%{"title" => title, "pageid" => :erlang.phash2(title), "ns" => 0}, attrs)
  end

  test "answers by the title that was asked for, not the one the API resolved" do
    stub(%{
      "query" => %{
        "normalized" => [%{"from" => "oyster drill", "to" => "Oyster drill"}],
        "redirects" => [%{"from" => "Oyster drill", "to" => "Urosalpinx cinerea"}],
        "pages" => [page("Urosalpinx cinerea", %{"description" => "Species of gastropod"})]
      }
    })

    assert {:ok, %{"oyster drill" => found}} =
             Wikipedia.summaries(["oyster drill"], rate_limit_ms: 0)

    assert found["title"] == "Urosalpinx cinerea"
  end

  test "a title with no article comes back as :missing, not as an error" do
    stub(%{
      "query" => %{
        "pages" => [
          %{"title" => "Prophaethontid", "missing" => true},
          page("Cat")
        ],
        "normalized" => [%{"from" => "prophaethontid", "to" => "Prophaethontid"}]
      }
    })

    assert {:ok, found} = Wikipedia.summaries(["prophaethontid", "Cat"], rate_limit_ms: 0)
    assert found["prophaethontid"] == :missing
    assert found["Cat"]["title"] == "Cat"
  end

  test "a title absent from the response entirely is also :missing" do
    stub(%{"query" => %{"pages" => []}})

    assert {:ok, %{"nothing" => :missing}} = Wikipedia.summaries(["nothing"], rate_limit_ms: 0)
  end

  test "an empty request costs no call at all" do
    Req.Test.stub(Clients, fn _conn -> raise "should not be called" end)
    assert {:ok, %{}} = Wikipedia.summaries([])
  end

  test "namespace-0 links of a disambiguation page" do
    stub(%{
      "query" => %{
        "pages" => [
          %{
            "title" => "Seal",
            "links" => [%{"title" => "Fur seal"}, %{"title" => "Seal (emblem)"}]
          }
        ]
      }
    })

    assert {:ok, ["Fur seal", "Seal (emblem)"]} = Wikipedia.links("Seal", rate_limit_ms: 0)
  end

  test "a 429 is a snooze, not a failure" do
    Req.Test.stub(Clients, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.resp(429, "slow down")
    end)

    assert {:error, {:rate_limited, 30}} = Wikipedia.summaries(["Cat"], rate_limit_ms: 0)
  end

  test "a 429 with no Retry-After still snoozes" do
    Req.Test.stub(Clients, fn conn -> Plug.Conn.resp(conn, 429, "slow down") end)

    assert {:error, {:rate_limited, seconds}} = Wikipedia.summaries(["Cat"], rate_limit_ms: 0)
    assert seconds > 0
  end
end
