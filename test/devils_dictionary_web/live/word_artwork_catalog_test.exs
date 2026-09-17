defmodule DevilsDictionaryWeb.WordArtworkCatalogTest do
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}
  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    Map.put(ctx, :sources, sources)
  end

  defp seed_met!(tags) do
    {:ok, summary} =
      Manifest.new("met-highlights", [
        %{
          "met_object_id" => "11417",
          "title" => "Washington Crossing the Delaware",
          "artist" => "Emanuel Leutze",
          "date" => "1851",
          "image_url" => "https://images.metmuseum.org/11417.jpg",
          "credit_line" => "Gift of John Stewart Kennedy, 1897",
          "source_url" => "https://www.metmuseum.org/art/collection/search/11417",
          "tags" => tags
        }
      ])
      |> Seeder.run()

    summary
  end

  defp seed_famous!(depicts) do
    {:ok, summary} =
      Manifest.new("wikidata-famous", [
        %{
          "qid" => "Q12418",
          "title" => "Mona Lisa",
          "sitelinks" => 146,
          "image_url" => "https://upload.wikimedia.org/wikipedia/commons/thumb/x/xx/Mona.jpg",
          "commons_file" => "Mona Lisa.jpg",
          "credit_line" => "Mona Lisa.jpg · Wikimedia Commons",
          "creators" => [%{"qid" => "Q762", "term" => "Leonardo da Vinci"}],
          "depicts" => depicts
        }
      ])
      |> Seeder.run()

    summary
  end

  test "the merged catalog reads as one artwork section on the word page", ctx do
    war = word!(ctx, "war", ["wordnet"])
    sense = sense!(ctx, war, "wordnet", gloss: "the waging of armed conflict")
    link!(war, concept!("Q198", "War"), sense: sense, confidence: 0.95)

    assert %{newly_created: 1} = seed_met!([%{"term" => "Soldiers", "qid" => "Q198"}])
    assert %{newly_created: 1} = seed_famous!([%{"term" => "war", "qid" => "Q198"}])

    {:ok, view, html} = live(ctx.conn, ~p"/define/war")

    # One shelf, both sources inside it, on the one reader surface (K2 of #109).
    # Two artwork sections on one page is the thing this is not allowed to
    # produce — and the tall cards beside the Met's shelf were exactly that.
    assert has_element?(view, "#in-culture")
    assert has_element?(view, "#culture-filter-artwork", "Artworks")
    assert html |> String.split(~s(id="culture-filter-artwork")) |> length() == 2
    refute has_element?(view, "#artwork-candidates")

    met_id = DevilsDictionary.Registry.by_external_id("met_object_id", "11417")
    famous_id = DevilsDictionary.Registry.by_external_id("wikidata", "Q12418")

    assert has_element?(view, "#culture-result-catalog_artwork-c#{met_id}")
    assert has_element?(view, "#culture-result-catalog_artwork-c#{famous_id}")

    # Both reach their local identity rather than an outside page.
    assert has_element?(view, "#culture-entry-image-c#{met_id}[href^='/entities/']")
    assert has_element?(view, "#culture-entry-image-c#{famous_id}[href^='/entities/']")

    # The reason is a fact with an identifier in it, and it names the concept
    # this page's sense refers to rather than a phrase composed for the reader.
    assert has_element?(
             view,
             "#culture-about-catalog",
             "Direct depiction of \u201CWar\u201D (Q198)"
           )

    assert has_element?(view, "#culture-about-catalog", "not yet reviewed")

    # Whoever made it, from a manifest display name and from a local identity.
    assert render(view) =~ "Emanuel Leutze"
    assert render(view) =~ "Leonardo da Vinci"
  end

  test "a word-level entity candidate says the match is about the word", ctx do
    love = word!(ctx, "love", ["wordnet"])
    sense!(ctx, love, "wordnet", gloss: "a strong affection")
    link!(love, concept!("Q316", "love"), method: :title_match)

    assert %{newly_created: 1} = seed_famous!([%{"term" => "love", "qid" => "Q316"}])

    {:ok, view, _html} = live(ctx.conn, ~p"/define/love")

    assert has_element?(view, "#culture-filter-artwork", "Artworks")

    assert has_element?(
             view,
             "#culture-about-catalog",
             "matched to the word and not to this meaning"
           )
  end

  test "a word the encyclopedia has not linked to a QID shows no artwork section", ctx do
    family = word!(ctx, "family", ["wordnet"])
    sense!(ctx, family, "wordnet", gloss: "a group of related people")

    assert %{newly_created: 1} = seed_famous!([%{"term" => "family", "qid" => "Q8436"}])

    {:ok, view, _html} = live(ctx.conn, ~p"/define/family")

    refute has_element?(view, "#culture-filter-artwork")
    refute has_element?(view, "#culture-about-catalog")
  end

  test "the catalog page lists both corpus sources", ctx do
    assert %{newly_created: 1} = seed_met!([])
    assert %{newly_created: 1} = seed_famous!([])

    {:ok, view, _html} = live(ctx.conn, ~p"/artworks")

    met_id = DevilsDictionary.Registry.by_external_id("met_object_id", "11417")
    famous_id = DevilsDictionary.Registry.by_external_id("wikidata", "Q12418")

    assert has_element?(view, "#artwork-#{met_id}")
    assert has_element?(view, "#artwork-#{famous_id}")
  end
end
