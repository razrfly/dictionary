defmodule DevilsDictionary.Discovery.Providers.PexelsTest do
  @moduledoc """
  What the conformance fixture cannot say: that `alt` is the only text Pexels
  publishes about a photo, and that the source is posted on the shelf as the
  search it is.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Providers.Pexels

  describe "title/1 — one generated sentence, or nothing" do
    test "alt is the title, because there is no other text" do
      assert Pexels.title(%{
               "alt" =>
                 "Desolate war-damaged building in Homs, Syria, with a truck in foreground."
             }) == "Desolate war-damaged building in Homs, Syria, with a truck in foreground."
    end

    test "an empty alt is nothing a card could print" do
      assert Pexels.title(%{"alt" => ""}) == nil
      assert Pexels.title(%{"alt" => "   "}) == nil
      assert Pexels.title(%{"alt" => nil}) == nil
      assert Pexels.title(%{}) == nil
      assert Pexels.title(nil) == nil
    end

    test "whitespace is collapsed and the line is clamped" do
      assert Pexels.title(%{"alt" => " two  spaces\tand a tab "}) == "two spaces and a tab"
      assert Pexels.title(%{"alt" => String.duplicate("a", 400)}) |> String.length() == 255
    end
  end

  describe "the shelf's posture" do
    test "a search-only source is plebs-tier (D1) and declines nothing (M6)" do
      assert Pexels.source_attrs().tier == :plebs
      assert Pexels.covers?(%{object_id: 1, term: "war", language: "en", relevance: "term"})
    end

    test "it declares the image shelf and nothing else" do
      assert Pexels.capabilities().content_types == [:image]
    end

    test "it proposes no encyclopedia identity" do
      refute function_exported?(Pexels, :identity_record, 1)
    end

    test "the licence is the Pexels License, named and linked" do
      attrs = Pexels.source_attrs()
      assert attrs.license =~ "Pexels License"
      assert attrs.license_url == "https://www.pexels.com/license/"
    end
  end
end
