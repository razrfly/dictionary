defmodule DevilsDictionary.Sources.Catalog do
  @moduledoc """
  The registry of what we absorb from, as data.

  Five open sources for MVP-0 (issue #69 §2), the Animals test scope (§3), and
  Bierce as a person who authored a layer. Lives in `lib` rather than in
  `seeds.exs` because seeds do **not** run in `:test` — the test alias is
  `ecto.create, ecto.migrate, test` — so tests and seeds need one shared
  definition. `mix dd.score`'s A1 row checks reality against this list.

  Adding a source is a row here plus a module under `Absorb.Sources`
  (scorecard E1: zero migrations).
  """

  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Person, Source}

  @doc """
  The MVP-0 sources. Pinned snapshots live in `config`.
  """
  def sources do
    [
      %{
        slug: "wordnet",
        name: "Open English WordNet 2025",
        tier: :middle,
        kind: :lexical_db,
        access: :dump,
        era_year: 2025,
        license: "CC BY 4.0",
        license_url: "https://creativecommons.org/licenses/by/4.0/",
        homepage: "https://en-word.net/",
        url_template: "https://en-word.net/id/{external_id}",
        attribution: "Open English WordNet 2025 (CC BY 4.0)",
        config: %{
          # The PLUS edition, deliberately: the base edition holds 107,519
          # synsets / 135,969 (lemma, pos) pairs and fails scorecard A2, which
          # needs >= 120,000 / >= 155,000. See #70 S0b.
          "dump_url" =>
            "https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025-plus-json.zip",
          "dump_file" => "data/english-wordnet-2025-plus-json.zip",
          "edition" => "2025-plus",
          "snapshot_date" => "2025-12-12",
          "synset_prefix" => "oewn-",
          "expected_synsets" => 120_564,
          "expected_lexemes" => 161_875
        }
      },
      %{
        slug: "wiktionary",
        name: "Wiktionary (English) via Kaikki",
        tier: :middle,
        kind: :dictionary,
        access: :dump,
        era_year: 2026,
        license: "CC BY-SA 4.0",
        license_url: "https://creativecommons.org/licenses/by-sa/4.0/",
        homepage: "https://en.wiktionary.org/",
        url_template: "https://en.wiktionary.org/wiki/{lemma}#English",
        attribution: "Wiktionary contributors (CC BY-SA 4.0), extracted by kaikki.org",
        config: %{
          "dump_url" => "https://kaikki.org/dictionary/raw-wiktextract-data.jsonl.gz",
          "dump_file" => "data/raw-wiktextract-data.jsonl.gz",
          "dump_date" => "2026-08-28",
          "dump_bytes" => 2_826_623_319,
          "lang_code" => "en",
          # Decision #11 / scorecard M4: drop what we never materialize before
          # storing. Measured at ~81% smaller on the fixtures.
          # One source of truth: the module decides what it throws away, and the
          # catalog reports it, so the two can never drift.
          "trim" => DevilsDictionary.Absorb.Sources.Wiktionary.trimmed_keys()
        }
      },
      %{
        slug: "wikidata",
        name: "Wikidata",
        tier: :middle,
        kind: :knowledge_graph,
        access: :api,
        era_year: 2026,
        license: "CC0 1.0",
        license_url: "https://creativecommons.org/publicdomain/zero/1.0/",
        homepage: "https://www.wikidata.org/",
        url_template: "https://www.wikidata.org/wiki/{external_id}",
        attribution: "Wikidata (CC0)",
        config: %{
          # `wbgetentities` takes 50 ids per call and, filtered to en + enwiki,
          # returns the same claims as `Special:EntityData` for a third of the
          # bytes: ~18,000 entities become ~360 requests. `entity_url` stays as
          # the canonical per-entity document a human can open.
          "api_url" => "https://www.wikidata.org/w/api.php",
          "entity_url" => "https://www.wikidata.org/wiki/Special:EntityData/{qid}.json",
          "batch_size" => 50,
          "rate_limit_ms" => 200,
          "claims" => DevilsDictionary.Absorb.Sources.Wikidata.kept_properties()
        }
      },
      %{
        slug: "wikipedia",
        name: "Wikipedia (English)",
        tier: :middle,
        kind: :encyclopedia,
        access: :api,
        era_year: 2026,
        license: "CC BY-SA 4.0",
        license_url: "https://creativecommons.org/licenses/by-sa/4.0/",
        homepage: "https://en.wikipedia.org/",
        url_template: "https://en.wikipedia.org/wiki/{title}",
        attribution: "Wikipedia contributors (CC BY-SA 4.0)",
        config: %{
          # The Action API takes 20 titles per call and adds redirect
          # resolution, the disambiguation flag and `wikibase_item`, none of
          # which the REST summary gives without a second guess.
          "api_url" => "https://en.wikipedia.org/w/api.php",
          "summary_url" => "https://en.wikipedia.org/api/rest_v1/page/summary/{title}",
          "batch_size" => 20,
          "rate_limit_ms" => 200,
          "keep" => DevilsDictionary.Absorb.Sources.Wikipedia.kept_keys()
        }
      },
      %{
        slug: "bierce",
        name: "Ambrose Bierce, The Devil's Dictionary",
        tier: :aristocracy,
        kind: :dictionary,
        access: :static,
        era_year: 1911,
        license: "Public domain",
        license_url: "https://www.gutenberg.org/policy/permission.html",
        homepage: "https://www.gutenberg.org/ebooks/972",
        # Gutenberg gives the text no per-entry anchors — only one `id` per
        # letter chapter — so each record carries its own anchored url and this
        # template is the whole-document fallback A9 asks every source for.
        url_template: "https://www.gutenberg.org/files/972/972-h/972-h.htm",
        attribution: "Ambrose Bierce, The Devil's Dictionary (1911), public domain",
        config: %{
          # The HTML edition, not the plain text: one paragraph per entry, verse
          # in <pre>, attributions as their own paragraphs. `pg972.txt` is the
          # same transcription and stays as a cross-check.
          "file" => "priv/sources/bierce/972-h.htm",
          "cross_check_file" => "priv/sources/bierce/pg972.txt",
          "gutenberg_id" => 972
        }
      },
      %{
        slug: "johnson",
        name: "Samuel Johnson, A Dictionary of the English Language",
        tier: :aristocracy,
        kind: :dictionary,
        access: :static,
        era_year: 1755,
        # The 1755 text is public domain; the transcription we parse is not.
        # CC BY 4.0 makes the attribution below a licence condition.
        license: "CC BY 4.0 (LEME transcription); the 1755 text is public domain",
        license_url: "https://creativecommons.org/licenses/by/4.0/",
        homepage: "https://leme.library.utoronto.ca/lexicons/1345/",
        # LEME gives the lexicon one page and no per-entry anchors, so this is
        # the whole-document fallback A9 asks every source for — the same
        # bargain the Bierce row strikes with Gutenberg's letter chapters.
        url_template: "https://leme.library.utoronto.ca/lexicons/1345/",
        attribution:
          "Samuel Johnson, A Dictionary of the English Language (1755); " <>
            "TEI-XML transcription by Ian Lancashire, Lexicons of Early Modern " <>
            "English (LEME), University of Toronto, CC BY 4.0",
        config: %{
          "file" => "priv/sources/johnson/johnson-1755-leme.xml.gz",
          # The transcription is versioned and the file is committed, so both
          # are pinned: a re-download that does not match this is a different
          # text, and every number S5 posted was measured on this one.
          "edition" => "LEME ver. 1.0 (2023)",
          "sha256" => "5b969669f18fe08981d74314471b6864ebca18967fd4633e8c93f8724df74418",
          "entries" => 42_726,
          "leme_lexicon_id" => 1345,
          "tspace_handle" => "1807/124274",
          "tspace_url" => "https://hdl.handle.net/1807/124274",
          # Also nicer to read, and restricted: non-commercial research only,
          # no API. Linked from the source page, never absorbed.
          "related_url" => "https://johnsonsdictionaryonline.com/"
        }
      }
    ]
  end

  @doc """
  People who authored a layer. Keyed by the source slug they wrote.
  """
  def people do
    [
      %{
        name: "Ambrose Bierce",
        slug: "ambrose-bierce",
        birth_date: ~D[1842-06-24],
        death_date: ~D[1914-01-01],
        bio: "American satirist; author of The Devil's Dictionary (1911).",
        wikidata_id: "Q310190",
        source_slug: "bierce"
      },
      %{
        name: "Samuel Johnson",
        slug: "samuel-johnson",
        birth_date: ~D[1709-09-18],
        death_date: ~D[1784-12-13],
        bio:
          "English lexicographer, critic and poet; author of A Dictionary of " <>
            "the English Language (1755).",
        wikidata_id: "Q182589",
        source_slug: "johnson"
      }
    ]
  end

  @doc """
  The scopes, read from `priv/scopes/*.json`.

  A scope is **data**, not code (scorecard E2): its rules live in a file that
  `mix dd.scope.new` writes, and no scope is defined in Elixir — `animals`
  included, so nothing about the first one is different from the Nth.

  `animals.json`'s `wiktionary_categories` list is frozen on purpose. The Kaikki
  dump carries each entry's categories as flat strings with no hierarchy, so the
  tree was walked once from `Category:en:Animals`
  (`mix dd.scope.categories animals`) and pinned in the file — which keeps
  `mix dd.scope.build` offline and reproducible (scorecard O3). Regenerate only
  if Wiktionary reorganises the tree.
  """
  def scopes do
    scopes_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&read_scope!/1)
  end

  @doc "Where the scope files live, at compile time and from a release."
  def scopes_dir, do: Application.app_dir(:devils_dictionary, "priv/scopes")

  @doc """
  Reads one scope file into the shape `seed!/0` and `Lexicon.create_scope/1`
  want. A file without a slug or a name is a mistake worth stopping on.
  """
  def read_scope!(path) do
    attrs = path |> File.read!() |> Jason.decode!()

    %{
      slug: Map.fetch!(attrs, "slug"),
      name: Map.fetch!(attrs, "name"),
      rules: Map.get(attrs, "rules", %{})
    }
  end

  @doc """
  Upserts the whole catalog. Idempotent: re-running only refreshes config.
  """
  def seed! do
    sources = Map.new(sources(), fn attrs -> {attrs.slug, upsert!(Source, :slug, attrs)} end)

    people =
      Map.new(people(), fn person ->
        {slug, attrs} = Map.pop(person, :source_slug)
        {attrs.slug, upsert!(Person, :slug, Map.put(attrs, :source_id, sources[slug].id))}
      end)

    scopes = Map.new(scopes(), fn attrs -> {attrs.slug, upsert!(Scope, :slug, attrs)} end)

    %{sources: sources, scopes: scopes, people: people}
  end

  defp upsert!(schema, natural_key, attrs) do
    replace = attrs |> Map.keys() |> Enum.reject(&(&1 == natural_key))

    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, replace},
      conflict_target: [natural_key],
      returning: true
    )
  end
end
