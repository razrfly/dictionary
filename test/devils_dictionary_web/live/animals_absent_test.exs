defmodule DevilsDictionaryWeb.AnimalsAbsentTest do
  @moduledoc """
  #77's headline acceptance scenario: *"No Animals population is configured —
  app boots, general search and entries work, and explicitly selected non-animal
  imports/health run without looking up Animals."*

  Every `\\\\ "animals"` default in the code was a latent `Ecto.NoResultsError`
  waiting for the row to be missing, and the whole product's navigation depended
  on it existing. So the test is the deletion: seed the catalog, remove the
  `animals` scope row, and walk the app.

  The **test** database only — sandboxed and rolled back per test. #79's
  guardrail is about the development database, which this never touches.

  Note what stays true. Animal *content* is untouched by the deletion: `cat` is
  still a word, still carries its sources, and still has whatever taxonomy is
  attached, because a population is an operational selection and never an
  entry's identity. That is the distinction #77 §2 is drawing, and deleting the
  row is the cleanest way to demonstrate it.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Ecto.Query

  alias DevilsDictionary.{Fixtures, Health, Repo}
  alias DevilsDictionary.Health.Score
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.Scope

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    ctx = %{sources: sources, animals: scopes["animals"], emotions: scopes["emotions"]}

    # Built while Animals still exists, so the words carry real membership and
    # the deletion is a deletion rather than an omission.
    cat = word!(ctx, "cat", ~w(wordnet bierce))
    sense!(ctx, cat, "wordnet", group_key: "oewn-cat-n", gloss: "a feline")
    entry!(ctx, cat, "bierce", headword: "CAT", pos: "n", body: "A soft automaton.", year: 1911)
    joy = word!(ctx, "joy", ~w(wordnet), scope: ctx.emotions)
    sense!(ctx, joy, "wordnet", group_key: "oewn-joy-n", gloss: "a feeling")

    {1, _} = Repo.delete_all(from s in Scope, where: s.slug == "animals")

    Map.put(ctx, :cat, cat)
  end

  test "the population really is gone" do
    refute Lexicon.get_scope_by_slug("animals")
    assert Lexicon.scope_slugs() == "culture, emotions"
  end

  describe "the reader's app" do
    test "the home page, its search and its stats all work", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/")
      html = render_async(live)

      assert html =~ ~s(id="stats")
      assert html =~ "words indexed"
      assert render_change(live, "search", %{"q" => "cat"}) =~ "cat"
    end

    test "an animal word keeps its page, its sources and its provenance", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/define/cat")

      assert html =~ "A soft automaton."
      assert html =~ "a feline"
      assert html =~ ~s(id="sources")
      assert html =~ "Defined here by 2 dictionaries"
    end

    test "and by its canonical address too", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/words/#{ctx.cat.object_id}/cat")

      assert html =~ "A soft automaton."
    end

    test "a source page answers for itself", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

      assert html =~ "Ambrose Bierce"
      assert html =~ "Attribution:"
      refute html =~ ~s(id="source-coverage")
    end
  end

  describe "the operational consoles" do
    test "grade the population they are asked for, without looking Animals up", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/ops/health?scope=emotions")
      html = render_async(live, 15_000)

      summary = "emotions" |> then(&Score.rows(scope: &1, skip_parity: true)) |> Score.summary()
      assert html =~ "#{summary.passed} / #{summary.graded} graded rows pass"
    end

    test "offer only the populations that exist", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/ops/imports")

      assert html =~ ~s(id="population-emotions")
      assert html =~ ~s(id="population-culture")
      refute html =~ ~s(id="population-animals")
    end

    test "a source's coverage of a live population is measurable", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/sources/wordnet?scope=emotions")

      assert html =~ ~s(id="source-coverage")
      assert html =~ "#{Health.coverage("emotions", "wordnet").total}"
    end
  end
end
