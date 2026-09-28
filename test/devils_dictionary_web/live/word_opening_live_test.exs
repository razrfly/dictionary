defmodule DevilsDictionaryWeb.WordOpeningLiveTest do
  @moduledoc """
  The curated opening on the word page (#156 Phase 1): rendered from the
  committed development fixture only when the environment allows it and the
  request asks, placed before the Definitions, and leaving every existing row,
  id and the open-row rule exactly as they were.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Curation.{ManualFixture, Opening}
  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    Map.merge(ctx, love!(ctx))
  end

  test "love, with the fixture asked for: Bierce leads, three highlights, a fixture label", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")

    assert has_element?(view, "#opening-fixture", "Development fixture")
    assert has_element?(view, "#opening-lead-text", "A temporary insanity curable by marriage")
    assert has_element?(view, "#opening-lead-entry[href='#card-bierce']", "Read the whole entry")
    assert has_element?(view, "#opening-highlight-1-title", "Cupid and Psyche")
    assert has_element?(view, "#opening-highlight-2-text", "cordial love")
    assert has_element?(view, "#opening-highlight-3-text", "Woman ſcorn'd")
    assert has_element?(view, "#opening-about-reviewed", "No person has reviewed")
  end

  test "the same page without the parameter has no opening and no trace of one", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love")

    refute has_element?(view, "#opening")
    assert has_element?(view, "#word-rail[class='lg:col-start-1 lg:row-start-1']")
  end

  test "the definitions are untouched: the same cards, the same ids, the same open row", ctx do
    {:ok, plain, _} = live(ctx.conn, ~p"/define/love")
    {:ok, curated, _} = live(ctx.conn, ~p"/define/love?opening=fixture")

    cards = fn view ->
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("details[name=sources]")
      |> Enum.map(&{LazyHTML.attribute(&1, "id"), LazyHTML.attribute(&1, "open")})
    end

    assert cards.(curated) == cards.(plain)
    assert {["card-wordnet"], [""]} in cards.(curated)

    for id <- ~w(card-bierce card-johnson card-wordnet card-wiktionary) do
      assert has_element?(curated, "##{id}")
    end
  end

  # The #202 audit: CSS `order` put the opening after the headword on screen
  # while keyboard and screen-reader order still went through the whole rail
  # first. The document order is now the reading order.
  test "the document order is the reading order: headword, opening, rail, definitions", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")
    html = render(view)

    order =
      for marker <- [
            ~s(id="headword"),
            ~s(id="opening"),
            ~s(id="word-rail"),
            ~s(id="word-stats"),
            ~s(id="definitions-),
            ~s(id="page-sources")
          ],
          do: html |> :binary.match(marker) |> elem(0)

    assert order == Enum.sort(order)

    # The headword now stands on its own, before the opening, not inside the
    # rail; the rest of the rail keeps its id. One copy of each.
    refute has_element?(view, "#word-rail #headword")
    assert html |> String.split(~s(id="headword")) |> length() == 2
    assert html |> String.split(~s(id="word-rail")) |> length() == 2

    # No CSS reordering is left to disagree with it.
    refute html =~ "order-first"
    refute html =~ "-order-1"
    refute html =~ "max-lg:contents"
  end

  test "without an opening the page keeps its own layout, headword inside the rail", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love")

    assert has_element?(view, "#word-rail #headword")
    assert has_element?(view, "#word-rail[class='lg:col-start-1 lg:row-start-1']")
  end

  test "moving between words never carries one word's selection onto another", ctx do
    word!(ctx, "rizz", ~w(wiktionary), scope: nil)

    {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")
    assert has_element?(view, "#opening-lead-text", "temporary insanity")

    render_patch(view, ~p"/define/rizz?opening=fixture")
    refute has_element?(view, "#opening")
    assert has_element?(view, "#word-rail #headword")

    render_patch(view, ~p"/define/love?opening=fixture")
    assert has_element?(view, "#opening-lead-text", "temporary insanity")

    # A reconnect is a fresh mount; it reads the selection again, not a copy.
    {:ok, again, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")
    assert has_element?(again, "#opening-highlight-1-title", "Cupid and Psyche")
  end

  test "the opening's disclosures are closed at first and keep their state across patches",
       ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")

    for id <- ~w(opening-lead-why opening-highlight-1-why opening-about) do
      assert has_element?(view, "details##{id}[phx-mounted]")
      refute has_element?(view, "details##{id}[open]")
    end
  end

  test "a word no fixture names renders exactly as it does without the parameter", ctx do
    word!(ctx, "rizz", ~w(wiktionary), scope: nil)

    {:ok, view, _html} = live(ctx.conn, ~p"/define/rizz?opening=fixture")

    refute has_element?(view, "#opening")
    assert has_element?(view, "#word-rail[class='lg:col-start-1 lg:row-start-1']")
  end

  test "an explicitly empty composition draws no section, heading or skeleton", ctx do
    word!(ctx, "topographagnosia", ~w(wiktionary), scope: nil)

    {:ok, view, _html} = live(ctx.conn, ~p"/define/topographagnosia?opening=fixture")

    refute has_element?(view, "#opening")
    refute has_element?(view, "#opening-heading")
  end

  test "the canonical address of the noun carries the opening; the verb's does not", ctx do
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)

    {:ok, noun_view, _} = live(ctx.conn, ~p"/words/#{ctx.love.object_id}/love?opening=fixture")
    {:ok, verb_view, _} = live(ctx.conn, ~p"/words/#{verb.object_id}/love?opening=fixture")

    assert has_element?(noun_view, "#opening-lead")
    refute has_element?(verb_view, "#opening")
  end

  test "turning the fixture on and off is a patch that rebuilds the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/define/love")
    refute has_element?(view, "#opening")

    render_patch(view, ~p"/define/love?opening=fixture")
    assert has_element?(view, "#opening-lead")

    render_patch(view, ~p"/define/love")
    refute has_element?(view, "#opening")
  end

  describe "a committed manifest that fails verification" do
    @describetag :tmp_dir
    @describetag :capture_log

    setup %{tmp_dir: root} do
      previous = Application.get_env(:devils_dictionary, :committed_manifest_root)
      Application.put_env(:devils_dictionary, :committed_manifest_root, root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:devils_dictionary, :committed_manifest_root, previous),
          else: Application.delete_env(:devils_dictionary, :committed_manifest_root)
      end)
    end

    test "the page still renders, without the work and without a substitute", ctx do
      committed_manifest!(ctx.tmp_dir, :invalid_checksum)

      {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")

      assert has_element?(view, "#opening-lead-text", "temporary insanity")
      refute has_element?(view, "#opening-highlight-1")
      assert has_element?(view, "#opening-highlight-2-text", "cordial love")
      assert has_element?(view, "#opening-about-withheld", "Highlight 1")
      assert has_element?(view, "#opening-about-withheld", "its catalog has changed")
      # The definitions below are untouched.
      assert has_element?(view, "#card-bierce")
    end
  end

  describe "the gate" do
    setup do
      previous = Application.get_env(:devils_dictionary, :curated_opening_fixtures)

      on_exit(fn ->
        Application.put_env(:devils_dictionary, :curated_opening_fixtures, previous)
      end)
    end

    test "with fixtures off, the parameter does nothing", ctx do
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, false)

      assert is_nil(Opening.reader(%{"opening" => "fixture"}))

      {:ok, view, _html} = live(ctx.conn, ~p"/define/love?opening=fixture")
      refute has_element?(view, "#opening")
    end

    test "with fixtures on, only the exact parameter asks for them" do
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, true)

      assert Opening.reader(%{"opening" => "fixture"}) == ManualFixture
      assert is_nil(Opening.reader(%{"opening" => "1"}))
      assert is_nil(Opening.reader(%{}))
    end

    test "production never turns fixtures on" do
      for path <- ~w(config/prod.exs config/runtime.exs config/config.exs) do
        refute File.read!(path) =~ "curated_opening_fixtures",
               "#{path} must not mention :curated_opening_fixtures"
      end
    end
  end
end
