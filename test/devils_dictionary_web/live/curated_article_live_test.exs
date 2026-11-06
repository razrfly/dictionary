defmodule DevilsDictionaryWeb.CuratedArticleLiveTest do
  @moduledoc """
  `/on/:slug` as the curated article (#309 D3): one document order on every
  screen size, every published item drawn, a state for each way there is
  nothing to show, and nothing on the page for one screen size only.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{Published, Reviews}

  setup ctx, do: love_world!(ctx)

  defp position(html, id) do
    case :binary.match(html, ~s(id="#{id}")) do
      {at, _} -> at
      :nomatch -> flunk("#{id} is not on the page")
    end
  end

  test "one document order: masthead, byline, lead, sections, the editor, the records, the version",
       ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")
    html = render(view)

    order =
      ~w(entry-views curated-page on-title headword curated-byline curated-lead opening-lead-why
         curated-definitions opening-highlight-1-reason curated-quotations curated-editor
         record-inventory-link curated-provenance)

    positions = Enum.map(order, &position(html, &1))
    assert positions == Enum.sort(positions)

    # The switch names both views for what they hold, the second being the
    # source records.
    assert has_element?(view, "#entry-curated[aria-current='page']", "This editor’s selection")

    assert has_element?(
             view,
             "#entry-records[href='/on/love/materials']",
             "Everything this page holds"
           )
  end

  # The owner's audit: a tap on the switch changed the switch itself. Both
  # views draw one control, and only which half is current changes.
  test "one switch on both views: the same control, only the current half changes", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, curated, _} = live(ctx.conn, ~p"/on/love")
    {:ok, records, _} = live(ctx.conn, ~p"/on/love/materials")

    switch = fn view ->
      doc = view |> element("#entry-views") |> render() |> LazyHTML.from_fragment()
      [nav] = doc |> LazyHTML.query("#entry-views") |> LazyHTML.attribute("class")

      halves =
        for id <- ~w(entry-curated entry-records) do
          node = LazyHTML.query(doc, "##{id}")
          [class] = LazyHTML.attribute(node, "class")

          {id, class, LazyHTML.attribute(node, "aria-current"),
           node |> LazyHTML.text() |> String.trim()}
        end

      {nav, halves}
    end

    {nav, [{_, curated_on, ["page"], selection}, {_, records_off, [], holds}]} =
      switch.(curated)

    {^nav, [{_, curated_off, [], ^selection}, {_, records_on, ["page"], ^holds}]} =
      switch.(records)

    assert selection == "This editor’s selection"
    assert holds == "Everything this page holds"
    # The current half looks the same on either view, and so does the other.
    assert curated_on == records_on
    assert curated_off == records_off
    # One weight in both states: only the fill says which is current.
    for class <- [curated_on, curated_off], do: assert(class =~ "font-medium")
    assert has_element?(curated, "#entry-records[href='/on/love/materials']")
    assert has_element?(records, "#entry-curated[href='/on/love']")
  end

  # The owner's audit: the page used too little of a wide screen. The two
  # `/on` views are wider there; a `/words` page and `?layout=current` are not.
  test "the curated article and its materials are the wide views", ctx do
    publish!(ctx, provision!(ctx))

    for path <- ["/on/love", "/on/love/materials"] do
      {:ok, view, _} = live(ctx.conn, path)
      assert has_element?(view, "[data-page-width='wide']"), path
    end

    for path <- ["/on/love?layout=current", "/words/#{ctx.love.object_id}/love"] do
      {:ok, view, _} = live(ctx.conn, path)
      refute has_element?(view, "[data-page-width]"), path
    end
  end

  # On a desktop the byline heads the right column, level with the headword,
  # and the editor follows it: one grid, the masthead and the body each a
  # subgrid of it, so the document order is still the reading order.
  test "on a desktop the byline heads the column the editor is in", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")
    doc = view |> render() |> LazyHTML.from_fragment()
    classes = fn selector -> doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") end

    [page] = classes.("#curated-page")
    assert page =~ "lg:grid "
    assert page =~ "lg:grid-cols-[minmax(0,1fr)_22rem]"

    [masthead] = classes.("#curated-masthead")
    assert masthead =~ "lg:col-span-2 lg:grid lg:grid-cols-subgrid"
    # A column gap of its own would override the grid's.
    refute masthead =~ ~r/(?:^|\s)gap-(?:\d|x-)/

    # The masthead holds the headword's block, then the byline: two cells.
    assert doc |> LazyHTML.query("#curated-masthead > *") |> Enum.count() == 2
    assert has_element?(view, "#curated-masthead > #curated-byline")
    assert has_element?(view, "#curated-page > div > #curated-column + #curated-rail")
  end

  test "every published item renders, with its reason on the page and one disclosure", ctx do
    composition = provision!(ctx)
    publish!(ctx, composition)
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert {:ok, %{lead: lead, highlights: highlights}} = Published.current(composition.id)
    assert lead
    assert length(highlights) == 2

    assert has_element?(view, "#opening-lead-text")

    for id <- ["opening-lead" | Enum.map(highlights, &"opening-highlight-#{&1.position}")] do
      assert has_element?(view, "details##{id}-why summary", "About this choice")
      refute has_element?(view, "details##{id}-why[open]")
    end

    # Each item's stored note is on the page, under the label D1 gives it.
    for {highlight, note} <- Enum.zip(highlights, ["Johnson's senses.", "A literary use."]) do
      assert has_element?(
               view,
               "#opening-highlight-#{highlight.position}-reason",
               "Why it’s here"
             )

      assert has_element?(view, "#opening-highlight-#{highlight.position}-reason", note)
    end

    assert has_element?(view, "#curated-holdings", "The editor chose 3.")
  end

  test "the editor chose what the version holds: a withheld item still counts, and is named",
       ctx do
    composition = provision!(ctx)
    publish!(ctx, composition)

    # The Milton quotation's sense gets a newer revision: the published item
    # is withheld at read time (#255 §2.3).
    current = DevilsDictionary.Registry.current_sense_revision(ctx.profound.object_id)

    {:ok, _newer} =
      DevilsDictionary.Registry.add_sense_revision(ctx.profound.object_id, %{
        gloss: current.gloss,
        position: current.position,
        examples: current.examples,
        url: current.url,
        source_record_revision_id: current.source_record_revision_id
      })

    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-holdings", "The editor chose 3, and 1 is withheld.")
    assert has_element?(view, "#curated-withheld-2", "Nothing was put in its place.")
    refute has_element?(view, "#opening-highlight-2")
  end

  test "a person's review is said without the person's name", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-status", "Reviewed by a person")

    reviewer =
      DevilsDictionary.Sources.Actor
      |> DevilsDictionary.Repo.get_by!(user_id: ctx.reviewer.user.id)
      |> DevilsDictionary.Curation.Compositions.author_label()

    # The masthead names no one; the record's own disclosure in the footer
    # (`#opening-about`, unchanged by #309) keeps its actors.
    refute view |> element("#curated-masthead") |> render() =~ reviewer
  end

  test "every id on the page is unique", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id]")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

    assert ids -- Enum.uniq(ids) == []
  end

  test "withheld as a whole: when it was published, why it is not shown, nothing in its place",
       ctx do
    %{version: version} = publish!(ctx, provision!(ctx))

    {:ok, _} =
      Reviews.decide(ctx.reviewer, version.id, :withdrawn,
        reason: "#309 test",
        idempotency_key: key("withdraw")
      )

    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    refute has_element?(view, "#opening")
    assert has_element?(view, "#curated-state[data-state='withheld']")
    assert has_element?(view, "#curated-state-heading", "A selection published on")
    assert has_element?(view, "#curated-state-heading", "is not shown.")

    assert has_element?(
             view,
             "#curated-state-why",
             "Its approval was withdrawn. Nothing was put in its place."
           )

    assert has_element?(view, "#curated-state #record-inventory-link[href='/on/love/materials']")
    # The withheld version's own record is a tap away.
    assert has_element?(view, "#curated-state-receipt[href='/on/love/receipt/1']")
  end

  test "abstained: who assessed it, when, and that it chose not to select", ctx do
    composition = provision!(ctx)
    publish!(ctx, composition)
    assert {:ok, :admitted} = visit!()
    withdraw!(ctx, composition)

    composition
    |> row!()
    |> set!(%{
      state: :idle,
      last_outcome: :abstained,
      last_outcome_reason: "abstained",
      last_completed_at: ~U[2026-11-04 09:43:02.000000Z],
      refresh_after: DateTime.add(DateTime.utc_now(), 3600)
    })

    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-state[data-state='abstained']")
    assert has_element?(view, "#curated-state-heading", "No selection is published for love.")

    assert has_element?(
             view,
             "#curated-state-assessed",
             "last assessed it on 4 November 2026, 09:43 UTC and chose not to select."
           )

    refute has_element?(view, "#curated-state-assessed", "gave no reason")
    refute has_element?(view, "#curated-state-reason")
  end

  test "never assessed: says so, and where every record is", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-state[data-state='none']")
    assert has_element?(view, "#curated-state-why", "No editor has assessed it yet.")
    assert has_element?(view, "#curated-holdings", "This page holds entries from")
  end

  # Nothing is shown on one screen size and hidden on another: the phone
  # reads the same document the desktop does (#309 §5).
  test "no content is desktop-only or phone-only", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    toggles = ~r/^(?:max-)?(?:sm|md|lg|xl|2xl):(?:hidden|sr-only)$/

    shows =
      ~r/^(?:sm|md|lg|xl|2xl):(?:block|flex|grid|inline|inline-flex|inline-block|contents|table)$/

    offending =
      view
      |> element("#curated-page")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[class]")
      |> Enum.flat_map(fn node ->
        tokens = node |> LazyHTML.attribute("class") |> hd() |> String.split()

        cond do
          Enum.any?(tokens, &Regex.match?(toggles, &1)) -> [tokens]
          "hidden" in tokens and Enum.any?(tokens, &Regex.match?(shows, &1)) -> [tokens]
          true -> []
        end
      end)

    assert offending == []
  end

  # A phone held sideways is 640 px and wider: a tap target there is as
  # large as it is upright (#309 review 4, item 3).
  test "no tap target shrinks on a wider screen", ctx do
    publish!(ctx, provision!(ctx))
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    shrinks = ~r/^(?:sm|md|lg|xl|2xl):(?:min-h|h)-(?:0|px|[0-9]|10|\[.*\])$/

    offending =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#entry-views a, #curated-page a, #curated-page summary, #curated-page button"
      )
      |> Enum.flat_map(fn node ->
        node
        |> LazyHTML.attribute("class")
        |> Enum.flat_map(&String.split/1)
        |> Enum.filter(&Regex.match?(shrinks, &1))
      end)

    assert offending == []

    # Links that run in a line are sized by what holds them: credits and
    # details, the headword's other words and Wikidata, the exact revisions.
    for {holder, rule} <- [
          {"#opening", "[&_dd_a]:min-h-11"},
          {"#curated-masthead", "[&_#parts-of-speech_a]:min-h-11"},
          {"#curated-masthead", "[&_#quick-definition_a]:min-h-11"},
          {"#curated-masthead", "[&_#quick-definition>span]:block"},
          {"#curated-provenance", "[&_#opening-about-revisions_a]:min-h-11"}
        ] do
      classes =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(holder)
        |> LazyHTML.attribute("class")
        |> hd()

      assert classes =~ rule, "#{holder} sizes its links"
    end

    # The byline's link to the editor is a box of its own.
    assert has_element?(view, "#curation-summary a.min-h-11")
  end
end
