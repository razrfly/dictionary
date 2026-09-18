defmodule DevilsDictionary.Discovery.Providers.OpenLibraryTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Providers.OpenLibrary

  # `retrieve/4` driven directly with a request function: no HTTP, no database.
  # The search proposes and the snippet disposes, so a page can be full of
  # candidates and still attest nothing — every one a *warm*, none a *war*.

  defp mapping do
    {operation, mapping} =
      OpenLibrary.automatic_mapping(%{
        object_id: 1,
        lexeme_ids: [1],
        term: "war",
        language: "en",
        relevance: "term"
      })

    {operation, mapping}
  end

  defp near_miss(n) do
    %{
      "fields" => %{
        "identifier" => ["nearmiss#{n}"],
        "meta_title" => ["Warm Hands #{n}"],
        "meta_creator" => ["Nobody"],
        "meta_languageSorter" => ["English"]
      },
      "highlight" => %{"text" => ["she held out a {{{warm}}} hand"]}
    }
  end

  defp page(docs), do: {:ok, %{"hits" => %{"hits" => docs}}}

  test "a full page on which nothing attests hands back a cursor, not the end" do
    {operation, mapping} = mapping()
    docs = Enum.map(1..OpenLibrary.page_size(), &near_miss/1)
    request_fun = fn "candidates:1", %{"endpoint" => "inside"} -> page(docs) end

    assert {:ok, result} =
             OpenLibrary.retrieve(
               operation,
               mapping,
               %{"after" => nil, "first" => 12},
               request_fun
             )

    assert result.items == []
    assert result.completion_reason == :no_results
    assert result.next_cursor == Integer.to_string(OpenLibrary.page_size())
  end

  test "a short page on which nothing attests is the end of the search" do
    {operation, mapping} = mapping()
    docs = Enum.map(1..3, &near_miss/1)
    request_fun = fn "candidates:1", %{"endpoint" => "inside"} -> page(docs) end

    assert {:ok, result} =
             OpenLibrary.retrieve(
               operation,
               mapping,
               %{"after" => nil, "first" => 12},
               request_fun
             )

    assert result.items == []
    assert result.completion_reason == :no_results
    assert result.next_cursor == nil
  end
end
