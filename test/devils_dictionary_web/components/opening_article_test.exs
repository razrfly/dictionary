defmodule DevilsDictionaryWeb.OpeningArticleTest do
  @moduledoc """
  The selection as the curated article draws it (#309 D3): the lead with its
  reason, *In the news* directly after it, the four sections a reader
  recognises, and every published item with its reason on the page and one
  disclosure. The arrangement is nepotism version 5's shape: a lead and
  eight highlights across news, a definition, two quotations and four works.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DevilsDictionary.Curation.Opening, as: Composition

  alias DevilsDictionary.Curation.Opening.{
    Credit,
    Highlight,
    Lead,
    Meaning,
    Reason,
    Reference,
    Review
  }

  alias DevilsDictionaryWeb.Opening

  @editor %{kind: :model, label: "Inspired by Voltaire · voltaire-whole-entry-v6 · qwen3.5-9b"}

  defp note(text), do: %Reason{kind: :editorial, text: text, author: @editor}

  defp meaning,
    do: %Meaning{kind: :lexeme, object_id: 1, label: "nepotism", part_of_speech: "noun"}

  defp lead do
    %Lead{
      reference: %Reference{object_id: 11, object_kind: :content, content_revision_id: 411},
      policy: :priority_source,
      register: :satire,
      source: %{
        slug: "bierce",
        name: "Ambrose Bierce, The Devil's Dictionary",
        tier: :aristocracy,
        logo: nil
      },
      author: "Ambrose Bierce",
      work: "The Devil's Dictionary",
      entry: %{headword: "NEPOTISM", marker: "n", year: 1911},
      excerpt: %{
        text: "Appointing your grandmother to office for the good of the party.",
        html: "Appointing your grandmother to office for the good of the party.",
        clipped?: false,
        chars: 64
      },
      meaning: meaning(),
      links: %{card_id: "card-bierce"},
      credits: [%Credit{label: "Rights", text: "Public domain"}],
      reasons: [note("Bierce satire highlights absurdity of power abuse.")]
    }
  end

  defp shelf(position, kind, title, reason) do
    %Highlight{
      position: position,
      kind: :shelf,
      reference: %Reference{object_id: 100 + position, object_kind: :entity},
      title: title,
      creator: "A creator",
      date: "2024",
      meaning: meaning(),
      source: %{slug: "provider-#{kind}", name: "Provider #{kind}", tier: :middle, logo: nil},
      links: %{source: "https://example.test/#{position}"},
      work: %{
        kind: kind,
        attribution: nil,
        mark: nil,
        credit_parts: [],
        observed_at: ~U[2026-11-03 03:02:49Z],
        shown_until: ~U[2026-11-10 03:02:49Z]
      },
      credits: [%Credit{label: "Source", text: "Provider #{kind}"}],
      reasons: [note(reason)]
    }
  end

  defp definition(position) do
    %Highlight{
      position: position,
      kind: :definition,
      register: :definition,
      reference: %Reference{object_id: 12, object_kind: :content, content_revision_id: 412},
      title: "A Dictionary of the English Language",
      creator: "Samuel Johnson",
      date: "1755",
      excerpt: %{
        text: "Fondness for nephews.",
        html: "Fondness for nephews.",
        clipped?: false,
        chars: 21
      },
      meaning: meaning(),
      source: %{slug: "johnson", name: "Samuel Johnson", tier: :aristocracy, logo: nil},
      links: %{},
      credits: [%Credit{label: "Rights", text: "Public domain"}],
      reasons: [note("Johnson gives the older sense.")]
    }
  end

  defp quotation(position, text) do
    %Highlight{
      position: position,
      kind: :quotation,
      register: :quotation,
      reference: %Reference{object_id: 2, object_kind: :sense, sense_revision_id: 22},
      quotation: %{text: text, citation: "1909, a citation", provenance: nil},
      meaning: meaning(),
      source: %{slug: "wiktionary", name: "Wiktionary", tier: :middle, logo: nil},
      links: %{},
      credits: [%Credit{label: "Rights", text: "CC BY-SA 4.0"}],
      reasons: [note("A use that tests the claim.")]
    }
  end

  defp nine do
    %Composition{
      composition: %{id: 6, version: 5},
      origin: :published,
      lead: lead(),
      highlights: [
        definition(1),
        quotation(2, "First line."),
        quotation(3, "Second line."),
        shelf(4, "images", "An image", "Visual representation."),
        shelf(5, "films", "A film", "A film about favour."),
        shelf(6, "music", "An album", "A song about family."),
        shelf(7, "books", "A book", "A book on patronage."),
        # Exactly 100 characters, stopping mid-word: the cap, not a sentence.
        shelf(8, "news", "A headline", String.duplicate("abcd ", 19) <> "abcde")
      ],
      review: %Review{state: :published, selected_by: @editor, published_on: ~D[2026-11-03]}
    }
  end

  defp render_article(opening \\ nine()),
    do: render_component(&Opening.article/1, opening: opening) |> LazyHTML.from_fragment()

  defp ids(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

  test "every published item renders, each with its reason on the page and one disclosure" do
    doc = render_article()

    assert ids(doc, "#opening-lead") == ["opening-lead"]

    shown = ids(doc, "li[id^='opening-highlight-']")
    assert Enum.sort(shown) == Enum.map(1..8, &"opening-highlight-#{&1}")

    for id <- ["opening-lead" | shown] do
      assert [_] = LazyHTML.query(doc, "##{id}-reason") |> Enum.to_list(),
             "#{id} shows its reason"

      assert [_] = LazyHTML.query(doc, "details##{id}-why") |> Enum.to_list(),
             "#{id} has one disclosure"
    end

    # One disclosure per item: nine in all, every one closed and named for
    # what it holds.
    assert Enum.count(LazyHTML.query(doc, "details")) == 9
    assert Enum.count(LazyHTML.query(doc, "details[open]")) == 0

    for summary <- LazyHTML.query(doc, "details > summary") do
      assert summary |> LazyHTML.text() |> String.trim() == "About this choice"
    end
  end

  test "the lead, then In the news, then Definitions, Quotations and In culture, in document order" do
    doc = render_article()

    assert ids(doc, "section[id^='curated-']") ==
             ~w(curated-lead curated-news curated-definitions curated-quotations curated-culture)

    assert LazyHTML.query(doc, "#curated-lead-heading") |> LazyHTML.text() =~ "Leading definition"
    assert LazyHTML.query(doc, "#curated-news-heading") |> LazyHTML.text() =~ "In the news"

    # In culture keeps the sections' order: image, film, music, book.
    assert ids(doc, "#curated-culture li[id^='opening-highlight-']") ==
             ~w(opening-highlight-4 opening-highlight-5 opening-highlight-6 opening-highlight-7)
  end

  test "a reason is the stored text with the AI mark; one stopped at the cap says so outside the quotes" do
    doc = render_article()

    lead = LazyHTML.query(doc, "#opening-lead-reason") |> LazyHTML.text()
    assert lead =~ "Why it leads"
    assert lead =~ "“Bierce satire highlights absurdity of power abuse.”"
    refute lead =~ "cut at"

    news = LazyHTML.query(doc, "#opening-highlight-8-reason") |> LazyHTML.text()
    assert news =~ "Why it’s here"
    assert news =~ "” · cut at 100 characters"
    assert [_] = LazyHTML.query(doc, "#opening-highlight-8-reason-cut") |> Enum.to_list()

    # The note is on the page once; its disclosure says who wrote it.
    refute LazyHTML.query(doc, "#opening-lead-why") |> LazyHTML.text() =~
             "absurdity of power abuse"

    assert LazyHTML.query(doc, "#opening-lead-why") |> LazyHTML.text() =~ "AI-generated note"
  end

  test "a headline says when it was found and until when it is shown" do
    doc = render_article()

    assert LazyHTML.query(doc, "#opening-highlight-8-kind") |> LazyHTML.text() =~ "Headline"

    assert LazyHTML.query(doc, "#opening-highlight-8-as-of") |> LazyHTML.text() =~
             "Headlines change. Found 3 November 2026, 03:02 UTC; shown until 10 November 2026."

    assert LazyHTML.query(doc, "#opening-highlight-5-kind") |> LazyHTML.text() =~ "Film"
  end

  test "a section with nothing published in it is not drawn" do
    doc = render_article(%{nine() | highlights: [definition(1)]})
    assert ids(doc, "section[id^='curated-']") == ~w(curated-lead curated-definitions)
  end

  test "a reason a person wrote has no AI mark and no cut mark" do
    person = %Reason{
      kind: :editorial,
      text: String.duplicate("x", 100),
      author: %{kind: :human, label: "A person"}
    }

    opening = %{nine() | lead: %{lead() | reasons: [person]}, highlights: []}
    doc = render_article(opening)

    reason = LazyHTML.query(doc, "#opening-lead-reason")
    refute LazyHTML.text(reason) =~ "cut at"
    assert Enum.empty?(LazyHTML.query(reason, "[aria-hidden='true']"))
  end
end
