defmodule DevilsDictionary.Discovery.Providers.OpenverseTest do
  @moduledoc """
  The two readings the conformance fixture cannot cover, because a fixture
  holds captured rows and these are about rows it would be dishonest to
  capture: a title Openverse passed through from Commons without cleaning it,
  and a licence outside the gate.
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
end
