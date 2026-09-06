defmodule DevilsDictionaryWeb.SourceLiveTest do
  @moduledoc "One page per source: what it is, what it holds, what it covers."

  use DevilsDictionaryWeb.ConnCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Health, Repo}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme}
  alias DevilsDictionary.Sources.SourceRecord

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
    source = ctx.sources["bierce"]
    now = DateTime.utc_now()

    record =
      Repo.insert!(%SourceRecord{
        source_id: source.id,
        external_id: "CAT/n",
        raw: %{},
        content_hash: "x",
        fetched_at: now,
        materialized_at: now
      })

    lexeme = Repo.insert!(%Lexeme{lang: "en", lemma: "cat", pos: "noun", slug: "cat"})

    Repo.insert!(%Entry{
      source_id: source.id,
      source_record_id: record.id,
      lexeme_id: lexeme.id,
      headword: "CAT",
      pos: "n",
      body: "A soft, indestructible automaton.",
      body_format: :markdown,
      year: 1911
    })

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

    assert html =~ ~s(id="source-counts")
    assert html =~ ~s(id="source-samples")
    # A real row, not a fixture: this page must not invent what was absorbed.
    assert html =~ "A soft, indestructible automaton."
    assert html =~ "CAT"
  end

  test "coverage of the scope is Health.coverage/2's number", ctx do
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: "cat",
        pos: "noun",
        slug: "cat",
        source_ids: [ctx.sources["bierce"].id]
      })

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: ["wordnet_closure"]
    })

    Repo.insert!(%Lexeme{lang: "en", lemma: "oyster", pos: "noun", slug: "oyster"})
    |> then(
      &Repo.insert!(%ScopeLexeme{
        scope_id: ctx.animals.id,
        lexeme_id: &1.id,
        reasons: ["wordnet_closure"]
      })
    )

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce")

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
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: "joy",
        pos: "noun",
        slug: "joy",
        source_ids: [ctx.sources["bierce"].id]
      })

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.emotions.id,
      lexeme_id: lexeme.id,
      reasons: ["wordnet_closure"]
    })

    {:ok, _live, html} = live(ctx.conn, ~p"/sources/bierce?scope=emotions")

    coverage = Health.coverage("emotions", "bierce")

    assert html =~ ~s(id="source-coverage")
    assert html =~ "#{coverage.total}"
  end

  test "an unknown source is a redirect, not a crash", ctx do
    assert {:error, {:live_redirect, %{to: "/admin/imports"}}} =
             live(ctx.conn, ~p"/sources/nosuch")
  end
end
