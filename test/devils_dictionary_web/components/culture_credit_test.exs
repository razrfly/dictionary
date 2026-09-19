defmodule DevilsDictionaryWeb.CultureCreditTest do
  @moduledoc """
  `Culture.credit_parts/2` on its own (D3 of #116 Phase 3).

  The multi-source check and the Commons/Openverse fold check assert the
  rendered links on real and coordinated items. These are the readings those
  cannot reach: a line that must come back unchanged whatever happens to it,
  a licence spelled two ways, a creator whose name is a substring of the rest
  of the sentence, and an item with no URLs at all.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionaryWeb.Culture

  defp texts(parts), do: Enum.map(parts, & &1.text)
  defp links(parts), do: parts |> Enum.reject(&is_nil(&1.url)) |> Enum.map(&{&1.text, &1.url})

  describe "the line is never altered" do
    test "the runs always concatenate back to the line exactly" do
      lines = [
        "Photo by Levi Meir Clancy on Unsplash",
        "Photo by Barış  Karagöz on Pexels",
        "Fixture, Public domain, via Wikimedia Commons",
        ~S|"war" by zbigphotography (1M+ views) is licensed under CC BY-SA 2.0.|,
        "Unsplash",
        "CC-BY-4.0"
      ]

      metadata = %{
        "creator" => "Levi Meir Clancy",
        "creator_url" => "https://unsplash.com/@levimeirclancy",
        "license" => "Unsplash",
        "license_url" => "https://unsplash.com/license"
      }

      for line <- lines do
        assert line |> Culture.credit_parts(metadata) |> texts() |> Enum.join() == line
      end
    end

    test "nothing at all is nothing to render" do
      assert Culture.credit_parts(nil, %{}) == []
    end
  end

  describe "what becomes a link" do
    test "the photographer's name and the word Unsplash, as the guidelines require" do
      parts =
        Culture.credit_parts("Photo by Levi Meir Clancy on Unsplash", %{
          "creator" => "Levi Meir Clancy",
          "creator_url" => "https://unsplash.com/@levimeirclancy?utm_source=devils_dictionary",
          "license" => "Unsplash",
          "license_url" => "https://unsplash.com/license?utm_source=devils_dictionary"
        })

      assert texts(parts) == ["Photo by ", "Levi Meir Clancy", " on ", "Unsplash"]

      assert links(parts) == [
               {"Levi Meir Clancy",
                "https://unsplash.com/@levimeirclancy?utm_source=devils_dictionary"},
               {"Unsplash", "https://unsplash.com/license?utm_source=devils_dictionary"}
             ]
    end

    test "a licence spelled with hyphens in the field and with spaces in the line" do
      line =
        ~S|"war" by zbigphotography (1M+ views) is licensed under CC BY-SA 2.0. To view a copy of this license, visit https://creativecommons.org/licenses/by-sa/2.0/.|

      parts =
        Culture.credit_parts(line, %{
          "creator" => "zbigphotography (1M+ views)",
          "creator_url" => "https://www.flickr.com/photos/45098669@N06",
          "license" => "CC-BY-SA-2.0",
          "license_url" => "https://creativecommons.org/licenses/by-sa/2.0/"
        })

      assert links(parts) == [
               {"zbigphotography (1M+ views)", "https://www.flickr.com/photos/45098669@N06"},
               {"CC BY-SA 2.0", "https://creativecommons.org/licenses/by-sa/2.0/"}
             ]

      # The trailing sentence, URL and all, is left as the text it is.
      assert List.last(texts(parts)) =~ "To view a copy of this license"
    end

    test "a name the line does not contain is not linked anywhere" do
      parts =
        Culture.credit_parts("An anonymous engraving, public domain", %{
          "creator" => "Somebody Else",
          "creator_url" => "https://example.test/somebody",
          "license" => "CC0-1.0",
          "license_url" => "https://creativecommons.org/publicdomain/zero/1.0/"
        })

      assert links(parts) == []
      assert texts(parts) == ["An anonymous engraving, public domain"]
    end
  end

  describe "what stays plain text" do
    test "a name with no URL beside it" do
      parts =
        Culture.credit_parts("Fixture, Public domain, via Wikimedia Commons", %{
          "creator" => "Fixture",
          "creator_url" => "https://commons.wikimedia.org/wiki/User:Fixture",
          "license" => "Public domain",
          "license_url" => nil
        })

      assert links(parts) == [{"Fixture", "https://commons.wikimedia.org/wiki/User:Fixture"}]
    end

    test "an item with no metadata worth reading" do
      assert Culture.credit_parts("Photo by Nobody on Nowhere", %{}) == [
               %{text: "Photo by Nobody on Nowhere", url: nil}
             ]

      assert Culture.credit_parts("Photo by Nobody on Nowhere", nil) == [
               %{text: "Photo by Nobody on Nowhere", url: nil}
             ]
    end

    test "a blank field is not a name" do
      assert Culture.credit_parts("Photo by  on Unsplash", %{
               "creator" => "   ",
               "creator_url" => "https://example.test/x",
               "license" => "",
               "license_url" => "https://example.test/l"
             })
             |> links() == []
    end
  end

  describe "overlaps" do
    test "a link never opens inside another one" do
      # The creator's name contains the licence text, and both carry URLs.
      parts =
        Culture.credit_parts("CC BY 4.0 Studio, CC BY 4.0, via Somewhere", %{
          "creator" => "CC BY 4.0 Studio",
          "creator_url" => "https://example.test/studio",
          "license" => "CC-BY-4.0",
          "license_url" => "https://creativecommons.org/licenses/by/4.0/"
        })

      # The licence's first occurrence is inside the creator's name, so it is
      # dropped rather than nested — the credit loses a link it could have
      # had further along the line, and keeps the one thing that matters,
      # which is that the sentence is intact and no anchor opens inside
      # another.
      assert links(parts) == [{"CC BY 4.0 Studio", "https://example.test/studio"}]

      assert texts(parts) == ["CC BY 4.0 Studio", ", CC BY 4.0, via Somewhere"]
      assert texts(parts) |> Enum.join() == "CC BY 4.0 Studio, CC BY 4.0, via Somewhere"
    end
  end
end
