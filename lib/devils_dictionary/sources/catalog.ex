defmodule DevilsDictionary.Sources.Catalog do
  @moduledoc """
  The registry of what we absorb from, as data.

  Six open absorbed sources plus registered discovery providers, the scopes read
  from `priv/scopes/`, and the authors of the two historical dictionaries — as
  **entities**, with the works they wrote and the editions we imported. Lives in
  `lib` rather than in `seeds.exs` because
  seeds do **not** run in `:test` — the test alias is `ecto.create, ecto.migrate,
  test` — so tests and seeds need one shared definition. `mix dd.score`'s A1 row
  checks reality against this list.

  Adding an absorbed source is a row here plus a module under `Absorb.Sources`
  (scorecard E1: zero migrations). Provider-owned source rows are appended by
  `Discovery.Providers` without making them absorb adapters.

  A third kind exists and is deliberately **not** in `sources/0`:
  `DevilsDictionary.Sources.OnDemand`, the definition sources the reader's own
  browser fetches and nothing stores (#136). `seed!/0` writes their rows; A1
  never grades them, because there is no absorb to finish.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

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
        logo: "/images/sources/wordnet.png",
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
        logo: "/images/sources/wiktionary.png",
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
        logo: "/images/sources/wikidata.png",
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
        logo: "/images/sources/wikipedia.png",
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
        logo: "/images/sources/bierce.png",
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
        logo: "/images/sources/johnson.png",
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
    ] ++
      [artsy()] ++
      DevilsDictionary.Discovery.Providers.source_catalog() ++
      DevilsDictionary.Quotations.Checkers.source_catalog() ++
      [DevilsDictionary.Quotations.Corpus.source_attrs()]
  end

  # Artsy is a **corpus**, not a provider (#144 Phase 3, and §4 of #144).
  #
  # Its 43 pilot works reach pages through `Artworks` as `:gene` identity, its
  # gene mappings are installed by `Artworks.install_meaning_mappings!/0`, and
  # `mix dd.artsy.withdraw` can take the lot back out. None of that needs a
  # provider, and the module it had was one that could never run: no
  # `retrieve/4`, `background: false`, a `validate_mapping/2` for a parameter
  # shape nothing built, and a 34-line fixture returning empty pages.
  #
  # The row lives **here** rather than in `:discovery_providers`, and that is
  # the correction #144 §4 needed: it said the source row "already arrives
  # through `Sources.Catalog`", and it did not — `sources/0` is the six MVP-0
  # entries plus `Providers.source_catalog()`, so un-registering the provider
  # without moving this map would have dropped the row on the next seed and
  # raised in `Artworks.install_meaning_mappings!/0`, which does
  # `Map.fetch!(sources, "artsy")`. Measured before the move.
  #
  # `active: false`: the API is being retired (announced 2026-09-11) and its
  # terms require removal of all API content on termination, so nothing should
  # start fetching from it again by accident. The seeded rows are unaffected —
  # `Artworks` reads them through `source.active`, so this is also the switch
  # that takes the Artsy shelf off every page, and it is deliberately left
  # **on** by the row that already exists in the database. `upsert!/3` refreshes
  # `config` and not `active`, so an existing row keeps whatever the owner set.
  defp artsy do
    %{
      slug: "artsy",
      name: "Artsy",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Artsy Public API Terms; removable cache, no permanent archive grant",
      license_url: "https://developers.artsy.net/v2/terms",
      homepage: "https://www.artsy.net/",
      logo: "/images/sources/artsy.png",
      url_template: "https://www.artsy.net/artwork/{external_id}",
      attribution: "Artwork discovery and source metadata: Artsy",
      config: %{
        "mode" => "committed pilot corpus; no request is ever made",
        "retention" => "disposable cache unless independently supported",
        "image_storage" => "references only; no downloads",
        "gene_traversal" => "disabled_pending_control_verification",
        "retirement_notice" => true,
        "left_the_provider_registry" => "2026-09-22, #144 Phase 3"
      }
    }
  end

  @doc """
  The people who authored a layer, and the works and editions those layers are.

  Not a `people` table any more. Each of these becomes an `entities` row with
  `entity_kind: :person` plus a `person_details` row, so Bierce authoring a
  definition, Bierce being the subject of a biography and Bierce being named in
  a cultural claim are all the same `object_id`. #73's first requirement.

  QIDs live in `external_identifiers`, namespaced, and are **verified against
  Wikidata rather than typed from memory** -- see the note on Bierce below.
  """
  def people do
    [
      %{
        name: "Ambrose Bierce",
        slug: "ambrose-bierce",
        birth_date: ~D[1842-06-24],
        # The archived biography gives an approximate year after his disappearance,
        # not a known calendar date. Do not manufacture January 1.
        death_date: nil,
        bio: "American satirist; author of The Devil's Dictionary (1911).",
        # Q191050, not Q310190. This row carried Q310190 from S3 until #74 P0:
        # that is **Tobin Bell**, an American actor born 1942, and the error was
        # invisible because nothing ever resolved it -- Bierce has no Wikipedia
        # pass and the QID was never read back. Checked against the Wikidata API
        # and pinned by a regression test rather than a comment.
        wikidata_id: "Q191050",
        source_slug: "bierce",
        work: %{
          title: "The Devil's Dictionary",
          slug: "the-devils-dictionary",
          work_kind: "dictionary",
          first_published_year: 1911,
          wikidata_id: "Q1197843",
          edition: %{
            slug: "bierce-gutenberg-972",
            label: "Project Gutenberg #972 (1911 text)",
            publication_year: 1911
          }
        }
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
        source_slug: "johnson",
        work: %{
          title: "A Dictionary of the English Language",
          slug: "a-dictionary-of-the-english-language",
          work_kind: "dictionary",
          first_published_year: 1755,
          wikidata_id: "Q1526598",
          edition: %{
            slug: "johnson-leme-1755",
            label: "LEME ver. 1.0 (2023) transcription of the 1755 first edition",
            publication_year: 1755
          }
        }
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

  People, works and editions are identities rather than rows with a natural key,
  so they are matched on their verified Wikidata id where there is one and on
  their preferred label otherwise -- never created twice.
  """
  def seed! do
    # Predicates first: seeding a person also asserts `authored_by` and
    # `edition_of`, and those cannot be asserted before they are registered.
    predicates = DevilsDictionary.Claims.Catalog.seed!()

    sources = Map.new(sources(), fn attrs -> {attrs.slug, upsert!(Source, :slug, attrs)} end)

    # The on-demand definition sources (#136) get their rows here and stay out
    # of `sources/0`: A1 grades everything in that list for a finished absorb,
    # and a source the server never fetches has none. Their own upsert, because
    # `upsert!/3` refreshes config on every seed and `active: false` on one of
    # these is a kill switch a re-seed must not undo.
    on_demand = DevilsDictionary.Sources.OnDemand.seed!()

    scopes = Map.new(scopes(), fn attrs -> {attrs.slug, upsert!(Scope, :slug, attrs)} end)
    people = Map.new(people(), fn person -> {person.slug, seed_person!(person)} end)

    %{
      sources: sources,
      on_demand: on_demand,
      scopes: scopes,
      people: people,
      predicates: predicates
    }
  end

  # A person, the work they wrote, the edition we imported, and the two
  # `authored_by` / `edition_of` claims that connect them. Everything here is
  # `find_or_create`, so seeding twice produces one Bierce.
  defp seed_person!(attrs) do
    person =
      find_or_create_entity(attrs.wikidata_id, attrs.name, fn ->
        {:ok, entity} =
          Registry.create_person(%{
            entity_kind: :person,
            preferred_label: attrs.name,
            description: attrs.bio,
            birth_date: attrs.birth_date,
            death_date: attrs.death_date
          })

        entity
      end)

    work =
      find_or_create_entity(attrs.work.wikidata_id, attrs.work.title, fn ->
        {:ok, entity} =
          Registry.create_work(%{
            entity_kind: :work,
            preferred_label: attrs.work.title,
            work_kind: attrs.work.work_kind,
            first_published_year: attrs.work.first_published_year
          })

        entity
      end)

    edition =
      find_or_create_entity(nil, attrs.work.edition.label, fn ->
        {:ok, entity} =
          Registry.create_edition(%{
            entity_kind: :edition,
            preferred_label: attrs.work.edition.label,
            work_id: work.object_id,
            publication_year: attrs.work.edition.publication_year
          })

        entity
      end)

    assert_once(work.object_id, "authored_by", person.object_id)
    assert_once(edition.object_id, "edition_of", work.object_id)

    # `materialize/1` is pure and cannot look up a person, so a source names its
    # author and its edition by the catalog slug. This is what turns that slug
    # into an entity id, and it is a *name* rather than an identifier because
    # that is what it is: `object_names` is where a thing's names live.
    name_once(person.object_id, attrs.slug)
    name_once(work.object_id, attrs.work[:slug])
    name_once(edition.object_id, attrs.work.edition[:slug])

    %{person: person, work: work, edition: edition}
  end

  defp name_once(object_id, nil), do: object_id

  defp name_once(object_id, slug) do
    Registry.add_name(object_id, slug, name_kind: "catalog_slug")
    object_id
  end

  defp find_or_create_entity(wikidata_id, label, build) do
    existing =
      (wikidata_id && Registry.by_external_id("wikidata", wikidata_id)) ||
        Repo.one(from e in Entity, where: e.preferred_label == ^label, select: e.object_id)

    case existing do
      nil ->
        entity = build.()

        if wikidata_id do
          {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", wikidata_id)
        end

        entity

      object_id ->
        Repo.get!(Entity, object_id)
    end
  end

  defp assert_once(subject_id, predicate_key, object_id) do
    existing =
      Repo.one(
        from r in AssertionRevision,
          join: p in assoc(r, :predicate),
          where:
            r.subject_object_id == ^subject_id and r.object_object_id == ^object_id and
              p.key == ^predicate_key and r.is_current,
          limit: 1
      )

    if is_nil(existing) do
      {:ok, _} = Claims.assert(subject_id, predicate_key, object_id, %{method: "catalog"})
    end

    :ok
  end

  # Everything but the natural key is refreshed on conflict — except `active`,
  # which is the owner's switch: `Discovery.set_provider_active/2` turns a
  # source off at runtime, and a reseed that turned it back on would undo that
  # without anyone deciding to. A new row still takes the `active` its attrs
  # carry, which is how a source is born on or, for a retired one, off.
  defp upsert!(schema, natural_key, attrs) do
    replace = attrs |> Map.keys() |> Enum.reject(&(&1 == natural_key or &1 == :active))

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
