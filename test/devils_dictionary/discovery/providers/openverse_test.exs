defmodule DevilsDictionary.Discovery.Providers.OpenverseTest do
  @moduledoc """
  The readings the conformance fixture cannot cover, because a fixture holds
  captured rows and some of these are about rows it would be dishonest to
  capture: a title Openverse passed through from Commons without cleaning it,
  a licence outside the gate, a credit whose title is longer than a card, and
  the one query parameter whose value depends on which page is being asked
  for.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Providers.Openverse

  describe "title/1 — what a card can show" do
    test "an ordinary title is its own answer" do
      assert Openverse.title(%{"title" => "Bosnian war header.no"}) == "Bosnian war header.no"
      assert Openverse.title(%{"title" => "  war  "}) == "war"
      assert Openverse.title(%{"title" => "   "}) == nil
      assert Openverse.title(%{}) == nil
    end

    test "a Commons ObjectName block keeps its English line and loses its QuickStatements" do
      # Real, from `/define/allegory` on 2026-09-19: Openverse indexes
      # Commons's `ObjectName` verbatim, hidden `label QS:…` lines included.
      block =
        "<div class='fn'> <p>Allegory of Europe </p> " <>
          "<div style='display: none;'>label QS:Lsl,'Alegorija Evrope'</div> " <>
          "<div style='display: none;'>label QS:Lfr,'Allegorie de l'Europe'</div></div>"

      assert Openverse.title(%{"title" => block}) == "Allegory of Europe"
    end

    test "a QuickStatements line that is not hidden is still not a title" do
      assert Openverse.title(%{
               "title" => "<p>Holy Allegory</p> label QS:P1476,en:'Holy Allegory'"
             }) ==
               "Holy Allegory label"
    end

    test "a title is clamped to what a label column can hold" do
      assert Openverse.title(%{"title" => String.duplicate("a", 400)}) |> String.length() == 255
    end
  end

  describe "license/1 — the gate is on the item, not on the query" do
    test "the four this project shows become the short form M4 names" do
      assert Openverse.license(%{"license" => "by", "license_version" => "2.0"}) ==
               {:ok, "CC-BY-2.0"}

      assert Openverse.license(%{"license" => "by-sa", "license_version" => "4.0"}) ==
               {:ok, "CC-BY-SA-4.0"}

      assert Openverse.license(%{"license" => "cc0", "license_version" => "1.0"}) ==
               {:ok, "CC0-1.0"}

      assert Openverse.license(%{"license" => "pdm", "license_version" => "1.0"}) ==
               {:ok, "PDM-1.0"}
    end

    test "a missing version is not a missing licence" do
      assert Openverse.license(%{"license" => "by"}) == {:ok, "CC-BY"}
      assert Openverse.license(%{"license" => "cc0"}) == {:ok, "CC0-1.0"}
    end

    test "every NC and ND variant is refused, and so is anything unrecognised" do
      for slug <- ~w(by-nc by-nc-nd by-nc-sa by-nd nc-sampling+ sampling+ gfdl) do
        assert Openverse.license(%{"license" => slug, "license_version" => "2.0"}) == :error
      end

      assert Openverse.license(%{}) == :error
      assert Openverse.license(%{"license" => nil}) == :error
    end
  end

  describe "attribution/3 — the credit is one sentence (D2 of #126)" do
    test "names the title, the creator and the licence, in that order, with no URL" do
      row = %{
        "title" => "war",
        "attribution" =>
          ~S|"war" by zbigphotography (1M+ views) is licensed under CC BY-SA 2.0. | <>
            "To view a copy of this license, visit https://creativecommons.org/licenses/by-sa/2.0/."
      }

      line = Openverse.attribution(row, "CC-BY-SA-2.0", "zbigphotography (1M+ views)")

      assert line == ~S|"war" by zbigphotography (1M+ views), CC-BY-SA-2.0|
      refute line =~ "http"
      assert String.length(line) < 160
    end

    test "Openverse's own ready-made line is never forwarded, however it is spelled" do
      row = %{"title" => "war", "attribution" => "anything at all, with https://a.test in it"}

      refute Openverse.attribution(row, "CC0-1.0", "Someone") =~ "http"
      assert Openverse.attribution(row, "CC0-1.0", "Someone") == ~S|"war" by Someone, CC0-1.0|
    end

    test "what is missing is absent rather than filled with a word" do
      assert Openverse.attribution(%{"title" => "war"}, "CC0-1.0", nil) ==
               ~S|"war", CC0-1.0|

      assert Openverse.attribution(%{}, "CC0-1.0", "Someone") == "by Someone, CC0-1.0"
      assert Openverse.attribution(%{}, "CC0-1.0", nil) == "CC0-1.0"
    end

    test "the title is the part that gives, and the creator and the licence never are" do
      # A card's title may be 255 characters; a credit may not. The creator is
      # not cut at any length, because a cut creator matches no needle in
      # `Culture.credit_parts/2` and so carries no link — which is the one
      # thing an Unsplash- or CC-style licence actually asks for.
      long_title = String.duplicate("a", 200)
      creator = String.duplicate("b", 120)

      clamped = Openverse.attribution(%{"title" => long_title}, "CC-BY-4.0", "Someone")
      assert String.length(clamped) < 160
      assert String.ends_with?(clamped, ~S|…" by Someone, CC-BY-4.0|)

      dropped = Openverse.attribution(%{"title" => long_title}, "CC-BY-4.0", creator)
      assert dropped == "by #{creator}, CC-BY-4.0"
      assert String.contains?(dropped, creator)
    end
  end

  describe "request_options/1 — filter_dead is the first page's, not the walk's" do
    test "the first page asks Openverse to check the links" do
      params = params(%{"term" => "war", "page" => "1", "page_size" => "12"})

      assert params["filter_dead"] == "true"
      assert params["q"] == ~S|"war"|
      assert params["page"] == "1"
    end

    test "a page after the first does not, because the filter is what repeats page one" do
      # Measured live 2026-09-19 on `q="war"`, `page_size=12`: with
      # `filter_dead=true` page 2 answered with page 1's twelve ids; with it
      # off, pages 1, 2 and 3 were contiguous on three cold cache misses
      # (#126 Phase 2, #128).
      for page <- ~w(2 3 20) do
        assert params(%{"term" => "war", "page" => page, "page_size" => "12"})["filter_dead"] ==
                 "false"
      end
    end

    test "the licence gate is on the query as well as on the item, on every page" do
      for page <- ~w(1 2) do
        params = params(%{"term" => "war", "page" => page, "page_size" => "12"})
        assert params["license"] == "cc0,pdm,by,by-sa"
        assert params["mature"] == "false"
      end
    end
  end

  defp params(payload), do: Openverse.request_options(payload)[:params]
end
