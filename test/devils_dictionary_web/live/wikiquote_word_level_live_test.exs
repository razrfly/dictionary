defmodule DevilsDictionaryWeb.WikiquoteWordLevelLiveTest do
  @moduledoc """
  `/define/grief` through #172 build B. No sense of *grief* refers to
  anything; the ladder matched its Wikipedia title to Q1026040 and a gloss
  agreed, at 0.85. The page shows a Quotes shelf from *Grief*, the shelf and
  every reason saying it is the word's and not a particular sense's. One
  promotion run later the gloss match is a sense's `refers_to`, the recipe is
  a new one, and the same shelf says nothing of the kind.

  The run is the provider's own over the page captured for #158 build 4
  (`WikiquoteFixture`); the page is mounted as a reader opens it.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Absorb.Linker
  alias DevilsDictionary.{Claims, Discovery, Registry, Repo}
  alias DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.Lexicon.ScopeMember

  @qid "Q1026040"
  @note "For the word “grief”, not a particular sense."

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Wikiquote])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Wikiquote})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req)
    end)

    WikiquoteFixture.respond(%{@qid => "Grief"})

    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes})
  end

  # What the ladder leaves on the dev database: a title match its gloss pass
  # corroborated, on a word in a scope, and no sense link.
  defp grief!(ctx) do
    word = word!(ctx, "grief", ~w(wiktionary))

    sense =
      sense!(ctx, word, "wiktionary",
        gloss: "Emotional pain, generally arising from misfortune or significant personal loss."
      )

    concept = concept!(@qid, "grief")

    {:ok, article} =
      Registry.create_content(%{
        content_kind: :article,
        source_id: ctx.sources["wikipedia"].id,
        body: "Grief is a response to loss, the emotional pain of a significant personal loss.",
        position: 0
      })

    {:ok, _} = Claims.assert(article.object_id, "about", concept.object_id)

    {:ok, _} =
      Claims.assert(word.object_id, "lexeme_entity_candidate", concept.object_id, %{
        method: "title_match",
        confidence: 0.85,
        metadata: %{"corroboration" => "gloss_overlap"}
      })

    Repo.insert!(%ScopeMember{
      scope_id: ctx.scopes["emotions"].id,
      lexeme_id: word.object_id,
      reasons: ["test"]
    })

    %{word: word, sense: sense}
  end

  defp run!(word) do
    target = %{object_id: word.object_id, term: "grief", language: "en", relevance: "term"}
    {:queued, run} = Discovery.request(target, "wikiquote")
    :ok = Discovery.execute_run(run.id)
    Repo.get!(Discovery.Mapping, run.mapping_id)
  end

  test "a word with no sense link shows a Quotes shelf labelled as the word's", ctx do
    %{word: word} = grief!(ctx)
    mapping = run!(word)

    assert [%{"qid" => @qid, "level" => "word"}] = mapping.parameters["entities"]

    {:ok, live, _html} = live(ctx.conn, ~p"/define/grief")

    assert has_element?(live, "#culture-filter-quote")
    assert has_element?(live, ~s([id^="culture-quote-"]))

    # Once on the shelf, above the rail…
    assert has_element?(live, "#culture-word-level-quote", @note)

    # …and on every reason, after the sentence naming the page and the QID.
    about = "#culture-about-quote-wikiquote"

    assert has_element?(
             live,
             about,
             "From Wikiquote's page “Grief”, the concept the word “grief” names (#{@qid}). " <>
               @note
           )

    refute render(live) =~ "Search result for"
  end

  test "after one promotion run the gloss match is the sense's, and the label goes", ctx do
    %{word: word, sense: sense} = grief!(ctx)
    before = run!(word)

    assert %{promoted: 1} = Linker.corroborate(ctx.scopes["emotions"])

    assert [%{object_object_id: _, method: "corroborated_gloss"}] =
             Claims.outgoing(sense.object_id, predicate: "refers_to")

    # A new recipe, because the level is in its identity; the same QID.
    promoted = run!(word)
    refute promoted.id == before.id
    assert [%{"qid" => @qid, "level" => "sense"}] = promoted.parameters["entities"]

    {:ok, live, _html} = live(ctx.conn, ~p"/define/grief")

    assert has_element?(live, "#culture-filter-quote")
    assert has_element?(live, ~s([id^="culture-quote-"]))
    refute has_element?(live, "#culture-word-level-quote")
    refute render(live) =~ "not a particular sense"

    assert has_element?(
             live,
             "#culture-about-quote-wikiquote",
             "From Wikiquote's page “Grief”, the page of the concept this meaning refers to (#{@qid})."
           )
  end

  # Build C: neither tier names a concept, so there is nothing to ask — and
  # the page says that, rather than letting a missing shelf read as "no
  # quotes exist".
  test "a word neither tier reaches says why it has no Quotes shelf, and asks nothing", ctx do
    word!(ctx, "situationship", ~w(wordnet))

    {:ok, live, _html} = live(ctx.conn, ~p"/define/situationship")

    refute has_element?(live, "#culture-filter-quote")

    assert has_element?(
             live,
             "#culture-about-empty-quote",
             "No concept this word's senses refer to has a Wikiquote page."
           )

    assert Repo.aggregate(Discovery.Run, :count) == 0
    assert Repo.aggregate(Discovery.Mapping, :count) == 0
  end

  test "a word-level page is not an empty one", ctx do
    %{word: word} = grief!(ctx)
    run!(word)

    {:ok, live, _html} = live(ctx.conn, ~p"/define/grief")

    refute has_element?(live, "#culture-about-empty-quote")
  end
end
