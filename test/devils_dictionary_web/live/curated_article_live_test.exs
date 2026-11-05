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
    html = view |> element("#curated-page") |> render()

    order =
      ~w(entry-views on-title headword curated-byline curated-lead opening-lead-why
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
             "last assessed it on 4 November 2026, 09:43 UTC and chose not to select, and gave no reason."
           )

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
end
