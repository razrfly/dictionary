defmodule DevilsDictionary.SourceProjectionTest do
  use DevilsDictionary.DataCase, async: true

  defp project(previous, value) do
    %{rows: [[result]]} =
      Repo.query!("SELECT dd_merge_projected_metadata($1::jsonb,$2::jsonb)", [previous, value])

    result
  end

  test "display metadata has stable source precedence and same-source corrections still apply" do
    wiki = %{"_projection_origin" => [1, "cat"], "image_url" => "wiki image"}
    data = %{"_projection_origin" => [2, "Q1"], "image_url" => "data image", "taxon" => "cat"}
    first = %{} |> project(wiki) |> project(data)
    assert first == %{} |> project(data) |> project(wiki)
    assert first == first |> project(data) |> project(wiki)
    assert first["image_url"] == "wiki image"
    assert project(first, Map.put(wiki, "image_url", "corrected"))["image_url"] == "corrected"
    refute Map.has_key?(project(first, %{"_projection_origin" => [1, "cat"]}), "image_url")
  end

  test "conflicting lookup probes choose the same representative in either order" do
    first = %{"_projection_origin" => [1, "Z-probe"], "title" => "Honey bee"}
    other = %{"_projection_origin" => [1, "a-probe"], "title" => "Different title"}
    state = %{} |> project(first) |> project(other)
    assert state["title"] == "Honey bee"
    assert state == %{} |> project(other) |> project(first)
    assert state == state |> project(first) |> project(other)
  end
end
