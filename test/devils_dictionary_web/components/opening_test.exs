defmodule DevilsDictionaryWeb.OpeningTest do
  @moduledoc """
  The curated opening component (#156) renders the view model and nothing
  else: source text distinct from what is said about it, every credit on the
  page, reasons that name their speaker, no empty slots.
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

  @fixture_author %{kind: :model, label: "Claude Code (Opus 5.5)"}

  defp lead(attrs \\ %{}) do
    struct!(
      %Lead{
        reference: %Reference{
          object_id: 11,
          object_kind: :content,
          content_revision_id: 411,
          locator: %{kind: :sentences, count: 1}
        },
        policy: :priority_source,
        source: %{
          slug: "bierce",
          name: "Ambrose Bierce, The Devil's Dictionary",
          tier: :aristocracy,
          logo: nil
        },
        author: "Ambrose Bierce",
        work: "The Devil's Dictionary",
        entry: %{headword: "LOVE", marker: "n", year: 1911},
        excerpt: %{
          text: "A temporary insanity curable by marriage.",
          html: "A temporary insanity curable by <em>marriage</em>.",
          clipped?: true,
          chars: 428
        },
        meaning: %Meaning{
          kind: :lexeme,
          object_id: 1,
          label: "love",
          part_of_speech: "noun",
          anchor: "#card-bierce"
        },
        links: %{
          card_id: "card-bierce",
          source: "https://www.gutenberg.org/files/972/972-h/972-h.htm"
        },
        credits: [
          %Credit{
            label: "Source",
            text: "Ambrose Bierce, The Devil's Dictionary (1911), public domain",
            href: "https://www.gutenberg.org/ebooks/972"
          },
          %Credit{label: "Rights", text: "Public domain"}
        ],
        reasons: [
          %Reason{
            kind: :policy,
            text: "Bierce first: where The Devil’s Dictionary defines a word, its entry leads."
          }
        ]
      },
      attrs
    )
  end

  defp sense_meaning(label),
    do: %Meaning{
      kind: :sense,
      object_id: 2,
      sense_revision_id: 22,
      label: label,
      source: %{slug: "wiktionary", name: "Wiktionary (English) via Kaikki"},
      anchor: "#card-wiktionary-noun"
    }

  defp artwork(position) do
    %Highlight{
      position: position,
      kind: :artwork,
      reference: %Reference{
        object_id: 3_735_469,
        object_kind: :entity,
        catalog: %{manifest: "wikidata-famous-v1", checksum: String.duplicate("a", 64)}
      },
      title: "Cupid and Psyche",
      creator: "François Gérard",
      date: "1798",
      image: %{url: "https://upload.wikimedia.org/cupid.jpg", alt: ""},
      meaning: sense_meaning("Affectionate, benevolent concern."),
      source: %{slug: "wikidata", name: "Wikidata", tier: :middle, logo: nil},
      credits: [
        %Credit{
          label: "Image",
          text: "Psyché et l'Amour - François Gérard.jpg · Wikimedia Commons",
          href: "https://commons.wikimedia.org/wiki/File:Psyche.jpg"
        }
      ],
      reasons: [
        %Reason{kind: :source_match, text: "The catalog records this work as depicting Q316."},
        %Reason{kind: :editorial, text: "Chosen as the picture.", author: @fixture_author}
      ]
    }
  end

  defp quotation(position) do
    %Highlight{
      position: position,
      kind: :quotation,
      reference: %Reference{
        object_id: 2,
        object_kind: :sense,
        sense_revision_id: 22,
        locator: %{kind: :quotation, fingerprint: String.duplicate("9", 64)}
      },
      quotation: %{
        text: "To Hymen's bower young Cupid came,\nAnd each with each was quite delighted;",
        citation: "1897, “The Quarrel of Love and Hymen”",
        provenance: "plausible"
      },
      meaning: sense_meaning("Cupid, Eros, or another personification of love."),
      source: %{
        slug: "wiktionary",
        name: "Wiktionary (English) via Kaikki",
        tier: :middle,
        logo: nil
      },
      credits: [
        %Credit{
          label: "Rights",
          text: "CC BY-SA 4.0",
          href: "https://creativecommons.org/licenses/by-sa/4.0/"
        }
      ],
      reasons: [
        %Reason{kind: :source_match, text: "Wiktionary files this quotation under this meaning."}
      ]
    }
  end

  defp opening(attrs) do
    struct!(
      %Composition{
        composition: %{id: "fixture:love", version: 1},
        origin: :fixture,
        review: %Review{
          state: :unreviewed,
          selected_by: @fixture_author,
          selected_on: ~D[2026-09-26]
        }
      },
      attrs
    )
  end

  defp render_opening(attrs),
    do: render_component(&Opening.section/1, opening: opening(attrs)) |> LazyHTML.from_fragment()

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "the lead is the source's words, verbatim, set as a quotation with its source beneath" do
    doc = render_opening(lead: lead(), highlights: [])

    assert text(doc, "#opening-lead-text") == "A temporary insanity curable by marriage."
    assert count(doc, "#opening-lead-text em") == 1

    assert count(
             doc,
             "#opening-lead blockquote[cite='https://www.gutenberg.org/files/972/972-h/972-h.htm']"
           ) == 1

    assert text(doc, "#opening-lead figcaption") =~ "Ambrose Bierce"
    assert text(doc, "#opening-lead figcaption cite") == "The Devil's Dictionary"
  end

  test "a clipped lead offers the whole entry, and the link opens its card on this page" do
    doc = render_opening(lead: lead(), highlights: [])

    assert count(doc, "a#opening-lead-entry[href='#card-bierce']") == 1
    assert text(doc, "#opening-lead-entry") =~ "Read the whole entry"
    assert text(doc, "#opening-lead-entry") =~ "428 characters"

    [click] = doc |> LazyHTML.query("#opening-lead-entry") |> LazyHTML.attribute("phx-click")
    assert click =~ "set_attr"
    assert click =~ "#card-bierce"
  end

  test "an unclipped lead points at its card without promising more" do
    doc =
      render_opening(
        lead: lead(excerpt: %{text: "Short.", html: "Short.", clipped?: false, chars: 6})
      )

    refute text(doc, "#opening-lead-entry") =~ "Read the whole entry"
    assert text(doc, "#opening-lead-entry") =~ "among the definitions"
  end

  test "meaning, rule and credits are labelled, and every credit is on the page, unclamped" do
    doc = render_opening(lead: lead(), highlights: [artwork(1)])

    assert text(doc, "#opening-lead-meaning") =~ "love"
    assert text(doc, "#opening-lead-reason-0") =~ "Bierce first"
    assert text(doc, "#opening-lead-credits") =~ "public domain"
    assert text(doc, "#opening-highlight-1-credits") =~ "Wikimedia Commons"
    assert count(doc, "#opening [class*=line-clamp]") == 0

    assert count(
             doc,
             "#opening-highlight-1-credits a[href^='https://commons.wikimedia.org'][target=_blank]"
           ) == 1
  end

  test "an editorial note is set apart and names its author and review state" do
    doc = render_opening(lead: lead(), highlights: [artwork(1)])

    assert text(doc, "#opening-highlight-1-note-0") =~ "Editorial note"

    assert text(doc, "#opening-highlight-1-note-0-author") =~
             "AI-generated by Claude Code (Opus 5.5)"

    assert text(doc, "#opening-highlight-1-note-0-author") =~ "not reviewed by a person"
    # Never set as a quotation: the display serif is the source's alone.
    assert count(doc, "#opening-highlight-1-note-0 blockquote") == 0
    assert text(doc, "#opening-highlight-1-reason-0") =~ "Source match"
  end

  test "a quotation keeps its source's line breaks and escapes its text" do
    doc =
      render_opening(
        highlights: [
          %{
            quotation(1)
            | quotation: %{quotation(1).quotation | text: "<b>bold</b>\nsecond line"}
          }
        ]
      )

    assert count(doc, "#opening-highlight-1-text br") == 1
    assert count(doc, "#opening-highlight-1-text b") == 0
    assert text(doc, "#opening-highlight-1-text") =~ "<b>bold</b>"
    assert text(doc, "#opening-highlight-1-provenance") == "Plausible"
    assert text(doc, "#opening-highlight-1-citation") =~ "Quarrel of Love and Hymen"
  end

  test "the highlights take as many columns as there are highlights, never an empty slot" do
    three = render_opening(lead: lead(), highlights: [artwork(1), quotation(2), quotation(3)])
    two = render_opening(lead: lead(), highlights: [artwork(1), quotation(2)])
    one = render_opening(lead: lead(), highlights: [artwork(1)])

    assert count(three, "#opening-highlights > li") == 3
    assert count(three, "#opening-highlights[class*='@2xl:grid-cols-3']") == 1
    assert count(two, "#opening-highlights[class*='@xl:grid-cols-2']") == 1

    assert count(
             one,
             "#opening-highlights[class*='grid-cols-2'], #opening-highlights[class*='grid-cols-3']"
           ) == 0
  end

  test "a leadless opening shows its highlights and no lead at all" do
    doc = render_opening(lead: nil, highlights: [quotation(1)])

    assert count(doc, "#opening-lead") == 0
    assert count(doc, "#opening-highlight-1") == 1
  end

  test "a fixture says it is one; a published composition does not" do
    fixture = render_opening(lead: lead())

    published =
      render_opening(lead: lead(), origin: :published, composition: %{id: 12, version: 3})

    assert text(fixture, "#opening-fixture") =~ "Development fixture"
    assert text(fixture, "#opening-about-selection") =~ "not a published composition"
    assert count(published, "#opening-fixture") == 0
    assert text(published, "#opening-about-selection") =~ "Composition 12, version 3"
  end

  test "the disclosure says who selected it, that nobody reviewed it, and that no panel took part" do
    doc = render_opening(lead: lead(), highlights: [artwork(1), quotation(2)])

    assert count(doc, "details#opening-about[phx-mounted]") == 1

    assert text(doc, "#opening-about-summary") =~
             "Selected by Claude Code (Opus 5.5), an AI model"

    assert text(doc, "#opening-about-summary") =~ "not reviewed"
    assert text(doc, "#opening-about-selected") =~ "26 September 2026"
    assert text(doc, "#opening-about-reviewed") =~ "No person has reviewed"
    assert text(doc, "#opening-about-panel") =~ "No model or persona panel took part"
    assert text(doc, "#opening-about-dissent") == "None recorded."
  end

  test "the disclosure lists every exact revision, linked to its evidence or its work" do
    doc = render_opening(lead: lead(), highlights: [artwork(1), quotation(2)])

    assert text(doc, "#opening-about-revision-lead") =~ "content 11, revision 411, first sentence"
    assert count(doc, "#opening-about-revision-lead a[href='/evidence/content/411']") == 1

    assert count(doc, "#opening-about-revision-1 a[href='/entities/3735469/cupid-and-psyche']") ==
             1

    assert count(doc, "#opening-about-revision-2 a[href='/evidence/sense/22']") == 1
  end

  test "withheld items are named with their reason, and nothing is said to replace them" do
    doc =
      render_opening(
        lead: nil,
        highlights: [quotation(2)],
        withheld: [
          %{role: :lead, position: nil, reason: :revision_not_current},
          %{role: :highlight, position: 1, reason: :catalog_changed}
        ]
      )

    withheld = text(doc, "#opening-about-withheld")
    assert withheld =~ "The lead: its exact source revision is no longer current"
    assert withheld =~ "Highlight 1: its catalog has changed"
    assert withheld =~ "Nothing was put in its place"
  end

  test "the section has a heading for assistive technology and none on screen" do
    doc = render_opening(lead: lead())

    assert count(doc, "section#opening[aria-labelledby=opening-heading]") == 1
    assert count(doc, "h2#opening-heading.sr-only") == 1
  end
end
