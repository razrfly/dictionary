defmodule DevilsDictionaryWeb.ScopeLiveTest do
  @moduledoc """
  Scope browse — scorecard row **U5**: the badges are legible, the filters work,
  and the counts are the ones `mix dd.health` prints.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Health, Repo}
  alias DevilsDictionary.Lexicon.{Lexeme, ScopeLexeme}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp word!(ctx, lemma, source_slugs, opts \\ []) do
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: lemma,
        pos: "noun",
        slug: Lexeme.slug(lemma),
        source_ids: Enum.map(source_slugs, &ctx.sources[&1].id),
        enriched_at: Keyword.get(opts, :enriched_at, DateTime.utc_now())
      })

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: Keyword.get(opts, :reasons, ["wordnet_closure"])
    })

    lexeme
  end

  # A row is identified by its id, so a negative assertion is about the row and
  # not about a word that happens to appear elsewhere on the page.
  defp row(lexeme), do: ~s(id="lexeme-#{lexeme.id}")

  defp concept!(qid, label, attrs \\ []) do
    Repo.insert!(struct(%Concept{qid: qid, label: label, kind: :taxon}, attrs))
  end

  defp link!(lexeme, concept, opts \\ []) do
    Repo.insert!(%ConceptLink{
      lexeme_id: lexeme.id,
      concept_id: concept.id,
      method: Keyword.get(opts, :method, :title_match),
      confidence: Keyword.get(opts, :confidence, 0.9),
      status: Keyword.get(opts, :status, :auto)
    })
  end

  describe "the badges (U5)" do
    test "one glyph per source, and the count matches mix dd.health", ctx do
      cat = word!(ctx, "cat", ~w(wordnet wiktionary bierce))
      word!(ctx, "oyster", ~w(wordnet wiktionary))
      word!(ctx, "aardvark", ~w(wordnet))

      {:ok, live, html} = live(ctx.conn, ~p"/s/animals")

      # Every word shows a badge slot for every source, lit or not.
      for lexeme <- [cat], source <- ~w(wordnet wiktionary wikidata wikipedia bierce) do
        assert html =~ ~s(id="badge-#{lexeme.id}-#{source}")
      end

      # U5's requirement: the page's coverage line and Health.coverage/2 agree.
      # The line is loaded asynchronously, so the words never wait for it.
      settled = render_async(live)

      for slug <- ~w(wordnet wiktionary bierce wikipedia) do
        covered = Health.coverage("animals", slug).covered
        assert settled =~ "#{slug} #{covered}"
      end

      # Wikidata attests things, not words: its figure is the linked count,
      # from the same rule the rows use to show a concept (S4c).
      assert settled =~
               ~s(id="scope-linked">#{DevilsDictionary.Lexicon.Browse.linked_count("animals")}<)

      assert settled =~ "linked to"

      # A chip's value must never travel as `phx-value-value`: LiveView's JS
      # replaces it with the button's own empty value and the chip goes dead
      # (S4 audit). LiveViewTest cannot see that, so the attribute is the guard.
      refute settled =~ "phx-value-value"
      assert settled =~ ~s(phx-value-slug="bierce")
    end

    test "a bare index row says so", ctx do
      word!(ctx, "aardvarks", ~w(wiktionary), enriched_at: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/s/animals")
      assert html =~ "bare"
    end

    test "a word's thing and its scientific name ride along", ctx do
      cat = word!(ctx, "cat", ~w(wordnet), reasons: ["wordnet_closure", "wiktionary_category"])

      link!(
        cat,
        concept!("Q146", "cat",
          taxon: %{"scientific_name" => "Felis catus", "rank" => "species"},
          image_url: "https://upload.wikimedia.org/x.jpg"
        )
      )

      {:ok, _live, html} = live(ctx.conn, ~p"/s/animals")

      # The graph's glyph on a row means "linked", not "attests".
      assert html =~ ~s(title="wikidata: linked")

      assert html =~ "Felis catus"
      assert html =~ "https://upload.wikimedia.org/x.jpg"
      assert html =~ "wordnet_closure"
      assert html =~ "wiktionary_category"
    end
  end

  describe "the filters" do
    test "has and missing narrow the list, and live in the URL", ctx do
      cat = word!(ctx, "cat", ~w(bierce wordnet))
      aardvark = word!(ctx, "aardvark", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/s/animals")

      html = live |> element("#filter-has-bierce") |> render_click()
      assert html =~ row(cat)
      refute html =~ row(aardvark)
      assert_patched(live, ~p"/s/animals?has=bierce&sort=lemma")

      html = live |> element("#filter-has-bierce") |> render_click()
      assert html =~ row(aardvark)

      html = live |> element("#filter-missing-bierce") |> render_click()
      assert html =~ row(aardvark)
      refute html =~ row(cat)
    end

    test "the state filters, including disputed", ctx do
      torpedo = word!(ctx, "torpedo", ~w(wordnet))
      link!(torpedo, concept!("Q1", "fish"), confidence: 0.9)
      link!(torpedo, concept!("Q2", "weapon"), confidence: 0.8, method: :wiktionary_qid)
      aardvark = word!(ctx, "aardvark", ~w(wordnet), enriched_at: nil)

      {:ok, live, _html} = live(ctx.conn, ~p"/s/animals")

      html = live |> element("#filter-state-disputed") |> render_click()
      assert html =~ row(torpedo)
      refute html =~ row(aardvark)

      html = live |> element("#filter-state-bare") |> render_click()
      assert html =~ row(aardvark)
      refute html =~ row(torpedo)
    end

    test "search within the scope", ctx do
      oyster = word!(ctx, "oyster", ~w(wordnet))
      cat = word!(ctx, "cat", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/s/animals")

      html =
        live
        |> form("#scope-filters", %{"q" => "oyst", "sort" => "lemma"})
        |> render_change()

      assert html =~ row(oyster)
      refute html =~ row(cat)
    end

    test "clear puts everything back", ctx do
      word!(ctx, "cat", ~w(bierce))
      aardvark = word!(ctx, "aardvark", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/s/animals?has=bierce")
      refute render(live) =~ row(aardvark)

      html = live |> element("#filter-clear") |> render_click()
      assert html =~ row(aardvark)
      assert_patched(live, ~p"/s/animals")
    end

    test "a filter that matches nothing says so rather than looking broken", ctx do
      word!(ctx, "cat", ~w(wordnet))

      {:ok, _live, html} = live(ctx.conn, ~p"/s/animals?has=bierce")
      assert html =~ "Nothing in this scope matches"
    end
  end

  describe "the taxonomy panel" do
    test "drilling in filters the words and keeps the filters", ctx do
      animalia = concept!("Q729", "Animalia")
      felidae = concept!("Q25265", "Felidae")

      Repo.insert!(%ConceptRelation{
        source_id: ctx.sources["wikidata"].id,
        from_concept_id: felidae.id,
        to_concept_id: animalia.id,
        type: :parent_taxon,
        property: "P171"
      })

      cat = word!(ctx, "cat", ~w(wordnet))
      link!(cat, felidae)
      oyster = word!(ctx, "oyster", ~w(wordnet))

      {:ok, live, html} = live(ctx.conn, ~p"/s/animals")

      # The words are on screen before the taxonomy is walked.
      assert html =~ row(cat)
      assert html =~ row(oyster)

      html = render_async(live)
      assert html =~ ~s(id="tree-Q25265")

      html = live |> element("#tree-Q25265") |> render_click()
      assert html =~ row(cat)
      refute html =~ row(oyster)
    end
  end

  test "an unknown scope is a redirect, not a crash", ctx do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(ctx.conn, ~p"/s/nosuch")
  end
end
