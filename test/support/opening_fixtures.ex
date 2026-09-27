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

  @doc "Q8777422's row in the committed `wikidata-famous-v1` manifest."
  def cupid_and_psyche_row do
    "priv/artworks/manifests/wikidata-famous-v1.json"
    |> Manifest.load!()
    |> Map.fetch!("rows")
    |> Enum.find(&(&1["qid"] == "Q8777422"))
  end

  @committed_famous "artworks/manifests/wikidata-famous-v1.json"

  @doc """
  Puts `wikidata-famous-v1` under `root` (a stand-in for `priv/`, via
  `:committed_manifest_root`) in one of the states a committed manifest can
  be found in on disk, and returns the path:

    * `:valid` — an exact copy of the committed file;
    * `:missing` — no file at all;
    * `:malformed` — the file cut off mid-JSON;
    * `:invalid_checksum` — a row edited without refreshing `checksum`;
    * `:unsupported_schema` — a `schema_version` this code does not read;
    * `:unsupported_shape` — valid JSON that is not a manifest (`[]`);
    * `:not_compiled` — a manifest that verifies, but is not the one this
      build was compiled with.
  """
  def committed_manifest!(root, variant) do
    path = Path.join(root, @committed_famous)
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    real = File.read!(Path.join(:code.priv_dir(:devils_dictionary), @committed_famous))

    case variant do
      :valid ->
        File.write!(path, real)

      :missing ->
        :ok

      :malformed ->
        File.write!(path, binary_part(real, 0, 4096))

      :invalid_checksum ->
        manifest = Jason.decode!(real)
        [first | rest] = manifest["rows"]
        tampered = %{manifest | "rows" => [Map.put(first, "title", "Edited by hand") | rest]}
        File.write!(path, Jason.encode!(tampered))

      :unsupported_schema ->
        File.write!(
          path,
          real |> Jason.decode!() |> Map.put("schema_version", 2) |> Jason.encode!()
        )

      :unsupported_shape ->
        File.write!(path, "[]")

      :not_compiled ->
        File.write!(
          path,
          "wikidata-famous" |> Manifest.new([cupid_and_psyche_row()]) |> Jason.encode!()
        )
    end

    path
  end

  @doc "Every way `committed_manifest!/2` can leave a manifest that must not be read."
  def unreadable_manifests,
    do: [
      :missing,
      :malformed,
      :invalid_checksum,
      :unsupported_schema,
      :unsupported_shape,
      :not_compiled
    ]

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

    # The committed catalog row itself, not a copy written for the test: the
    # reader checks that what it displays is exactly what the pinned
    # manifest says, so the seeded row has to be that row.
    {:ok, _summary} = Manifest.new("wikidata-famous", [cupid_and_psyche_row()]) |> Seeder.run()

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
