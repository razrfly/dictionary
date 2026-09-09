defmodule DevilsDictionary.EncyclopediaTest do
  @moduledoc """
  The rule that has to have exactly one meaning: **what counts as a link from a
  word to a thing.**

  Five surfaces read it — the browse page's concept column, its taxon filter,
  `linked_count/1`, scorecard rows A10 and L3, and the Wikidata seed — and it is
  written twice, because two of them are recursive CTEs that have to inline it
  and three of them compose Ecto. `Encyclopedia`'s moduledoc says the two
  spellings agree; this is what makes that a checked claim rather than an
  intention.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Claims, Encyclopedia, Fixtures, Repo}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  describe "the two spellings of `linked`" do
    test "return the same pairs, over a graph with something of every kind", ctx do
      cat = word!(ctx, "cat", ~w(wordnet))
      seal = word!(ctx, "seal", ~w(wordnet))
      hammer = word!(ctx, "hammer", ~w(wordnet))

      # Sense-backed, above the floor: a claim.
      link!(cat, concept!("Q146", "cat"), confidence: 0.95, method: :wiktionary_qid)

      # Word-level, above the floor: also a claim, and a different one.
      link!(seal, concept!("Q7365", "Pinniped"), confidence: 0.9, method: :title_match)

      # Word-level, below the floor: a possibility. Neither spelling counts it.
      link!(seal, concept!("Q114414285", "BYD Seal"),
        confidence: 0.4,
        method: :disambiguation
      )

      # Above the floor but rejected by a curator. Neither spelling counts it,
      # and no importer rerun can put it back.
      rejected = link!(hammer, concept!("Q25294", "Hammer"), confidence: 0.9)
      Claims.review(Claims.current_revision(rejected.id).id, :rejected)

      assert raw_pairs() == query_pairs()

      # And it is the graph we meant, not two empty sets agreeing.
      assert length(raw_pairs()) == 2
    end

    test "and they agree when the floor is widened to nothing", ctx do
      seal = word!(ctx, "seal", ~w(wordnet))
      link!(seal, concept!("Q1", "a possibility"), confidence: 0.4, method: :disambiguation)

      assert raw_pairs(0.0) == query_pairs(min_confidence: 0.0)
      assert length(raw_pairs(0.0)) == 1
    end
  end

  describe "view/1" do
    test "puts identity and description back together, and only there", ctx do
      _ = ctx

      entity =
        concept!("Q146", "cat",
          description: "a small carnivore",
          image_url: "https://example.test/cat.jpg",
          wikipedia_title: "Cat",
          taxon: %{"scientific_name" => "Felis catus"}
        )

      view = Encyclopedia.view(entity)

      # The QID is an `external_identifiers` row and the rest is `metadata`;
      # a page reads one flat map and never has to know that.
      assert view.qid == "Q146"
      assert view.label == "cat"
      assert view.description == "a small carnivore"
      assert view.image_url == "https://example.test/cat.jpg"
      assert view.wikipedia_title == "Cat"
      assert view.taxon["scientific_name"] == "Felis catus"
    end

    test "a local thing with no external identifier is still a thing", ctx do
      _ = ctx

      # #74's decision 7, as a fact about the display layer too: a local artwork
      # or event exists without a QID, and the panel must not require one.
      entity = concept!(nil, "an untitled meme")
      view = Encyclopedia.view(entity)

      assert view.qid == nil
      assert view.label == "an untitled meme"
    end
  end

  defp raw_pairs(floor \\ nil) do
    sql =
      if floor,
        do: Encyclopedia.linked_lexemes_sql(floor),
        else: Encyclopedia.linked_lexemes_sql()

    Repo.query!("SELECT lexeme_id, entity_id FROM (#{sql}) lk ORDER BY 1, 2")
    |> Map.fetch!(:rows)
    |> Enum.map(&List.to_tuple/1)
  end

  defp query_pairs(opts \\ []) do
    Repo.all(
      from lk in subquery(Encyclopedia.linked_lexemes_query(opts)),
        order_by: [lk.lexeme_id, lk.entity_id],
        select: {lk.lexeme_id, lk.entity_id}
    )
    |> Enum.uniq()
  end
end
