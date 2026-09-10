defmodule DevilsDictionaryWeb.SourceLiveTest do
  @moduledoc "One page per source: what it is, what it holds, what it covers."

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Health

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"], emotions: scopes["emotions"]}
  end

  test "the row, its tier, its licence and its snapshot pin", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

    assert html =~ ~s(id="source-header")
    assert html =~ "Ambrose Bierce"
    assert html =~ "aristocracy"
    assert html =~ "gutenberg_id=972"
    assert html =~ "Public domain"
    # #69 backbone rule 1: the attribution line is not optional.
    assert html =~ "Attribution:"
    # A year is not a count.
    assert html =~ "1911"
    refute html =~ "1,911"
  end

  test "what it holds, and what that became", ctx do
    record = record!(ctx, "bierce", external_id: "CAT/n", raw: %{})
    lexeme = word!(ctx, "cat", ~w(bierce), scope: nil)

    entry!(ctx, lexeme, "bierce",
      record: record,
      headword: "CAT",
      pos: "n",
      body: "A soft, indestructible automaton.",
      year: 1911
    )

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

    assert html =~ ~s(id="source-counts")
    assert html =~ ~s(id="source-samples")
    # A real row, not a fixture: this page must not invent what was absorbed.
    assert html =~ "A soft, indestructible automaton."
    assert html =~ "CAT"
  end

  test "coverage of the scope is Health.coverage/2's number", ctx do
    word!(ctx, "cat", ~w(bierce))
    word!(ctx, "oyster", [])

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce?scope=animals")

    coverage = Health.coverage("animals", "bierce")
    assert coverage.covered == 1
    assert coverage.total == 2
    assert html =~ ~s(id="source-coverage")
    assert html =~ "#{coverage.pct}%"
    assert html =~ "1 of 2 scope words"
  end

  test "a source that writes neither senses nor entries says so", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/sources/wikidata")

    assert html =~ "materializes neither senses nor entries"
    assert ctx.sources["wikidata"].kind == :knowledge_graph
  end

  test "coverage is of the scope asked for, not always Animals (#70 S5c)", ctx do
    word!(ctx, "joy", ~w(bierce), scope: ctx.emotions)

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce?scope=emotions")

    coverage = Health.coverage("emotions", "bierce")

    assert html =~ ~s(id="source-coverage")
    assert html =~ "#{coverage.total}"
  end

  # The defect this page had all along, and the one test/ never covered — not
  # even the S5c test above, which exists to prove the page is not hard-wired to
  # Animals. The headline read the scope asked for; the link under it went to
  # `/s/animals` whatever was asked (#77 §1).
  test "the gaps link goes to the population the page is reporting on", ctx do
    word!(ctx, "joy", ~w(wordnet), scope: ctx.emotions)

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce?scope=emotions")

    assert html =~ "Browse the words this source is missing"
    assert html =~ ~s(href="/ops/scopes/emotions?missing=bierce")
    refute html =~ "/s/animals"
    refute html =~ ~s(href="/ops/scopes/animals?missing=bierce")
  end

  # #77 §1: a reader's source page must not make a claim about a population
  # nobody asked about, and "population" is not a word public copy uses. So the
  # coverage section is simply absent, and everything the source owns is not.
  describe "with no population asked about" do
    test "the source answers for itself and makes no coverage claim", ctx do
      word!(ctx, "cat", ~w(bierce))

      {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

      assert html =~ ~s(id="source-header")
      assert html =~ ~s(id="source-counts")
      assert html =~ ~s(id="source-runs")
      assert html =~ "Attribution:"

      refute html =~ ~s(id="source-coverage")
      refute html =~ "scope words"
      refute html =~ "Animals"
      refute html =~ ~s(id="population-chooser")
    end
  end

  test "an unknown source is a redirect, not a crash", ctx do
    assert {:error, {:live_redirect, %{to: "/ops/imports"}}} =
             live(ctx.conn, ~p"/sources/nosuch")
  end
end
