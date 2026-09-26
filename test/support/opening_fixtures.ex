defmodule DevilsDictionary.OpeningFixtures do
  @moduledoc """
  The corner of the corpus the committed curated-opening fixture names (#156):
  *love* with Bierce's and Johnson's entries, WordNet and Wiktionary senses,
  the Wiktionary quotations the fixture highlights, the concept Q316 and Gérard's
  *Cupid and Psyche* seeded from a `wikidata-famous` manifest.

  Built with the **same source identities and revision keys** as the dev
  corpus — `LOVE/n` at its content hash, `love/noun/1` at its content hash,
  Q8777422 in `wikidata-famous-v1` — so a test that renders
  `priv/curation/opening-fixtures.json` proves the committed references
  resolve, rather than a copy of them written for the test. The texts are the
  sources' own, copied from the dev corpus.
  """

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}

  @bierce_love_key "764883999f1a0ef470bae07d0967596f894e3a2c220409249fb8e86e887a16c2"
  @wiktionary_love_key "234effe43aa45fd2ab47e9b872d4a550dc341620c04dc2122e27e48602f858a3"

  @bierce_love "A temporary insanity curable by marriage or by removal of the patient from the influences under which he incurred the disorder. This disease, like *caries* and many other ailments, is prevalent only among civilized races living under artificial conditions; barbarous nations breathing pure air and eating simple food enjoy immunity from its ravages. It is sometimes fatal, but more frequently to the physician than to the patient."

  @benevolent "Affectionate, benevolent concern or care for other people or beings, and for their well-being."
  @profound "A profound and caring affection towards someone."
  @intense "A feeling of intense attraction towards someone."

  @milton %{
    "ref" => "1674, John Milton, Paradise Lost:",
    "text" =>
      "He on his side / Leaning half-raised, with looks of cordial love / Hung over her enamoured.",
    "type" => "quotation"
  }

  @congreve %{
    "ref" =>
      "1697, [William] Congreve, The Mourning Bride, a Tragedy. […], London: […] Jacob Tonson, […], →OCLC, Act III, page 39:",
    "text" =>
      "Heav'n has no Rage, like Love to Hatred turn'd, / Nor Hell a Fury, like a Woman ſcorn'd.",
    "type" => "quotation"
  }

  def bierce_love_key, do: @bierce_love_key
  def wiktionary_love_key, do: @wiktionary_love_key
  def bierce_love, do: @bierce_love
  def glosses, do: %{benevolent: @benevolent, profound: @profound, intense: @intense}

  @doc """
  *love*, noun, with everything the committed `love` composition names. Returns
  the rows a test asserts about.
  """
  def love!(ctx) do
    love = word!(ctx, "love", ~w(bierce johnson wiktionary wordnet), scope: nil)

    bierce_record =
      record!(ctx, "bierce", external_id: "LOVE/n", content_hash: @bierce_love_key)

    bierce =
      entry!(ctx, love, "bierce",
        record: bierce_record,
        headword: "LOVE",
        pos: "n",
        year: 1911,
        body: @bierce_love,
        url: "https://www.gutenberg.org/files/972/972-h/972-h.htm#link2H_4_0014"
      )

    johnson =
      entry!(ctx, love, "johnson",
        headword: "LOVE",
        pos: "n. s.",
        body: "1. The passion between the sexes."
      )

    sense!(ctx, love, "wordnet",
      group_key: "oewn-love-n-1",
      gloss: "any object of warm affection or devotion"
    )

    wiktionary_record =
      record!(ctx, "wiktionary", external_id: "love/noun/1", content_hash: @wiktionary_love_key)

    benevolent =
      sense!(ctx, love, "wiktionary",
        record: wiktionary_record,
        external_id: "love/noun/1#2",
        gloss: @benevolent,
        position: 1
      )

    profound =
      sense!(ctx, love, "wiktionary",
        record: wiktionary_record,
        external_id: "love/noun/1#1",
        gloss: @profound,
        position: 2,
        examples: [
          %{"type" => "example", "text" => "My love for Melca is eternal."},
          @milton
        ]
      )

    intense =
      sense!(ctx, love, "wiktionary",
        record: wiktionary_record,
        external_id: "love/noun/1#3",
        gloss: @intense,
        position: 3,
        examples: [@congreve]
      )

    concept = concept!("Q316", "love", description: "strong, positive emotion based on affection")
    link!(love, concept, sense: benevolent, confidence: 0.95)

    {:ok, _summary} =
      Manifest.new("wikidata-famous", [
        %{
          "qid" => "Q8777422",
          "title" => "Cupid and Psyche",
          "date" => "1798",
          "sitelinks" => 10,
          "image_url" => "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Cupid.jpg",
          "commons_file" => "Psyché et l'Amour - François Gérard.jpg",
          "credit_line" => "Psyché et l'Amour - François Gérard.jpg · Wikimedia Commons",
          "creators" => [%{"qid" => "Q163543", "term" => "François Gérard"}],
          "depicts" => [
            %{"qid" => "Q316", "term" => "love"},
            %{"qid" => "Q5011", "term" => "Cupid"},
            %{"qid" => "Q843382", "term" => "Psyche"}
          ]
        }
      ])
      |> Seeder.run()

    %{
      love: love,
      bierce: bierce,
      johnson: johnson,
      benevolent: benevolent,
      profound: profound,
      intense: intense,
      concept: concept,
      artwork_id: DevilsDictionary.Registry.by_external_id("wikidata", "Q8777422")
    }
  end
end
