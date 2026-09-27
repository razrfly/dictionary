defmodule DevilsDictionary.Routing.SlugParityTest do
  @moduledoc """
  The slug cases the Stage 2 proposal generator (`docs/routing/stage-2/
  candidates.py`) is held to. This side holds `Routing.Policy.slug/1` to the
  same file, so the two cannot drift apart silently: a change here must be
  made in both, or one of the two tests fails.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{Address, Policy}

  @fixture "docs/routing/stage-2/slug-parity.json"
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  test "the parity file covers normalization, marks, punctuation and the byte limit" do
    reasons = Enum.map(@cases, & &1["case"])

    for expected <- [
          "decomposed accent (NFD)",
          "combining marks in an Indic script",
          "plus signs"
        ] do
      assert expected in reasons
    end

    assert Enum.any?(@cases, &is_nil(&1["slug"]))
  end

  for %{"case" => reason, "input" => input, "slug" => slug} <- @cases do
    test "Policy.slug/1: #{reason}" do
      assert Policy.slug(unquote(input)) == unquote(slug)
    end
  end

  test "every slug in the file is a path segment the address parser accepts" do
    for %{"slug" => slug} <- @cases, slug do
      assert {:ok, %{slug: ^slug}} = Address.parse("/works/" <> slug)
    end
  end
end
